# iOS 打包说明（宝宝手机 / UltraLightProbe）

Flutter 的 iOS 包只能用 **macOS + Xcode** 构建（Windows 上无法生成 .ipa/.app）。
本仓库已把 iOS 侧配置准备齐全，拿到任何一台 Mac（不需要改动 Android 工程）即可出包。

## 本工程为 iOS 做了什么

- 上传设备名：沿用 `--dart-define=device=xxx` 机制。
  - 打“宝宝手机”包时传 `device=宝宝手机`，iPhone 上报即归到网站第 4 台「宝宝手机」设备；
  - 不传该参数时 iOS 默认上报为 `phone`，与旧行为一致。
  - `device_info.dart` 已改为优先读取编译期 `device`，再回退平台默认（Android/iOS 默认 `phone`），不影响现有 Android/Windows 打包。
- iOS 工程（`ios/`）：
  - `Podfile`：`platform :ios, '13.0'`（见下「为什么最低 iOS 13」）。
  - `Info.plist`：App 显示名 `UltraLightProbe`；ATS 允许 http 备用服务器；声明
    `BGTaskSchedulerPermittedIdentifiers` 与后台 `fetch` 模式，用于 iOS 13+ 的后台刷新。
  - `AppDelegate.swift`：注册 workmanager 的 `BGAppRefreshTask`
    （标识符 `com.example.probeApp.iOSBackgroundRefresh`，约 15 分钟一次，由 iOS 决定实际时机）。
  - `main_full.dart`：iOS 启动时初始化 workmanager 后台刷新，回调里执行一次 `ReporterService.onWake()`。
    前台行为不变（App B：WebView 控制台 + Dart 后台上报）。

## 打包步骤（在 Mac 上）

前置：安装 Xcode（含 Xcode Command Line Tools）与 CocoaPods，并 `flutter doctor` 通过。

```bash
cd flutter
flutter pub get

# 方案 A：直接用免费/付费 Apple ID 装到真机调试（先在 Xcode 里登录 Apple ID 并选 Team）
open ios/Runner.xcworkspace
#   - Signing & Capabilities → Team 选你的 Apple ID
#   - Bundle Identifier 建议改成你自己的，例如 com.yiyongtao.babyphone
#   - 连上宝宝手机 → Run

# 方案 B：命令行构建 Release（需要已配好签名，能出 ipa）
flutter build ipa --release --dart-define=device=宝宝手机
# 产物在 build/ios/ipa/*.ipa，可用 Apple Configurator / TestFlight / 导出后安装

# 只做校验不签名（检查能否编译，App 不可安装）
flutter build ios --release --dart-define=device=宝宝手机 --no-codesign
```

- 真机后台刷新只能真机验证（模拟器不支持）。
- iOS 首次可能要好几天才学会你的使用习惯并稳定触发后台刷新，属系统机制，非 bug。

## 为什么最低 iOS 13（不是 12）

后台刷新用的 `workmanager` 插件 podspec 强制 `deployment_target = 13.0`：
CocoaPods 不允许“pod 最低版本高于 App 目标版本”的安装。所以保留该插件即无法声明 iOS 12。

若确需支持 iOS 12，只能走**已废弃的 Background Fetch** 路线：

1. 从 `ios/Podfile` 移除 workmanager 的 iOS pod（fork 一份把 podspec 最低版本降到 12.0 或手动排除）；
2. `Info.plist` **不能**包含 `BGTaskSchedulerPermittedIdentifiers`（它的存在会禁用旧版
   `performFetch` 回调），只保留 `UIBackgroundModes: fetch`；
3. 在 `AppDelegate` 里 `setMinimumBackgroundFetchInterval` + `performFetch`，
   把事件转发给 Dart 执行一次 `onWake()`。

代价是需要长期维护一个 workmanager 的 iOS fork，且 iOS 12 已是 Apple 不更新的系统
（iPhone 6s 及以上都能升到 iOS 13+）。建议先用 iOS 13+ 方案。

## iOS 平台固有限制（透明告知）

- iOS 不允许 App 读取其它 App 的前台窗口/标题（没有 Android 无障碍机制），
  因此宝宝手机上只能上报本 App 自身的运行状态与周期性保活（窗口显示如
  `iOS background monitor`），做不到 QQ/哔哩哔哩 那样的窗口标题级监控。
- 后台执行由 iOS 系统调度，每次约 30 秒；不能像 Android 前台服务一样常驻。

## 不影响 Android / Windows

- Android 侧能力保留：`flutter build apk --dart-define=device=xxx` 仍可出包
  （默认不带参数仍等于 `phone`，与改动前一致）。
- Windows 仍按 exe 文件名识别设备（`probe-notebook.exe`/`probe-desktop.exe`）。
