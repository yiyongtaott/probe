# Codex 交接：Probe 上报与 CF 控制台

更新时间：2026-06-13
工作目录：`D:\aMyDrivesF\develop\java-project\demo\probe`

本目录后续只保留这一份交接文件。旧截图、旧阶段记录、旧待修复清单已经合并到本文，不再单独保留。

## 后续工作重心

1. C Probe：继续以 `c\UltraLightProbe.c` 作为高质量基准，关注上报逻辑、会话边界、离线队列、idle/锁屏处理、窗口标题准确性。
2. Flutter APK：继续围绕 Android 后台上报、无障碍标题抓取、隐私白名单、锁屏/息屏、事件驱动上报进行修复。
3. Cloudflare Worker / CF 控制台：`worker.js` 目前同时承载 API 和单页面前端，后续要关注接收逻辑，并将 CF 单页面拆成多页面。

## 当前关键路径

- C Probe：`D:\aMyDrivesF\develop\java-project\demo\probe\c\UltraLightProbe.c`
- CF Worker：`D:\aMyDrivesF\develop\java-project\demo\probe\worker.js`
- Flutter 项目：`D:\aMyDrivesF\develop\java-project\demo\probe\flutter`
- Android APK：`D:\aMyDrivesF\develop\java-project\demo\probe\flutter\probe-phone.apk`
- Android SDK：`D:\aMyDrivesF\app\Android\Sdk`
- ADB：`D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe`
- 使用现有 JDK，不要重复下载：
  `D:\aMyDrivesF\JAVA\IntelliJ IDEA 2019.2.3\jdk-17.0.12`
- 手机：realme RMX3708，Android 13 / realme UI 4.0
- 线上控制台/API：`https://flandretiamat.dpdns.org/`

## 最新 Android APK

最新已构建并安装到手机：

`D:\aMyDrivesF\develop\java-project\demo\probe\flutter\probe-phone.apk`

SHA256：

`DDF809C095AB74469E0E4BB1D98C1FA34F2B4B4F802CBEE5BEDBD8AF23D1F342`

构建命令：

```powershell
cd D:\aMyDrivesF\develop\java-project\demo\probe\flutter
$env:JAVA_HOME='D:\aMyDrivesF\JAVA\IntelliJ IDEA 2019.2.3\jdk-17.0.12'
$env:Path="$env:JAVA_HOME\bin;$env:Path"
$env:GRADLE_OPTS='-Xmx4096m -Dorg.gradle.jvmargs=-Xmx4096m'
flutter build apk --release -t lib\main_full.dart --dart-define=device=phone
Copy-Item .\build\app\outputs\flutter-apk\app-release.apk .\probe-phone.apk -Force
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe install -r .\probe-phone.apk
```

验证命令：

```powershell
flutter analyze
flutter test
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe shell settings get secure enabled_accessibility_services
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe shell dumpsys activity services com.example.probe_app
```

最近验证结果：

- `flutter analyze` 通过。
- `flutter test` 通过。
- APK 已 `adb install -r`。
- 无障碍服务启用：`com.example.probe_app/com.example.probe_app.ProbeAccessibilityService`
- 前台 service 运行：`id.flutter.flutter_background_service.BackgroundService`，`isForeground=true`，`foregroundId=888`

## Flutter APK 当前实现状态

设备 ID：

- Android/iOS 固定返回 `phone`。
- 不再使用 `phone1` / `phone2`。

Android 后台：

- 使用 `flutter_background_service` 常驻前台服务。
- WorkManager 现在只做 service 兜底拉起，不再直接调用 `ReporterService.onWake()`，避免和前台 service 双路径竞争写 `OfflineCache`。
- 开机自启仍通过 foreground service/WorkManager 配置兜底；realme 系统上的厂商自启动限制仍可能需要用户系统设置配合。

Android 前台窗口/标题：

- 依赖无障碍服务 `ProbeAccessibilityService.kt`。
- 无障碍服务写入：
  `/data/user/0/com.example.probe_app/files/probe_accessibility_window.json`
