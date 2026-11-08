import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'app_log.dart';
import 'desktop_media.dart';
import 'platform_channel.dart';

/// iOS 侧就地把 Android 的两条自定义通道实现掉：
///
/// * `fqapp/native_player` —— media_kit（MPVKit）播放 + `Video` 纹理；
/// * `fqapp/system_tts` —— AVSpeechSynthesizer，经 `flutter_tts`。
///
/// 契约与 `desktop_platform.dart` 里的 Windows 实现完全一致，所以
/// `NativePlayer`、`InlineVideoPlayback`、`SystemTts` 这些 Dart 侧代码
/// 不需要任何 iOS 分支，只是背后换了个 host。
class IosPlatform {
  IosPlatform._();

  static final IosPlatform instance = IosPlatform._();

  final Map<String, StreamController<dynamic>> _events = {};
  final Map<int, _IosPlayer> _players = {};
  final FlutterTts _tts = FlutterTts();

  int _nextId = 500000;
  bool _initialized = false;

  /// 已经交给合成器排队、还没开读的句子 id。AVSpeechSynthesizer 按队列
  /// 顺序逐条触发 didStartSpeaking，这里靠 FIFO 把 id 对回去。
  final List<String> _pendingIds = [];
  String? _speakingId;

  /// 锁屏 / 控制中心媒体卡与屏幕常亮，实现在
  /// `ios/Runner/AppDelegate.swift` 的 NowPlayingBridge。
  final MethodChannel _mediaSession = const MethodChannel(
    'fqapp/ios_media_session',
  );
  final EventChannel _mediaEvents = const EventChannel(
    'fqapp/ios_media_session/events',
  );

  Stream<dynamic> events(String name) =>
      (_events[name] ??= StreamController<dynamic>.broadcast()).stream;

