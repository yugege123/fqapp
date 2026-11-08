import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let nowPlaying = NowPlayingBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 听书与视频需要在后台继续出声：audio session 用 playback，配合
    // Info.plist 里的 UIBackgroundModes(audio)。配置失败不挡启动，
    // 播放/朗读会各自报告不可用。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback,
                              options: [.allowAirPlay, .allowBluetoothA2DP])
      try session.setActive(true)
    } catch {
      NSLog("audio session setup failed: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 锁屏/控制中心媒体卡片与屏幕常亮的桥接。隐式引擎下拿 messenger 的
    // 唯一可靠时机就在这里（didFinishLaunching 时 rootViewController 未必就绪）。
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "NowPlayingBridge") {
      nowPlaying.register(with: registrar.messenger())
    }
  }
}

/// 把「锁屏 / 控制中心媒体卡」和「屏幕常亮」接到 Dart。
///
/// Dart 侧（`lib/services/ios_platform.dart`）通过
/// `fqapp/ios_media_session` 下发卡片内容、通过
/// `fqapp/ios_media_session/events` 收到耳机线控/媒体键的动作；
/// 动作再注入 `fqapp/native_player` 的 `onNotificationAction`，
/// 走的是 Android 那条完全相同的远程控制路径。
///
/// 单独放在这个文件里而不是新加 .swift：`ios/Runner.xcodeproj` 是
/// 老式（objectVersion 54）工程，新文件必须手工登记 PBXBuildFile /
/// PBXFileReference / Sources 三处，改错一处就是整包编不出来。
final class NowPlayingBridge: NSObject, FlutterStreamHandler {
  private var control: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var sink: FlutterEventSink?

  private var title = ""
  private var episode = ""
  private var coverUrl = ""
  private var playing = false
  private var hasPrev = false
  private var hasNext = false
  private var elapsed: Double = 0
  private var duration: Double = 0
  private var rate: Double = 1
  private var artwork: MPMediaItemArtwork?
  private var artworkTask: URLSessionDataTask?

  func register(with messenger: FlutterBinaryMessenger) {
    let control = FlutterMethodChannel(
      name: "fqapp/ios_media_session", binaryMessenger: messenger)
    self.control = control
    control.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "detached", message: nil, details: nil))
        return
      }
      self.handle(call, result: result)
    }

    let events = FlutterEventChannel(
      name: "fqapp/ios_media_session/events", binaryMessenger: messenger)
    self.events = events
    events.setStreamHandler(self)

    configureRemoteCommands()
  }

  // MARK: - Dart -> native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      let args = call.arguments as? [String: Any] ?? [:]
      apply(args)
      result(nil)
    case "clear":
      clear()
      result(nil)
    case "setIdleTimerDisabled":
      let on = call.arguments as? Bool ?? false
      DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = on
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func apply(_ args: [String: Any]) {
    let nextTitle = args["title"] as? String ?? ""
    let nextEpisode = args["episode"] as? String ?? ""
    let nextCover = args["coverUrl"] as? String ?? ""

    title = nextTitle
    episode = nextEpisode
    playing = args["playing"] as? Bool ?? false
    hasPrev = args["hasPrev"] as? Bool ?? false
    hasNext = args["hasNext"] as? Bool ?? false
    elapsed = number(args, "positionMs") / 1000.0
    duration = number(args, "durationMs") / 1000.0
    rate = number(args, "speed")
    if rate <= 0 { rate = 1 }

    if nextCover != coverUrl {
      coverUrl = nextCover
      loadArtwork(nextCover)
    }

    updateCommandAvailability()
    pushNowPlaying()
  }

  private func clear() {
    title = ""
    episode = ""
    coverUrl = ""
    playing = false
    hasPrev = false
    hasNext = false
    elapsed = 0
    duration = 0
    artwork = nil
    artworkTask?.cancel()
    artworkTask = nil

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    for command in remoteCommands() {
      command.isEnabled = false
    }
  }

  private func pushNowPlaying() {
    var info: [String: Any] = [:]
    if !title.isEmpty { info[MPMediaItemPropertyTitle] = title }
    if !episode.isEmpty { info[MPMediaItemPropertyArtist] = episode }
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? rate : 0
    if let artwork = artwork {
      info[MPMediaItemPropertyArtwork] = artwork
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
  }

  private func loadArtwork(_ url: String) {
    artworkTask?.cancel()
    artworkTask = nil
    artwork = nil
    guard let parsed = URL(string: url),
      let scheme = parsed.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return }

    artworkTask = URLSession.shared.dataTask(with: parsed) { [weak self] data, _, _ in
      guard let self = self, let data = data, let image = UIImage(data: data) else {
        return
      }
      let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      DispatchQueue.main.async {
        self.artwork = art
        if !self.title.isEmpty { self.pushNowPlaying() }
      }
    }
    artworkTask?.resume()
  }

  private func number(_ args: [String: Any], _ key: String) -> Double {
    if let value = args[key] as? NSNumber { return value.doubleValue }
    if let value = args[key] as? Double { return value }
    return 0
  }

  // MARK: - Remote commands

  private func remoteCommands() -> [MPRemoteCommand] {
    let center = MPRemoteCommandCenter.shared()
    return [
      center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
      center.nextTrackCommand, center.previousTrackCommand, center.stopCommand,
    ]
  }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()

    // play / pause / 耳机线控单击都收敛成同一个动作：Android 侧只认
    // playPause / prev / next / stop 这四种，沿用同一套语义。
    center.playCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.send("playPause")
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.send("playPause")
      return .success
    }
    center.togglePlayPauseCommand.addTarget {
      [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.send("playPause")
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.send("next")
      return .success
    }
    center.previousTrackCommand.addTarget {
      [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.send("prev")
      return .success
    }
    center.stopCommand.addTarget { [weak self] _ -> MPRemoteCommandHandlerStatus in
      self?.send("stop")
      return .success
    }

    updateCommandAvailability()
  }

  private func updateCommandAvailability() {
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    center.nextTrackCommand.isEnabled = hasNext
    center.previousTrackCommand.isEnabled = hasPrev
    center.stopCommand.isEnabled = true
  }

  private func send(_ action: String) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(action)
    }
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
