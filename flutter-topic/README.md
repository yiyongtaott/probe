# Tulpa Topic Engine

一个利用宿主真实浏览行为，持续生成 Tulpa 对话话题的 Topic Engine。

> 本文档同时作为产品设计说明、AI 开发指南和构建安装手册。

---

## 一、产品定位

**持续为宿主提供源源不断、贴合自身生活的话题。**

话题来自宿主每天最真实的浏览行为，而不是随机生成。

- 不是 AI 聊天软件
- 不是 Tulpa 模拟器
- AI 不扮演 Tulpa、不陪聊、不创作人格
- AI 只是一个整理工具

---

## 二、设计理念

宿主每天浏览大量内容：新闻、视频、小说、漫画、社交平台、技术文章、游戏资讯……这些内容天然就是 Tulpa 对话最好的素材。

但是：
- 宿主通常不会主动记住它们
- 真正准备塑造时，已经忘记今天看过什么
- 最终只能面对一个空白聊天框

因此，产品需要成为一个**话题发动机（Topic Engine）**：
- 每天自动收集宿主真正关注过的信息
- 在最合适的时候，把这些内容重新整理成可以讨论的话题

---

## 三、核心流程

```
手机浏览行为
  ↓
无障碍服务
  ↓
抓取标题
  ↓
本地过滤
  ↓
生成今日素材池
  ↓
算法分析
  ↓
判断推送时机
  ↓
生成一个讨论话题
  ↓
宿主开始与 Tulpa 对话
  ↓
聊天记录进入记忆库
```

整个流程只有最后一步需要宿主参与，前面均自动完成。

---

## 四、设计边界

| 禁止 | 允许 |
|------|------|
| AI 扮演 Tulpa | 总结浏览内容 |
| AI 回复聊天 | 聚类素材 |
| AI 推测 Tulpa 性格 | 生成讨论入口 |
| AI 编造 Tulpa 喜好 | 判断推送时机 |
| AI 自动补全档案 | 提取聊天中的事实 |
| AI 主导聊天方向 | |

聊天窗口**不区分宿主/Tulpa**，所有内容作为一个连续记录。
AI 只负责：浏览标题总结、素材聚类、生成讨论话题。
所有数据均本地保存。

---

## 五、浏览内容收集

使用 Android Accessibility Service 采集：
- 页面标题
- 页面 App 来源
- 时间

例如：
```
知乎 — 为什么人会孤独
Bilibili — 赛博朋克音乐推荐
微博 — SpaceX 再次发射成功
```

**不保存**：页面正文、图片、视频、用户输入内容、聊天内容。
所有采集均在本地完成。

**隐私白名单**（Kotlin 层）：
- 允许抓标题：QQ、Bilibili、知乎、微博、今日头条、微信
- 仅显示应用名：其他所有 App
- 跳过：输入框/密码框/EditText
- 忽略包：com.android.systemui、coloros.smartsidebar、iflytek.inputmethod

---

## 六、素材池（Daily Material Pool）

每天生成一个素材池。不是浏览记录，而是经过聚类后的主题。素材池每天更新，昨天的数据自动过期。

例如：
```
今天浏览：机器人、宇宙、孤独、睡眠、猫、历史、程序设计
```

### 算法 1：Material Ranking
- 考虑：浏览次数、停留时间（可选）、最近浏览时间、来源类型、是否重复出现
- 按标题聚类（不区分大小写）→ 综合评分排序
- 输出：Top N 素材

### 算法 2：Topic Generation
- 输入：Top N 素材
- 输出：一个自然的问题
- 要求：不评价宿主、不扮演 Tulpa、不生成设定、只负责打开讨论

---

## 七、推送算法

推送不按照时间，按照状态。

例如：长时间刷短视频 → 突然退出，说明注意力出现释放窗口。此时生成一个话题并通过系统通知推送。

注意力释放检测（AttentionTracker）：
- 沉浸时长阈值：5 分钟
- 沉浸式 App：抖音/快手/哔哩哔哩/小红书/微博/今日头条/QQ/微信
- 检测逻辑：持续沉浸 → 切换 App → 触发话题生成 + 通知

---

## 八、项目架构

