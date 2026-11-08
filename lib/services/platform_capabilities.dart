import 'package:flutter/foundation.dart';

import 'desktop_platform.dart';

/// 视频播放是否可用。
///
/// 视频依赖原生播放器：Android 走 ExoPlayer 平台通道（`fqapp/native_player`），
/// Windows 与 iOS 走 media_kit（iOS 由 `lib/services/ios_platform.dart` 在
/// 进程内实现同一条通道契约，画面走 `Video` 而不是 Texture）。
bool get supportsVideoPlayback =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        isWindowsDesktop);
