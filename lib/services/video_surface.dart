import 'dart:io';

import 'package:flutter/widgets.dart';

import 'desktop_platform.dart';
import 'ios_platform.dart';

/// 视频画面的唯一入口：Android 用原生纹理，Windows 与 iOS 用 media_kit
/// 的 `Video` 组件。两个调用点（播放页、短剧信息流的卡片）都走这里，
/// 别在页面里各自判断平台。
Widget videoSurfaceFor(int textureId, {Key? key}) {
  if (isWindowsDesktop) {
    return DesktopPlatform.instance.videoSurface(textureId, key: key);
  }
  if (Platform.isIOS) {
    return IosPlatform.instance.videoSurface(textureId, key: key);
  }
  return Texture(key: key, textureId: textureId);
}