```
flutter-topic/
├── lib/
│   ├── main.dart                         # 入口 + 5-tab 导航 + IndexedStack
│   ├── shared/
│   │   ├── models/models.dart            # 所有数据模型
│   │   ├── storage/database.dart         # SQLite (sqflite) — 全部 CRUD
│   │   ├── ai/ai_provider.dart           # 5 个 AI Provider 实现
│   │   ├── engine/
│   │   │   ├── topic_engine.dart         # Algorithm 1 Ranking + Algorithm 2 Generation
│   │   │   └── attention_tracker.dart    # 注意力释放窗口检测 + 素材采集
│   │   ├── services/
│   │   │   ├── background_service.dart   # 后台编排器（单例）
│   │   │   ├── notification_service.dart # 系统通知
│   │   │   └── ai_config_manager.dart   # AI 配置持久化
│   │   └── utils/
│   │       ├── device_info.dart          # 前台窗口监控 + 无障碍文件读取 + 白名单管理
│   │       └── app_log.dart              # 日志工具
│   └── ui/
│       ├── home_page.dart                # 今日素材 + 话题建议 + 生成按钮
│       ├── material_page.dart            # 素材池（聚类 + 浏览记录）
│       ├── chat_page.dart                # 对话窗口（连续记录、AI 不参与）
│       ├── conversations_page.dart       # 历史对话列表
│       ├── settings_page.dart            # AI 配置 + 无障碍 + 数据管理
│       └── debug_page.dart               # 调试页：白名单配置 + 实时状态
└── android/
    └── app/src/main/kotlin/com/example/tulpa_topic/
        ├── TulpaAccessibilityService.kt  # 无障碍服务（标题抓取 + 退出检测 + 通知推送）
        ├── TulpaKeepAliveService.kt      # 前台保活服务（:accessibility 进程）
        ├── TulpaBootReceiver.kt          # 开机自启保活
        ├── TulpaRestartReceiver.kt       # 服务销毁后重启
        ├── MainActivity.kt               # MethodChannel（getInstalledApps / getWhitelist / setWhitelist）
        └── TulpaApplication.kt           # 通知渠道
```

---

## 九、关键设计决策

### AI Provider
- 支持：OpenAI 兼容 / Anthropic / Gemini / Ollama / 自定义 URL+Key
- 用户在设置页配置 (provider, baseUrl, apiKey, model)
- Ollama 不需要 apiKey
- 未配置 AI 时，话题生成/聚类功能静默跳过

### 动态白名单（Flutter ↔ Kotlin 共享）
- 使用 `tulpa_whitelist.json` 保存在应用内部存储，避免 SharedPreferences 多进程同步问题
- Flutter 调试页提供搜索 + Switch 开关配置
- Kotlin 侧 `FileObserver` 实时监听文件变动并热加载
- 首次运行写入默认白名单，后续完全信任用户配置

### 应用退出检测 + 通知推送
- Kotlin 层在 `TYPE_WINDOW_STATE_CHANGED` 事件中检测白名单应用退出
- 切出到桌面/非白名单应用时，即时推送固定通知（AI 话题总结占位）
- 30 秒去重节流，避免频繁通知

### 服务保活
- `TulpaAccessibilityService.onServiceConnected()` 调用 `startForeground()`
- `TulpaKeepAliveService` 运行在 `:accessibility` 进程，START_STICKY + 自我重启
- `TulpaBootReceiver` 开机自动启动保活服务
- `TulpaRestartReceiver`（非导出）接收服务销毁广播并重启
- 清后台后无障碍服务进程仍然存活

---

## 十、构建与安装

### 环境变量

```powershell
$env:JAVA_HOME='D:\aMyDrivesF\JAVA\IntelliJ IDEA 2019.2.3\jdk-17.0.12'
$env:Path="$env:JAVA_HOME\bin;$env:Path"
$env:GRADLE_OPTS='-Xmx4096m -Dorg.gradle.jvmargs=-Xmx4096m'
```

### 构建 APK

```powershell
cd D:\aMyDrivesF\develop\java-project\demo\probe\flutter-topic
flutter pub get
flutter build apk --release
```

APK 输出路径：`build\app\outputs\flutter-apk\app-release.apk`

### 无线调试连接（WLAN ADB）

> **注意**：当前调试方式已从 USB 数据线改为 WLAN 无线调试。手机的 IP 地址和端口号每次连接可能不同，以下以 `192.168.10.4:39997` 为例。

#### 第一次连接（需要 USB 数据线）

1. 手机开启「开发者选项」和「USB 调试」
2. 用数据线连接电脑
3. 执行以下命令开启无线调试端口：

```bash
adb tcpip 5555
```

4. 拔掉数据线

#### 后续连接（无线）

1. 确保手机和电脑在同一个 WiFi 网络下
2. 查看手机的 WLAN IP 地址（设置 → 关于手机 → 状态信息）
3. 连接：

```bash
# 格式：adb connect <手机IP>:<端口>
adb connect 192.168.10.4:39997
```

4. 验证连接：

```bash
adb devices
# 输出示例：
# List of devices attached
# 192.168.10.4:39997   device
```

> **提示**：连接成功后，后续命令可直接使用 `adb shell`（不需要 `-s` 参数）；如果同时连接了多个设备，需要用 `-s 192.168.10.4:39997` 指定目标设备。

### 安装到手机（ColorOS / realme UI）