  void _emit(String name, dynamic event) => _events[name]?.add(event);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    // 必须先初始化 media_kit，否则 VideoController 拿不到原生纹理。
    MediaKit.ensureInitialized();
    PlatformChannels.invoke = invoke;
    PlatformChannels.events = events;
    _configureTts();
    _listenMediaCommands();
  }

  /// 视频画面。与 Windows 版本同形：`Video` + `NoVideoControls`，
  /// 进入后台不自动暂停（后台行为交给 app 的偏好与生命周期）。
  Widget videoSurface(int id, {Key? key}) {
    final host = _players[id];
    return host == null
        ? const SizedBox.expand()
        : Video(
            key: key,
            controller: host.video,
            controls: NoVideoControls,
            fit: BoxFit.fill,
            pauseUponEnteringBackgroundMode: false,
            resumeUponEnteringForegroundMode: false,
          );
  }

  Future<dynamic> invoke(
    String channel,
    String method,
    dynamic arguments,
  ) async {
    final args = arguments is Map ? arguments : const <dynamic, dynamic>{};
    switch (channel) {
      case 'fqapp/native_player':
        return _playback(method, args);
      case 'fqapp/system_tts':
        return _speech(method, args);
      case 'fqapp/eink-refresh':
        return false;
      case 'fqapp/volume-key':
        return null;
      case 'fqapp/fair_memory':
        return null;
    }
    // 其余 `fqapp/*` 通道 iOS 没有原生实现：如实抛给调用方的降级分支，
    // 不要假装成功。插件自己的通道仍然走真实 MethodChannel。
    if (!channel.startsWith('fqapp/')) {
      return MethodChannel(channel).invokeMethod<dynamic>(method, arguments);
    }
    throw MissingPluginException('$channel/$method');
  }

  Future<dynamic> _playback(String method, Map args) async {
    switch (method) {
      case 'create':
        final id = _nextId++;
        final host = _IosPlayer(
          id,
          (event) => _emit('fqapp/native_player/events', event),
        );
        _players[id] = host;
        unawaited(
          host.open(
            args['cdnUrl'] as String,
            args['keyHex'] as String,
            (args['startPositionMs'] as num?)?.toInt() ?? 0,
          ),
        );
        return {'playerId': id};
      case 'setKeepScreenOn':
        // 屏幕常亮：设 UIApplication.isIdleTimerDisabled（主线程）。
        await _setIdleTimer(args['on'] == true);
        return null;
      case 'canDrawOverlays':
        return false;
      case 'requestOverlayPermission':
        return false;
      case 'startListenForeground':
        // 锁屏 / 控制中心媒体卡片：标题、章节、封面、进度与倍速一起下发。
        await _pushNowPlaying(args);
        return null;
      case 'stopListenForeground':
        await _clearNowPlaying();
        return null;
    }

    final id = (args['id'] as num?)?.toInt();
    final host = _players[id];
    if (method == 'dispose') {
      _players.remove(id);
      await host?.dispose();
      return null;
    }
    if (host == null) {
      throw PlatformException(code: 'player_closed', message: '播放器已关闭');
    }
    await host.command(method, args);
    return null;
  }

  /// 耳机线控 / 控制中心按下的动作，转发给 `fqapp/native_player` 的
  /// `onNotificationAction` —— 与 Android 的 MediaSession 回调同一条路径，
  /// `NativePlayer` 与听书/播放页因此不需要任何 iOS 分支。
  void _listenMediaCommands() {
    _mediaEvents.receiveBroadcastStream().listen(
      (event) {
        final action = event is Map ? event['action'] : event;
        if (action is! String || action.isEmpty) return;
        unawaited(
          PlatformChannels.notify(
            'fqapp/native_player',
            'onNotificationAction',
            action,
          ),
        );
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  Future<void> _pushNowPlaying(Map args) async {
    try {
      await _mediaSession.invokeMethod<void>('update', {
        'title': args['title'] ?? '',
        'episode': args['episode'] ?? '',
        'coverUrl': args['coverUrl'] ?? '',
        'playing': args['playing'] == true,
        'hasPrev': args['hasPrev'] == true,
        'hasNext': args['hasNext'] == true,
        'positionMs': (args['positionMs'] as num?)?.toInt() ?? 0,
        'durationMs': (args['durationMs'] as num?)?.toInt() ?? 0,
        'speed': (args['speed'] as num?)?.toDouble() ?? 1,
      });
    } catch (_) {
      // 媒体卡片是增强功能：宿主不可用时静默降级，不影响播放。
    }
  }

  Future<void> _clearNowPlaying() async {
    try {
      await _mediaSession.invokeMethod<void>('clear');
    } catch (_) {
      // 同上。
    }
  }

  Future<void> _setIdleTimer(bool on) async {
    try {
      await _mediaSession.invokeMethod<void>(
        'setIdleTimerDisabled',
        on,
      );
    } catch (_) {
      // 同上：常亮失败不影响播放。
    }
  }

  void _configureTts() {
    // 共享 audio session：朗读时不要把别的音频掐掉，也别被静音开关吞掉。
    unawaited(() async {
      try {
        await _tts.setSharedInstance(true);
      } catch (_) {
        // 老版本 flutter_tts 没有这个方法时忽略即可。
      }
    }());

    _tts.setStartHandler(() {
      final id = _pendingIds.isEmpty ? null : _pendingIds.removeAt(0);
      _speakingId = id;
      if (id != null) {
        _emit('fqapp/system_tts_events', {'type': 'start', 'id': id});
      }
    });
    _tts.setProgressHandler((text, start, end, word) {
      final id = _speakingId;
      if (id == null || start < 0) return;
      _emit('fqapp/system_tts_events', {
        'type': 'range',
        'id': id,
        'start': start,
      });
    });
    _tts.setCompletionHandler(() {
      final id = _speakingId;
      if (id == null) return;
      _speakingId = null;
      _emit('fqapp/system_tts_events', {'type': 'done', 'id': id});
    });
    _tts.setCancelHandler(() {
      _speakingId = null;
    });
    _tts.setErrorHandler((dynamic message) {
      final id = _speakingId;
      _speakingId = null;
      if (id == null) return;
      _emit('fqapp/system_tts_events', {
        'type': 'error',
        'id': id,
        'message': '系统朗读失败，请更换音色后重试',
      });
    });
  }

  Future<dynamic> _speech(String method, Map args) async {
    switch (method) {
      case 'engines':
        final voices = await _tts.getVoices;
        return {
          'defaultEngine': 'ios',
          'engines': [
            {'package': 'ios', 'label': 'iOS 系统语音'},
            if (voices is List)
              for (final voice in voices)
                if (voice is Map && voice['name'] is String)
                  {
                    'package': jsonEncode({
                      'name': voice['name'],
                      'locale': voice['locale'],
                    }),
                    'label': '${voice['name']} (${voice['locale']})',
                  },
          ],
        };
      case 'initialize':
        _pendingIds.clear();
        _speakingId = null;
        await _tts.stop();
        final engine = args['engine'];
        if (engine is String && engine.startsWith('{')) {
          final voice = (jsonDecode(engine) as Map).cast<String, String>();
          await _tts.setVoice({
            'name': voice['name'] ?? '',
            'locale': voice['locale'] ?? '',
          });
        } else {
          await _tts.setLanguage('zh-CN');
        }
        // AVSpeechUtterance 的 rate 以 0.5 为「正常语速」，app 侧的 1.0
        // 对到 0.5；Windows 那边是 SAPI 的 0.5 基线，所以两处换算不同。
        await _tts.setSpeechRate(_iosRate(args['rate']));
        await _tts.setPitch(1);
        await _tts.setVolume(1);
        // 返回值是「一次喂给引擎的最大字数」，AVSpeechSynthesizer 吃得下整段。
        return 300;
      case 'speak':
        final id = args['id'] as String?;
        if (args['queue'] != true) {
          _pendingIds.clear();
          _speakingId = null;
          await _tts.stop();
        }
        if (id != null) _pendingIds.add(id);
        final result = await _tts.speak(args['text'] as String);
        if (result == 0) {
          throw PlatformException(
            code: 'tts_failed',
            message: '系统语音不可用，请检查设置中的语音包',
          );
        }
        return null;
      case 'pause':
        await _tts.pause();
        return null;
      case 'stop':
      case 'shutdown':
        _pendingIds.clear();
        _speakingId = null;
        await _tts.stop();
        return null;
      case 'settings':
        // iOS 没有独立的「语音设置」深链，交给页面自己的提示即可。
        return null;
    }
    throw MissingPluginException(method);
  }

  /// app 侧 0.5–3.0 的倍速 → AVSpeechUtterance 的 0.0–1.0。
  double _iosRate(Object? raw) =>
      (((raw as num?)?.toDouble() ?? 1) * .5).clamp(.1, 1);
}

/// media_kit 播放器 host，事件形状与 Android 的 `fqapp/native_player`
/// 完全一致（playWhenReady / firstFrame / videoSize 等），这样
/// `NativePlayer` 不用区分平台。
class _IosPlayer {
  _IosPlayer(this.id, this.emit) {
    video = VideoController(player);
    void event(String type, dynamic value) {
      if (!disposed) emit({'playerId': id, 'type': type, 'value': value});
    }

    subscriptions.addAll([
      player.stream.position.listen((v) => event('position', v.inMilliseconds)),
      player.stream.duration.listen((v) => event('duration', v.inMilliseconds)),
      player.stream.playing.listen((v) => event('playing', v)),
      player.stream.buffering.listen((v) => event('buffering', v)),
      player.stream.completed.listen((v) => event('completed', v)),
      player.stream.width.listen((_) => _size()),
      player.stream.height.listen((_) => _size()),
      player.stream.error.listen(
        (_) => event('error', {'message': '媒体播放失败，请重试或切换清晰度'}),
      ),
    ]);
    unawaited(
      video.waitUntilFirstFrameRendered.then((_) => event('firstFrame', true)),
    );
  }

  final int id;
  final void Function(Map<String, dynamic>) emit;
  final player = Player();
  late final VideoController video;
  final subscriptions = <StreamSubscription<dynamic>>[];
  final ready = Completer<void>();
  DesktopMedia? media;
  bool disposed = false;

  Future<void> open(String url, String key, int startPositionMs) async {
    ready.future.ignore();
    try {
      var playbackUrl = url;
      if (key.isNotEmpty) {
        // CENC 解密走 Rust 核的回环服务；iOS 上符号来自主二进制本身
        // （见 desktop_media.dart 的 coreLibrary）。
        final session = await DesktopMedia.open(url, key);
        if (disposed) {
          session.close();
          return;
        }
        media = session;
        playbackUrl = session.url;
      }
      if (disposed) return;
      await player.open(Media(playbackUrl), play: false);
      AppLog.d('ios-player', 'id=$id opened paused');
      if (disposed) return;
      if (startPositionMs > 0) {
        await player.seek(Duration(milliseconds: startPositionMs));
      }
      ready.complete();
      emit({'playerId': id, 'type': 'created', 'value': id});
      _size();
    } catch (error) {
      if (!ready.isCompleted) ready.completeError(StateError('无法打开媒体'));
      final value = desktopOpenFailure(id, error);
      if (!disposed) {
        emit({'playerId': id, 'type': 'error', 'value': value});
      }
      media?.close();
    }
  }

  void _size() {
    if (disposed) return;
    emit({
      'playerId': id,
      'type': 'videoSize',
      'width': player.state.width ?? 0,
      'height': player.state.height ?? 0,
      'rotationCorrection': 0,
    });
  }

  Future<void> command(String method, Map args) async {
    await ready.future;
    if (disposed) return;
    AppLog.d('ios-player', 'id=$id command=$method');
    switch (method) {
      case 'play':
        await player.play();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': true});
      case 'pause':
        await player.pause();
        emit({'playerId': id, 'type': 'playWhenReady', 'value': false});
      case 'seek':
        await player.seek(
          Duration(milliseconds: (args['positionMs'] as num).toInt()),
        );
      case 'setRate':
        await player.setRate((args['rate'] as num).toDouble());
      case 'setVolume':
        await player.setVolume(
          (args['volume'] as num).toDouble().clamp(0, 1) * 100,
        );
      default:
        throw MissingPluginException(method);
    }
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    media?.close();
  }
}
