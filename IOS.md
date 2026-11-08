# iOS 版：构建与已知限制

仓库原本只有 Android / Windows 两个平台。iOS 端是后补的，当前目标是「能在 iPhone 上搜书、管书架、看小说」，不是全功能对齐 Android。

## 构建环境

| 组件 | 版本 | 备注 |
|---|---|---|
| macOS | 27.2+ | |
| Xcode | 27.2 | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| Flutter | **3.47.9** | Xcode 27 的适配补丁在 3.47.0 才进，别用 3.44.x 建 iOS |
| CocoaPods | 1.17.0 | `brew install cocoapods`（系统 Ruby 太旧，别用 gem 装） |
| Rust | 1.99.1 | `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios` |
| flutter_rust_bridge_codegen | 2.13.0 | 必须与 `rust/Cargo.toml` 里的版本一致 |

## 构建

```bash
flutter pub get
./scripts/build_rust_ios.sh          # Rust → ios/Frameworks/libfqapi_core.a
flutter build ios --release --no-codesign
```

产物在 `build/ios/iphoneos/Runner.app`（未签名）。

打包成未签名 IPA：

```bash
rm -rf /tmp/pack && mkdir -p /tmp/pack/Payload
ditto build/ios/iphoneos/Runner.app /tmp/pack/Payload/Runner.app
(cd /tmp/pack && zip -qry fqapp_ios_unsigned.ipa Payload)
```

## 签名

`DEVELOPMENT_TEAM` 不入库。首次构建前把它放进本地文件：

```bash
cp ios/Flutter/Signing.xcconfig.example ios/Flutter/Signing.xcconfig
# 把 DEVELOPMENT_TEAM 改成自己的 Team ID；该文件已被 ios/.gitignore 忽略
```

只要改 `Signing.xcconfig` 就够了，别在 Xcode 的 Signing 页里再选一次 Team——那样
Xcode 会把 `DEVELOPMENT_TEAM` 写回 `ios/Runner.xcodeproj/project.pbxproj`，让工程文件变脏。
`CODE_SIGN_STYLE` 仍是 Automatic，Team 由 xcconfig 供值。

装到真机可以走自签（免费 Apple ID 7 天有效，过期后 App 闪退，重新签一次即可）。
下面的命令按你自己的签名脚本替换：

```bash
BUNDLE_ID=com.fqapp.fqapp IPA=/tmp/pack/fqapp_ios_unsigned.ipa ./your-sign-script.sh
```

## iOS 专用改动（为什么需要）

1. **Rust 核心以静态库链接**。iOS 不允许从 App 包内 dlopen 共享库，所以：
   - `scripts/build_rust_ios.sh` 用 `--crate-type staticlib` 编出 `ios/Frameworks/libfqapi_core.a`（`CARGO_PROFILE_RELEASE_STRIP=debuginfo`，因为 release profile 的 `strip = true` 会裁掉符号）；
   - `ios/Flutter/{Debug,Release}.xcconfig` 追加三个必需设置：
     - `-force_load` 把静态库目标文件全部装进来；
     - `DEAD_CODE_STRIPPING = NO`，否则「只在运行时 dlsym」的符号会被 dead_strip 删掉；
     - `-Wl,-export_dynamic`，主可执行文件默认不导出全局符号，dlsym 会找不到 Rust 入口；
   - `lib/services/rust_bootstrap_io.dart` 在 iOS 上改用 `ExternalLibrary.process()`（接缝在 `lib/services/backend_transport.dart` 的 `runtimeInitializer`）。
2. **桌面专用依赖**（`webview_windows` / `smtc_windows` / `window_manager` / `screen_retriever`）不需要条件导入：它们都能在 iOS 上编译，运行时只在 `isWindowsDesktop` 分支调用。
3. **视频/听书**：2026-11 起不再降级。iOS 由 `lib/services/ios_platform.dart` 在进程内实现 `fqapp/native_player` 与 `fqapp/system_tts`（media_kit + flutter_tts），`supportsVideoPlayback` 在 iOS 为 true。详见下面「iOS 播放与听书怎么实现的」。阅读页的亮度/常亮/墨水屏通道仍然缺失，走既有的 `MissingPluginException` 降级。
4. **图标与应用名**：`scripts/generate_ios_app_icon.py` 从 `assets/branding/app_icon_source.png` 生成 1024 无 alpha 图标（复用 Android 生成器的「去纸张外框」逻辑），`CFBundleDisplayName` 设为「什锦铺」。
5. **关掉 Swift Package Manager**：`flutter config --no-enable-swift-package-manager`（Xcode 27 + SPM 有已知构建失败）。

## 已知限制