- 原生屏幕状态写入：
  `/data/user/0/com.example.probe_app/files/probe_device_state.json`
- Dart 侧 `DeviceInfo.getForegroundApp()` 优先读取屏幕状态，息屏/锁屏时不回退到 UsageStats 的最后 app。

隐私与白名单：

- 只有 `com.tencent.mobileqq` 和 `tv.danmaku.bili` 允许读取页面文本。
- 其他 app 只允许显示应用名，例如 `设置`、`Edge`、`系统桌面`。
- 输入框、密码框、`EditText`、password/passwd/pwd 相关 viewId/inputType 均跳过。
- 输入法包 `com.iflytek.inputmethod` 被忽略。

锁屏/息屏：

- 新增 `ProbeDeviceState.kt`，监听 `ACTION_SCREEN_OFF`、`ACTION_SCREEN_ON`、`ACTION_USER_PRESENT`、`ACTION_USER_UNLOCKED`。
- 息屏显示 `系统息屏`，锁屏显示 `系统锁屏`。
- 息屏/锁屏不发 keepalive。
- 已在线上历史看到 `系统息屏`、`系统锁屏` session。

事件驱动：

- `ReporterService.startContinuousLoop()` 监听无障碍窗口文件和设备状态文件变化。
- 窗口变化会即时触发 session roll，120 秒定时器只做兜底。
- onWake 已串行化，避免文件事件、手动唤醒、定时器重入导致 session 边界乱序。

离线队列/网络：

- `OfflineCache.maxEntries = 200`，超限丢弃最旧条目。
- keepalive 成功后触发 `OfflineCache.autoFlush()`。
- HTTP timeout 为 10 秒。
- `cacheRefreshMs = 5min` 已实现为 wifi/ip/battery 慢缓存。

## QQ / B 站标题规则现状

QQ：

- 正常主界面：`QQ`
- 群聊/聊天页：优先上方标题区域。
- 已过滤或降权：
  - `资料卡`、`个人资料卡`
  - `某某的资料卡`
  - `某某的个人资料`
  - `查看...资料`
  - 头像/profile/card/head/face/avatar 相关 viewId
  - `在线 - 4G`、`听筒模式`、`你加入了群聊`、`LV...`、底部 tab/按钮等低价值文本
- 注意：线上历史里如果看到 `QQ - ...的资料卡`，大概率是修复前旧记录。修复后的 APK 哈希见上文。
- 如果用户再次遇到某个群聊标题误抓，打开目标页面后执行：

```powershell
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe shell uiautomator dump /sdcard/window.xml
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe exec-out cat /sdcard/window.xml
```

然后按真实节点继续调整 `ProbeAccessibilityService.chooseTitle()` 和 QQ 低价值规则。

B 站：

- 支持短视频、横向视频、评论区打开、键盘打开等场景。
- 评论区/输入框场景会尽量复用上一条有意义视频标题，避免抓评论、输入内容、`x人在观看`。
- 已过滤 `UP主头像`、播放/观看数、评论数、`点我发弹幕`、`弹幕输入框`、作者粉丝等低价值文本。
- B 站广告/返回首页按钮等个别 UI 文案仍可能被误判；后续若继续优化，优先在 `ProbeAccessibilityService.kt` 加低价值文本和 viewId 规则。

非白名单：

- `设置` 已修正为 `设置`，不再显示 `com.android.settings/androidx.recyclerview.widget.RecyclerView`。
- `Edge` 只显示应用名，不抓网页标题。这是为了满足“QQ、B站之外不抓文本”的隐私白名单要求。

## C Probe 当前基准

`c\UltraLightProbe.c` 是当前认为较成熟的上报器：

- Win32 原生事件驱动，`SetWinEventHook` 监听前台窗口变化。
- 120 秒 housekeeping timer。
- 30 分钟 checkpoint。
- 240 秒 keepalive。
- 5 分钟慢缓存刷新 lan/wifi/battery。
- idle/锁屏处理。
- bounded offline ring buffer：
  - `PENDING_CAP = 128`
  - `PENDING_ENTRY = 2048`