> ⚠️ **关键**：ColorOS / realme UI 等系统会在 `adb install` 时弹出一个**「继续安装」确认对话框**。这个对话框会阻塞安装进程——**如果不点击，`adb install` 将永远卡死**。
>
> 实测数据（realme RMX3708 / ColorOS）：
> - 从执行 `adb install` 到对话框出现约 **14 秒**
> - 点击「继续安装」后约 **2 秒** 安装完成
> - 总耗时约 **16 秒**
>
> ❌ **绝对禁止**：直接执行 `adb install` 然后死等。它会卡在对话框直到永远。
>
> ❌ **禁止串行**：把 `adb install` 和 `sleep + tap` 放在**同一个阻塞命令**里串行执行。`adb install` 会卡住，后面的 `sleep` 永远执行不到。
>
> ✅ **正确做法**：`adb install` 放到**后台**运行，`sleep` 和 `tap` 在前台顺序执行，最后用 `wait` 等待安装自然结束。

---

### 单命令后台运行（唯一推荐方案）

**Bash / Git Bash**：
```bash
APK="D:/aMyDrivesF/develop/java-project/demo/probe/flutter-topic/build/app/outputs/flutter-apk/app-release.apk"
ADB="D:/aMyDrivesF/app/Android/Sdk/platform-tools/adb.exe"

"$ADB" install -r -d "$APK" &
sleep 15
"$ADB" shell input tap 345 2247
wait
echo "Done"
```

**CMD（Windows）**：
```cmd
start "" "D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe" install -r -d "D:\aMyDrivesF\develop\java-project\demo\probe\flutter-topic\build\app\outputs\flutter-apk\app-release.apk" && timeout /t 15 /nobreak >nul && "D:\aMyDrivesF\app\Android\Sdk\platform-tools\adb.exe" shell input tap 345 2247
```

**为什么这样是对的**：
- `&`（Bash）或 `start ""`（CMD）把安装放到**后台**，当前 shell **不被阻塞**
- `sleep 15`：等 14 秒（实测弹出时间）+ 1 秒缓冲
- `adb shell input tap`：点击「继续安装」，释放被卡住的安装进程
- `wait`：等待后台的 `adb install` 自然结束（约 2 秒后），**立刻返回**，不会傻等超时

---

### ⚠️ AI Agent 特别注意

如果你让 AI 帮你执行安装，**绝对不要** spawn 两个并行的阻塞 basher（一个 `adb install` 设 30 秒超时，一个 `sleep` 后点击）。这会导致：
- 安装明明 16 秒就完成了，却因为 basher 的 30 秒超时而傻等到 30 秒
- 用户体验极差

**AI 应该直接把上面的单命令发给用户执行，或者自己执行单命令。**

---

### 坐标校准

如果 `(345, 2247)` 不准确，dump UI 获取精确坐标：
```bash
adb shell "uiautomator dump /data/local/tmp/ui_inst.xml"
adb shell "cat /data/local/tmp/ui_inst.xml | grep -o 'text=\"继续安装\"[^>]*bounds=\"[^\"]*\"'"
# 输出示例：text="继续安装" bounds="[84,2170][606,2324]"
# 中心坐标 = ((84+606)/2, (2170+2324)/2) = (345, 2247)
```

### 安装后权限设置

APK 安装完成后，需要授予以下权限才能使 App 正常工作：

| 权限 | 说明 |
|------|------|
| `POST_NOTIFICATIONS` | 推送通知权限（Android 13+） |
| `ACCESS_RESTRICTED_SETTINGS` | 访问受限设置 |
| `SYSTEM_ALERT_WINDOW` | 悬浮窗权限 |
| `RUN_IN_BACKGROUND` / `RUN_ANY_IN_BACKGROUND` | 后台运行权限 |
| 无障碍服务 | 抓取浏览内容 |
| 省电白名单 | 防止系统杀后台 |

> **注意**：以下命令中的 `-s 192.168.10.4:39997` 为设备标识，请根据 `adb devices` 的实际输出替换。如果已通过 `adb connect` 连接且只有一个设备在线，可直接去掉 `-s` 参数。

**一键设置所有权限（推荐）：**

```bash
adb -s 192.168.10.4:39997 shell "
  pm grant com.example.tulpa_topic android.permission.POST_NOTIFICATIONS &&
  appops set com.example.tulpa_topic ACCESS_RESTRICTED_SETTINGS allow &&
  appops set com.example.tulpa_topic SYSTEM_ALERT_WINDOW allow &&
  settings put secure enabled_accessibility_services \
    com.example.tulpa_topic/com.example.tulpa_topic.TulpaAccessibilityService &&
  settings put secure accessibility_enabled 1 &&
  dumpsys deviceidle whitelist +com.example.tulpa_topic &&
  cmd appops set com.example.tulpa_topic RUN_IN_BACKGROUND allow &&
  cmd appops set com.example.tulpa_topic RUN_ANY_IN_BACKGROUND allow
"
```

