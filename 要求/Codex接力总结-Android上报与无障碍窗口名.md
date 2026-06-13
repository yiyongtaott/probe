# Codex 接力总结：Android 上报与无障碍窗口名

更新时间：2026-06-13
工作目录：`D:\aMyDrivesF\develop\java-project\demo\probe`

## 用户目标

修复 Flutter Android 版 Probe：

- Android app 能稳定后台上报，设备 ID 固定为 `phone`。
- 不 root 的情况下，前台窗口名不要显示 `com.tencent.mobileqq/com.tencent.mobileqq.activity.SplashActivity` 这种技术字符串。
- 可以使用无障碍模式读取真实前台窗口标题。
- QQ/B 站至少应显示为 `QQ`、`哔哩哔哩`，有可用页面标题时显示为 `应用名 - 标题`。
- 只需要构建一份 APK。
- 用户已有多套 JDK，不要重复下载 JDK。

## 环境与路径

- Flutter 项目：`D:\aMyDrivesF\develop\java-project\demo\probe\flutter`
- 最终 APK：`D:\aMyDrivesF\develop\java-project\demo\probe\flutter\probe-phone.apk`
- Android SDK：`D:\aMyDrivesF\app\Android\Sdk`
- 已使用 JDK：`D:\aMyDrivesF\JAVA\IntelliJ IDEA 2019.2.3\jdk-17.0.12`
- 测试手机：realme RMX3708，Android 13 / realme UI 4.0
- adb：`D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe`

注意：`flutter\probe-phone1.apk` 是旧包，曾因 Windows 文件占用无法删除，后续应忽略。

## 当前 APK 状态

最终 APK：

`D:\aMyDrivesF\develop\java-project\demo\probe\flutter\probe-phone.apk`

最近一次大小约 `20537480` bytes，已安装到手机。安装后确认：

```powershell
adb shell settings get secure enabled_accessibility_services
# com.example.probe_app/com.example.probe_app.ProbeAccessibilityService

adb shell settings get secure accessibility_enabled
# 1
```

签名验证通过 v1/v2：

```powershell
D:\aMyDrivesF\app\Android\Sdk\build-tools\35.0.0\apksigner.bat verify --verbose .\build\app\outputs\flutter-apk\app-release.apk
```

## 关键修复

### 1. Android 前台服务崩溃

之前 realme UI 4.0 打开 app 闪退，关键崩溃为：

`CannotPostForegroundServiceNotificationException: Bad notification for startForeground`

修复：

- 新增 `ProbeApplication.kt`
- 在进程启动时创建通知渠道：
  - `probe_reporter`
  - `FOREGROUND_DEFAULT`
- Manifest 中 `android:name=".ProbeApplication"`

### 2. 后台上报与开机自启

当前 Android 使用：

- `flutter_background_service` 前台服务
- `WorkManager` 作为兜底周期任务
- `RECEIVE_BOOT_COMPLETED`
- `setAutoStartOnBootMode(true)`
- `WorkManager` 周期任务使用 `ExistingWorkPolicy.replace`，避免旧的 `phone1` input data 残留

上报日志示例：

```text
initialize android reporter device=phone
service wake reason=manual device=phone
report phone -> 9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa 200
keepalive phone -> 9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa 200
```

### 3. 设备 ID

`DeviceInfo.detectDeviceId()` 和同步版本已改为 Android/iOS 固定返回：

```dart
phone
```

不再使用 `phone1` / `phone2`。

### 4. 前台窗口名

新增无障碍服务：

- `flutter/android/app/src/main/kotlin/com/example/probe_app/ProbeAccessibilityService.kt`
- `flutter/android/app/src/main/res/xml/probe_accessibility_service.xml`
- `flutter/android/app/src/main/res/values/strings.xml`

Manifest 注册：

- `BIND_ACCESSIBILITY_SERVICE`
- `PACKAGE_USAGE_STATS`
- `QUERY_ALL_PACKAGES`

`MainActivity.kt` 提供 MethodChannel：

- `hasAccessibilityAccess`
- `openAccessibilitySettings`

Flutter 读取优先级：

1. 读取无障碍服务写入的 JSON：
   - `/data/user/0/com.example.probe_app/files/probe_accessibility_window.json`
   - `/data/data/com.example.probe_app/files/probe_accessibility_window.json`
2. 如果 UsageStats 能确认当前包名，则只接受同包名的无障碍 display，避免旧缓存污染。
3. UsageStats 兜底，已给常用包名做 label mapping：
   - `com.tencent.mobileqq` -> `QQ`
   - `tv.danmaku.bili` -> `哔哩哔哩`