- **锁屏 / 控制中心媒体卡**：已接（`NowPlayingBridge`），标题、章节、封面、进度、倍速都会同步，耳机线控的播放/暂停/上下集走与 Android 相同的 `onNotificationAction` 路径。**还没在真机上确认**，尤其封面加载与倍速下的进度外推。
- **屏幕常亮**：已接 `UIApplication.isIdleTimerDisabled`（播放页开、退出关）。阅读页的常亮走的是 `fqapp/reader_device`，iOS 仍不生效。
- **解码器偏好 / 悬浮窗**：Android 专有概念，iOS 不生效；设置页入口还在，选了没有效果。
- 分享、导入导出、后台播放、LAN 分享、番茄书架导入等只在 Android 上验证过；iOS 上这些 `fqapp/*` 通道返回 `MissingPluginException`，界面按既有降级逻辑提示。
- 免费 Apple ID 签名 7 天过期，过期后 App 闪退，重跑一次自签脚本即可。

## 与 Android 构建的关系

iOS 需要 Flutter 3.47+（Xcode 27 适配），因此 `pubspec.lock` 的传递依赖被一并升级到
3.47.9 能解析的版本，Android / Windows 的 CI 也统一到 3.47.9（见 `chore(deps)` 那个
commit）。若上游要保留旧 SDK，把那一个 commit 整体回退、再在 3.44.6 上重新生成
`pubspec.lock` 即可，iOS 侧的改动不受影响。

## iOS 播放与听书怎么实现的（2026-11）

iOS 没有写 Swift 播放器。Windows 端早就有「用 Dart 实现 Android 平台通道」的后端
（`lib/services/desktop_platform.dart` 的 `invoke` + `_DesktopPlayer`），iOS 复用它同一套契约，
底层换成 media_kit（MPVKit）+ flutter_tts。

| 环节 | 位置 | 说明 |
|---|---|---|
| 通道后端 | `lib/services/ios_platform.dart` | 进程内实现 `fqapp/native_player` 与 `fqapp/system_tts`，事件形状与 Android 完全一致 |
| 画面 | `lib/services/video_surface.dart` | 唯一的画面入口：Android → `Texture`，Windows / iOS → media_kit 的 `Video` |
| 解密 | `lib/services/desktop_media.dart` | iOS 用 `DynamicLibrary.process()` 从主二进制查 `fq_desktop_media_*`（静态链接，没有可 dlopen 的库） |
| 播放库 | `pubspec.yaml` → `media_kit_libs_ios_video` | MPVKit；不要换 umbrella 的 `media_kit_libs_video`，那会把 Android 也切走 |
| 音频会话 | `ios/Runner/AppDelegate.swift` + `Info.plist` | `AVAudioSession` 用 `.playback`，并声明 `UIBackgroundModes(audio)` |
| 初始化 | `lib/main.dart` | `Platform.isIOS` 时调 `IosPlatform.instance.initialize()`（media_kit 必须先初始化） |
| 媒体卡 / 常亮 | `ios/Runner/AppDelegate.swift` 的 `NowPlayingBridge` | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` + `isIdleTimerDisabled`；通道 `fqapp/ios_media_session`，动作从 `fqapp/ios_media_session/events` 回来 |

验证状态：Dart 侧过了 `flutter analyze`；**Swift 部分没有本机编译过**（Windows 没有 Xcode），
第一次 CI 构建就是它的首次编译；真机播放、倍速、后台音频、锁屏卡片都还没实测。

## 没有 Mac 也能出包（GitHub Actions）

`.github/workflows/ios-unsigned.yml` 在 `macos-15` runner 上编 Rust 静态库、
跑 `flutter build ios --release --no-codesign`，产物是**未签名 IPA**，从 Artifacts 下载后自行签名：

1. Windows 上装 Sideloadly（或 AltStore），插上 iPhone；
2. 拖入 `fqapp_ios_unsigned.ipa`，填自己的 Apple ID，开始签名并安装；
3. 免费账号 7 天后失效，重签即可；付费开发者账号 1 年。

想省掉点网页这一步，用仓库里的 Windows 脚本（需要先 `gh auth login`）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\ios_selfsign.ps1 -Repo <你的账号>/fqapp
# 只下载最近一次成功的包，不重新触发构建：
powershell -ExecutionPolicy Bypass -File scripts\ios_selfsign.ps1 -Repo <你的账号>/fqapp -SkipBuild
```

脚本会触发构建、等结果、下载 artifact、校验 `Payload/Runner.app/Info.plist` 与 `Runner` 都在，
然后打开 Sideloadly。**签名仍然是你自己点**——那需要你的 Apple ID 和手机。

CI 里不做签名是刻意的：那需要把证书和私钥放进仓库 secret。

> 注意：`pubspec.yaml` 新增了 `media_kit_libs_ios_video`，`pubspec.lock` 必须重新解析。
> 在任意一台装了 Flutter 的机器上跑一次 `flutter pub get` 再提交；否则 `android-apk.yml` 里的
> `flutter pub get --enforce-lockfile` 会因为锁文件里没有新依赖而失败。
