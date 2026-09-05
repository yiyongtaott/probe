# iOS 打包说明（宝宝手机 / UltraLightProbe）

Flutter 的 iOS 包只能用 **macOS + Xcode** 构建（Windows 上无法生成 .ipa/.app）。
本仓库已把 iOS 侧配置准备齐全，拿到任何一台 Mac（不需要改动 Android 工程）即可出包。

## 后台方案：原生 Background Fetch（iOS 12+，含 iOS 13+）

iOS 12 没有 BGTaskScheduler，能用的通用后台通道是**旧版 Background Fetch**（`performFetch`，
iOS 12 原生支持；iOS 13+ 也仍然生效，前提是 `Info.plist` 里**不要**出现
`BGTaskSchedulerPermittedIdentifiers` —— 该键一旦存在就会禁用旧回调）。

实现（全部原生，无第三方 iOS 插件）：

- `ios/Runner/AppDelegate.swift`
  - `didFinishLaunching` 里调用 `setMinimumBackgroundFetchInterval`（表示愿意接收后台抓取）；
  - 重写 `performFetchWithCompletionHandler`，通过 Flutter `MethodChannel("ultralightprobe/ios")`
    通知 Dart，Dart 侧 `main_full.dart` 收到 `backgroundFetch` 后执行一次
    `ReporterService.onWake()`（保活/会话上报，逻辑与前台一致）。
  - 冷启动竞态做了轮询重试（等待 FlutterViewController/Dart handler 就绪后调用完成回调）。
- `ios/Runner/Info.plist`：`UIBackgroundModes = fetch`；**没有**
  `BGTaskSchedulerPermittedIdentifiers`。
- 系统按“用户使用习惯”决定何时抓取，频率由 iOS 控制（非固定周期）；每次执行约 30 秒。
- 后台抓取只能**真机**验证，模拟器不会触发。

### 为什么 iOS 上不再用 workmanager

workmanager 的 iOS podspec 强制最低 **iOS 13.0**，CocoaPods 不允许“pod 最低版本高于
App 目标版本”，会把部署目标锁死在 13。为兼容 iOS 12，这里把 workmanager 本地化为
**仅 Android**（`flutter/third_party/workmanager`，删除了 ios 实现并保留 0.7.0 Android 逻辑），
iOS 端后台由上面这套原生 Background Fetch 承担。Android 行为与上游一致，不受影响。

### iOS 13+ 更现代的替代（如需 ~15 分钟 BGAppRefreshTask）

若确定只支持 iOS 13+，可改用 BGTaskScheduler 定期刷新（约 15 分钟一次，仍由系统调度）：
把 `AppDelegate` 改回注册 `BGAppRefreshTask`，并在 `Info.plist` 添加
`BGTaskSchedulerPermittedIdentifiers`。但这与 iOS 12 兼容互斥，当前默认走 12+ 原生方案。

## 上传设备名

沿用 `--dart-define=device=xxx` 机制：

- 打“宝宝手机”包传 `device=宝宝手机` → iPhone 上报归到网站第 4 台「宝宝手机」设备；
- 不传该参数 → iOS 默认 `phone`（与旧行为一致）；
- `device_info.dart` 已改为“编译期 define 优先，其次平台默认”，Android/Windows 不受影响。

## 打包步骤（在 Mac 上）

前置：Xcode（含 Command Line Tools）+ CocoaPods，`flutter doctor` 通过。

```bash
cd flutter
flutter pub get

# 方案 A：直接装到真机调试（先在 Xcode 登录 Apple ID 并选 Team）
open ios/Runner.xcworkspace
#   - Signing & Capabilities → Team 选你的 Apple ID
#   - Bundle Identifier 建议改成自己的，例如 com.yiyongtao.babyphone
#   - 连上宝宝手机 → Run（首次启动后等待几天让 iOS 学会调度后台抓取）

# 方案 B：命令行构建 Release（已配好签名，可出 .ipa）
flutter build ipa --release --dart-define=device=宝宝手机
# 产物 build/ios/ipa/*.ipa；用 TestFlight / Apple Configurator / 导出后安装

# 仅编译校验（不签名，产物不可安装）
flutter build ios --release --dart-define=device=宝宝手机 --no-codesign
```

## iOS 平台固有限制（透明告知）

- iOS 不允许 App 读取其它 App 的前台窗口/标题（无 Android 无障碍机制），
  因此宝宝手机上只能上报本 App 自身的运行状态与保活（窗口显示为
  `iOS background monitor`），做不到 QQ/哔哩哔哩 那样的窗口标题级监控。
- 后台执行由 iOS 系统调度，每次约 30 秒；不能像 Android 前台服务一样常驻。
- 旧版 Background Fetch 在 iOS 13+ 已被 Apple 标记废弃但实测仍可用；
  若 Apple 后续彻底停用旧 API，则需要升级到 iOS 13+ 的 BGTaskScheduler 路线（见上）。

## 不影响 Android / Windows

- Android 侧能力保留：`flutter build apk --dart-define=device=xxx` 仍可出包
  （不带参数默认仍为 `phone`，与改动前一致；workmanager Android 逻辑来自本地 fork，行为同 0.7.0）。
- Windows 仍按 exe 文件名识别设备（`probe-notebook.exe` / `probe-desktop.exe`）。