无障碍服务核心规则：

- 优先使用 `event.packageName`，不优先信任 `rootInActiveWindow`，防止切换瞬间 root 还是上一个窗口。
- 只有 root 包名和 event 包名一致时，才从 root 提取页面标题。
- 过滤状态栏、信号、电量、蓝牙、闹钟、Wi-Fi/WLAN、纯数字角标、时间、常见 tab 文案。
- 忽略系统浮层：
  - `com.android.systemui`
  - `com.coloros.smartsidebar`
  - `com.oplus.smartsidebar`
  - `com.iflytek.inputmethod`
- 页面标题可信时输出 `应用名 - 标题`，否则只输出应用名。

已验证：

```text
ProbeAccessibility: display=QQ - 账户及设置 package=com.tencent.mobileqq
ProbeAccessibility: display=哔哩哔哩 - FlandreTiamat package=tv.danmaku.bili
```

之前错误输出：

```text
com.tencent.mobileqq - 手机信号满格
tv.danmaku.bili - 3
```

已修复。

## 主要变更文件

重点文件：

- `flutter/lib/shared/utils/device_info.dart`
- `flutter/lib/shared/background/reporter_service.dart`
- `flutter/lib/shared/utils/probe_log.dart`
- `flutter/lib/main_full.dart`
- `flutter/android/app/src/main/AndroidManifest.xml`
- `flutter/android/app/src/main/kotlin/com/example/probe_app/MainActivity.kt`
- `flutter/android/app/src/main/kotlin/com/example/probe_app/ProbeApplication.kt`
- `flutter/android/app/src/main/kotlin/com/example/probe_app/ProbeAccessibilityService.kt`
- `flutter/android/app/src/main/res/xml/probe_accessibility_service.xml`
- `flutter/android/app/src/main/res/values/strings.xml`
- `flutter/android/app/build.gradle.kts`
- `flutter/android/build.gradle.kts`
- `flutter/pubspec.yaml`
- `flutter/pubspec.lock`

还有 Windows/desktop 相关改动存在于工作区，但这份接力重点是 Android APK。

## 构建与验证命令

进入 Flutter 目录：

```powershell
cd D:\aMyDrivesF\develop\java-project\demo\probe\flutter
```

静态检查：

```powershell
flutter analyze
```

测试：

```powershell
flutter test
```

构建：

```powershell
flutter build apk --release -t lib\main_full.dart --dart-define=device=phone
```

复制最终 APK：

```powershell
Copy-Item -LiteralPath .\build\app\outputs\flutter-apk\app-release.apk -Destination .\probe-phone.apk -Force
```

验签：

```powershell
D:\aMyDrivesF\app\Android\Sdk\build-tools\35.0.0\apksigner.bat verify --verbose .\build\app\outputs\flutter-apk\app-release.apk
```

安装：

```powershell
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe install -r .\probe-phone.apk
```

看无障碍服务输出：

```powershell
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe logcat -d -v time | Select-String -Pattern 'ProbeAccessibility|FATAL EXCEPTION|AndroidRuntime'
```

打开 QQ/B 站测试：

```powershell
adb shell monkey -p com.tencent.mobileqq -c android.intent.category.LAUNCHER 1
adb shell monkey -p tv.danmaku.bili -c android.intent.category.LAUNCHER 1
```

检查上报：

```powershell
adb logcat -d -v time | Select-String -Pattern 'initialize android reporter|service wake|session start|session switch|report phone|keepalive phone|FATAL EXCEPTION'
```

## 后续如果继续优化

如果用户想让 QQ 聊天页显示更精确的“联系人名/群名”，让用户打开目标聊天页后抓 UI：

```powershell
adb shell uiautomator dump /sdcard/window.xml
adb exec-out cat /sdcard/window.xml
```

然后根据 QQ 页面真实节点文本，继续调整 `ProbeAccessibilityService.chooseTitle()` 的筛选规则。

如果上报又显示旧窗口，优先检查：

1. 无障碍服务是否仍开启。
2. `ProbeAccessibility` 日志当前写入的 display/pkg。
3. `DeviceInfo._getAndroidForegroundApp()` 是否被 UsageStats 兜底误判。
4. realme/ColorOS 是否又出现新的系统浮层包名，需要加入 `ignoredPackages`。

## 工作区注意事项

当前仓库是 dirty 状态，包含用户/历史改动。不要执行：

```powershell
git reset --hard
git checkout -- .
```

除非用户明确要求。继续工作时只改相关文件。