**逐条设置（调试用）：**

```powershell
# 通知权限
adb -s 192.168.10.4:39997 shell pm grant com.example.tulpa_topic android.permission.POST_NOTIFICATIONS

# 受限设置访问
adb -s 192.168.10.4:39997 shell appops set com.example.tulpa_topic ACCESS_RESTRICTED_SETTINGS allow

# 悬浮窗权限
adb -s 192.168.10.4:39997 shell appops set com.example.tulpa_topic SYSTEM_ALERT_WINDOW allow

# 启用无障碍服务
adb -s 192.168.10.4:39997 shell settings put secure enabled_accessibility_services com.example.tulpa_topic/com.example.tulpa_topic.TulpaAccessibilityService
adb -s 192.168.10.4:39997 shell settings put secure accessibility_enabled 1

# 省电白名单
adb -s 192.168.10.4:39997 shell dumpsys deviceidle whitelist +com.example.tulpa_topic

# 后台运行权限
adb -s 192.168.10.4:39997 shell cmd appops set com.example.tulpa_topic RUN_IN_BACKGROUND allow
adb -s 192.168.10.4:39997 shell cmd appops set com.example.tulpa_topic RUN_ANY_IN_BACKGROUND allow
```

### 验证安装

```powershell
# 检查包是否存在
adb shell pm list packages com.example.tulpa_topic

# 检查无障碍服务是否启用
adb shell settings get secure enabled_accessibility_services

# 查看服务状态
adb shell dumpsys accessibility | Select-String -Pattern 'TulpaTopic'

# 检查权限是否已授予
adb shell dumpsys package com.example.tulpa_topic | Select-String -Pattern 'permission:'
adb shell appops get com.example.tulpa_topic

# 查看日志
adb logcat -d -v time -s TulpaAccessibility
```

---

## 十一、关键 ADB 命令

```powershell
# WLAN 无线调试连接
adb connect 192.168.10.4:39997
adb devices

# 查看日志
adb logcat -d -v time -s TulpaAccessibility

# 查看无障碍窗口文件
adb shell cat /data/user/0/com.example.tulpa_topic/files/tulpa_accessibility_window.json

# 查看白名单文件
adb shell cat /data/user/0/com.example.tulpa_topic/files/tulpa_whitelist.json

# 启用无障碍服务
adb shell settings put secure enabled_accessibility_services com.example.tulpa_topic/com.example.tulpa_topic.TulpaAccessibilityService

# 打开测试 App
adb shell monkey -p tv.danmaku.bili -c android.intent.category.LAUNCHER 1
adb shell monkey -p com.tencent.mm -c android.intent.category.LAUNCHER 1

# 模拟返回桌面
adb shell input keyevent KEYCODE_HOME

# 抓取当前页面节点树（调试标题规则）
adb shell uiautomator dump /sdcard/window.xml
adb exec-out cat /sdcard/window.xml
```

---

## 十二、调试页面

App 内置调试页面（底部导航第 6 个 tab 或设置页入口）：

- 无障碍服务状态（已启用/未启用）
- 当前前台窗口实时显示
- 今日素材数量
- 注意力追踪器状态
- **白名单配置**：搜索已安装应用，Switch 开关切换白名单成员
- 手动触发：生成话题、发送测试通知、添加测试素材
- 原始无障碍 JSON 文件内容展示
- AI 连接测试

### 调试日志

Kotlin 层使用 `Log.i("TulpaAccessibility", ...)` 输出，Dart 层使用 `AppLog.info()` 输出。
通过 `adb logcat -s TulpaAccessibility` 过滤查看。

---

## 十三、数据结构

```
material_pool:     title, source_app, timestamp, topic, weight, date_key
conversation:      session_id, topic, created_at
messages:          session_id, text, timestamp, author(可选)
facts:             text, source_message_id, created_at
topic_suggestions: topic, question, context, created_at, used
daily_topics:      date_key, topics_json, created_at
```

---

## 十四、技术栈

- Flutter (Dart)
- SQLite (sqflite) 本地存储
- Android Accessibility Service (Kotlin)
- flutter_local_notifications 系统通知
- 多 AI provider 适配层

---

## 十五、代码风格规范

- 所有 Dart 文件使用 `flutter_lints` 规范
- 导入使用相对路径（`../` 形式）
- 模型类使用 `const` 构造 + `final` 字段
- 异步方法统一使用 `Future<T>`
- Kotlin 使用 `companion object` 管理常量
- 私有成员使用 `_` 前缀
- 字符串模板使用 `$var` / `${expr}`