- 设备 ID 可由 exe 名或 `--device` 决定：
  - `probe-notebook.exe` -> `notebook`
  - `probe-desktop.exe` -> `desktop`
  - `--device <id>` 可覆盖

后续 Flutter APK 的上报逻辑应尽量继续对齐 C Probe 的行为，而不是让两端策略分叉。

## Cloudflare Worker / CF 页面现状

入口文件：`worker.js`

当前 Worker 同时承担：

- API 接收：
  - `POST /api/report/{device_id}`
  - `GET /api/sync`
  - `GET /api/history`
  - `POST /api/chat`
  - `POST /api/heartbeat`
  - `POST /api/ai-summary`
  - `GET /api/ai-data`
  - `GET /api/ai-usage`
  - `POST /api/models`
  - `DELETE /api/device/{id}`
  - `DELETE /api/devices`
- 前端页面：
  - `GET /` 返回内嵌 HTML/CSS/JS 单页面。
- D1 数据：
  - `devices`
  - `activity_history`
  - `messages`
  - `online_users`
  - `ai_usage`

接下来要做：

- 先稳住 `/api/report/{device_id}` 的兼容性，保持 C Probe 和 Flutter APK 都能上报 JSON payload。
- 评估 `mergeSessions()`、历史查询、设备在线状态的接收/合并逻辑，避免前端显示误导。
- 把单页面拆成多页面/模块时，先不要改 API 行为。建议先拆出：
  - 设备总览页
  - 历史记录页
  - AI 总结页
  - 聊天/在线用户页
  - 设置/模型页
- 拆分前先确认 Cloudflare Worker 的部署方式和静态资源策略。当前项目看起来仍是单 `worker.js` 直接部署。

## 常用线上检查

```powershell
curl.exe -s "https://flandretiamat.dpdns.org/api/sync?since=0"

$end=[DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$start=$end-1800000
curl.exe -s "https://flandretiamat.dpdns.org/api/history?device=phone&start=$start&end=$end&pageSize=20"
```

Android 日志：

```powershell
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe logcat -d -v time |
  Select-String -Pattern 'UltraLightProbe|ProbeAccessibility|ProbeDeviceState|report phone|keepalive phone|session switch|FATAL EXCEPTION|AndroidRuntime'
```

打开测试 app：

```powershell
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe shell monkey -p com.tencent.mobileqq -c android.intent.category.LAUNCHER 1
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe shell monkey -p tv.danmaku.bili -c android.intent.category.LAUNCHER 1
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe shell am start -a android.settings.SETTINGS
D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe shell monkey -p com.microsoft.emmx -c android.intent.category.LAUNCHER 1
```

## 主要修改文件

Android / Flutter 重点：

- `flutter/lib/shared/utils/device_info.dart`
- `flutter/lib/shared/background/reporter_service.dart`
- `flutter/lib/main_full.dart`
- `flutter/lib/main_reporter.dart`
- `flutter/android/app/src/main/kotlin/com/example/probe_app/ProbeAccessibilityService.kt`
- `flutter/android/app/src/main/kotlin/com/example/probe_app/ProbeDeviceState.kt`
- `flutter/android/app/src/main/kotlin/com/example/probe_app/ProbeApplication.kt`
- `flutter/android/app/src/main/kotlin/com/example/probe_app/MainActivity.kt`

CF / C 重点：

- `worker.js`
- `c/UltraLightProbe.c`

## 工作区注意事项

- 当前 git 工作区是 dirty 状态，包含本轮修改和历史生成产物。
- 不要执行 `git reset --hard`、`git checkout -- .` 之类会丢用户/历史改动的命令，除非用户明确要求。
- `flutter/probe-phone1.apk` 是旧包，应忽略。
- `要求` 文件夹已清理为只保留本文；后续新对话优先读本文，再读源码。

