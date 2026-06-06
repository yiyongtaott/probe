# UltraLightProbe 三端架构 & 移动端 App 技术方案

## 一、C Probe 浏览器标签捕获改进方案

### 当前问题

```c
// 当前：仅监听前台窗口切换
SetWinEventHook(EVENT_SYSTEM_FOREGROUND, ...)  // Alt+Tab 等窗口级切换
// 30s 定时器轮询标题（兜底）
SetTimer(NULL, 0, 30000, timer_proc)           // 浏览器内切标签靠此捕获
```

浏览器内切标签不改变前台窗口 HWND，故 `EVENT_SYSTEM_FOREGROUND` 不触发。当前靠 30s 定时器调用 `GetWindowTextW` 轮询标题来补漏，延迟 0~30s。

### 改进方案：EVENT_OBJECT_NAMECHANGE + 浏览器进程过滤

Windows 在窗口标题变化时会触发 `EVENT_OBJECT_NAMECHANGE`，而浏览器切换标签时**必定更新窗口标题**（如 `"标签名 — Edge"`）。注册一个额外 Hook 专门监听标题变化，过滤出浏览器进程即可。

#### 新增回调函数

```c
/* 浏览器标签切换：标题变化即捕获（零延迟） */
static void CALLBACK win_event_namechange_proc(HWINEVENTHOOK hHook, DWORD event, HWND hwnd,
                                                LONG idObject, LONG idChild,
                                                DWORD idThread, DWORD evTime) {
    (void)hHook; (void)event; (void)idThread; (void)evTime;
    /* 只处理顶层窗口 */
    if (idObject != OBJID_WINDOW || idChild != CHILDID_SELF) return;
    if (!hwnd || !IsWindowVisible(hwnd)) return;
    /* 只有前台窗口的标题变化才关心 */
    if (hwnd != GetForegroundWindow()) return;

    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    wchar_t name[MAX_PATH];
    if (!get_process_name(pid, name, MAX_PATH)) return;

    wchar_t lp[MAX_PATH];
    to_lower_w(name, lp, MAX_PATH);
    const wchar_t *browsers[] = {
        L"chrome", L"msedge", L"firefox", L"opera",
        L"brave", L"vivaldi", L"browse", L"iexplore"
    };
    for (int i = 0; i < sizeof(browsers)/sizeof(browsers[0]); i++) {
        if (wcsstr(lp, browsers[i])) {
            on_possible_change();
            return;
        }
    }
}
```

#### run() 中注册

```c
/* 原有：前台窗口切换 */
HWINEVENTHOOK hook = SetWinEventHook(
    EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
    NULL, win_event_proc, 0, 0,
    WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);

/* 新增：浏览器标签切换 */
HWINEVENTHOOK nameHook = SetWinEventHook(
    EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE,
    NULL, win_event_namechange_proc, 0, 0,
    WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
```

#### 效果

| 场景 | 触发机制 | 延迟 |
|---|---|---|
| Alt+Tab 切换窗口 | `EVENT_SYSTEM_FOREGROUND` | 0ms |
| 浏览器内切标签 | `EVENT_OBJECT_NAMECHANGE` | 0ms |
| 其他窗口标题变化 | 同上 | 0ms |
| 兜底（非浏览器、其他未知变化） | 30s 定时器 | ≤30s |
| 消息循环 | `GetMessage` 阻塞 | 待机功耗 ≈ 0 |

依然纯事件驱动，待机功耗不变。定时器可延长到 60s 只做纯兜底。

---

## 二、App 双端方案：Flutter 单项目双入口

### 项目结构

```
probe/
├── c/                              ← C Probe（不移动）
│   └── UltraLightProbe.c
├── worker.js                        ← CF Workers（不移动）
├── app/                             ← 新增：Flutter 项目根
│   ├── lib/
│   │   ├── main_reporter.dart       ← App A 入口：静默上报器（无 UI）
│   │   ├── main_full.dart           ← App B 入口：全功能 App（含 UI）
│   │   └── shared/
│   │       ├── api/                 ← API 客户端（双 App 共用）
│   │       │   ├── report_client.dart   ← POST /api/report/{device}
│   │       │   ├── sync_client.dart     ← GET  /api/sync
│   │       │   ├── history_client.dart  ← GET  /api/history
│   │       │   ├── chat_client.dart     ← POST /api/chat
│   │       │   ├── heartbeat_client.dart← POST /api/heartbeat
│   │       │   ├── ai_client.dart       ← POST /api/ai-summary
│   │       │   └── ai_data_client.dart  ← GET  /api/ai-data
│   │       ├── models/              ← 数据模型
│   │       │   ├── device_state.dart
│   │       │   ├── activity_record.dart
│   │       │   ├── chat_message.dart
│   │       │   └── online_user.dart
│   │       ├── background/          ← 后台上报引擎（双 App 共用）
│   │       │   ├── reporter_service.dart
│   │       │   ├── offline_cache.dart
│   │       │   └── platform_channels/  ← 平台特定（前台应用检测等）
│   │       └── utils/
│   │           ├── wifi_info.dart
│   │           ├── battery_info.dart
│   │           └── ip_info.dart
│   ├── android/
│   ├── ios/
│   └── pubspec.yaml
├── 要求/
│   └── ...（本文档）
```

### App A：纯后端静默上报器

#### 架构

```
┌──────────────────────────────────────────┐
│              Flutter Engine               │
│    （纯 Dart VM，不初始化渲染引擎）         │
│                                           │
│  ┌──────────────────────────────────┐     │
│  │  WorkManager（Android）           │     │
│  │  BGTaskScheduler（iOS）           │     │
│  │  每 15min 系统窗口唤醒             │     │
│  └──────────┬───────────────────────┘     │
│             │ onWake()                    │
│  ┌──────────▼───────────────────────┐     │
│  │  ReporterService                  │     │
│  │  1. 获取前台应用（UsageStats）     │     │
│  │  2. 获取 WiFi / IP / 电量          │     │
│  │  3. 构造 Payload                  │     │
│  │  4. POST /api/report/phone        │     │
│  │  5. 失败 → offline_cache          │     │
│  └──────────────────────────────────┘     │
└──────────────────────────────────────────┘
```

#### 核心代码骨架

```dart
// shared/models/report_payload.dart
class ReportPayload {
  final String window;     // 前台应用名
  final String lan;        // 局域网 IP
  final String wifi;       // SSID
  final String battery;    // "85% · 放电中"
  final int start;         // 会话开始 epoch ms
  final int end;           // 当前 epoch ms
  final int dur;           // 持续时长 ms

  Map<String, dynamic> toJson() => {
    'window': window, 'lan': lan, 'wifi': wifi,
    'battery': battery, 'start': start, 'end': end, 'dur': dur,
  };
}

// background/reporter_service.dart
class ReporterService {
  static const String deviceId = 'phone';
  static const String baseUrl = 'http://...'; // 同 worker.js 的 ip6.arpa

  int _sessionStart = 0;
  String _lastApp = '';

  /// 被 WorkManager 或前台 Service 调用
  Future<void> onWake() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final currentApp = await _getForegroundApp();

    if (currentApp == _lastApp && _sessionStart > 0) {
      // 同应用，仅发 keepalive（省流量）
      await _sendKeepalive(currentApp);
      return;
    }

    // 应用切换 → 关旧会话、开新会话
    if (_lastApp.isNotEmpty && _sessionStart > 0) {
      await _reportSession(_lastApp, _sessionStart, now);
    }
    _lastApp = currentApp;
    _sessionStart = now;
  }

  Future<void> _reportSession(String app, int start, int end) async {
    final payload = ReportPayload(
      window: app,
      lan: await WiFiInfo.getIp(),
      wifi: await WiFiInfo.getSsid(),
      battery: await BatteryInfo.getStatus(),
      start: start,
      end: end,
      dur: end - start,
    );

    final ok = await ReportClient.send(deviceId, payload);
    if (!ok) OfflineCache.enqueue(payload);  // 离线缓存
  }
}

// main_reporter.dart（无 UI 入口）
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 不 runApp，只启动后台服务
  final reporter = ReporterService();
  Workmanager().initialize(reporter.onWake);
  Workmanager().registerPeriodicTask(
    'phone_report', 'reportActivity',
    frequency: Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.CONNECTED),
  );
  // 前台 Service（更频繁上报，Android 专用）
  FlutterBackgroundService().start();
}
```

### App B：全功能 App

#### UI 架构

- **状态管理**：Riverpod（轻量、编译安全、无 runtime 反射）
- **路由**：GoRouter（与 Web 路径一致）
- **UI 组件**：Flutter Material 3（可换 Cupertino）
- **WebView 注入**：仅在需要显示网页版页面时使用（如未被迁移的旧页面）

#### 页面结构

```
/                          → 主页（设备卡片 + 日志 + 在线用户）
/history                   → 活动历史（表格 + 筛选 + 翻页）
/ai-summary                → AI 总结（模型配置 + 结果展示）
/chat                      → 聊天（完整消息列表）
/settings                  → 设置（服务器地址、昵称、主题）
```

#### 后台持续上报

App B 在前台运行时，后台上报引擎通过 Flutter `Isolate` 独立运行：

```dart
// main_full.dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 主 Isolate：UI
  runApp(const FullApp());

  // 后台 Isolate：上报引擎（与 UI 隔离，不卡 UI 线程）
  Isolate.spawn((msg) {
    final reporter = ReporterService();
    reporter.startBackgroundLoop();  // 每 30s 检查前台应用
  }, null);
}
```

#### 与网页版 CF 功能对标

| 网页版 | App B |
|---|---|
| 三设备状态卡片（绿/灰指示器） | Material 3 Card + Lottie 动画过渡 |
| 设备扩展信息（WiFi/IP/电量） | 底部 Sheet 展开 |
| 在线用户列表 | 原生列表 + 头像首字 |
| 日志终端（滚动 + 标签色） | 原生 ListView + AnimatedList |
| 聊天发送/接收 | 原生 TextField + 消息气泡 |
| 历史表格（keyset 翻页） | 原生 DataTable + 自动翻页 |
| AI 模型配置（provider/model/key） | 原生 Form + 下拉选择 |
| AI 总结展示 | Markdown 渲染（flutter_markdown） |
| 新增：推送通知 | Firebase Cloud Messaging |
| 新增：桌面 Widget | Android home screen widget |

---

## 三、Flutter vs Uni-App 待机开销深度对比

### 内存对比（实测参考值）

| 场景 | Flutter | Uni-App (WebView) | Uni-App (Weex) |
|---|---|---|---|
| 冷启动后 | 15-25 MB | 45-55 MB | 30-40 MB |
| 稳定运行（带 UI） | 25-35 MB | 60-80 MB | 40-55 MB |
| 切后台（不杀进程） | 10-15 MB | 40-60 MB | 30-40 MB |
| 仅后台 Service | 8-12 MB | 不可实现 | 不可实现 |

### CPU 对比

| 操作 | Flutter | Uni-App (WebView) |
|---|---|---|
| 状态刷新（10s 轮询） | Dart 解析 JSON → setState → 局部重绘 | JS JSON.parse → DOM diff → WebView 渲染 |
| 列表滚动 | Skia 直接绘制，无布局 thrash | WebView 滚动，触发浏览器 layout/paint |
| 后台上报 | Dart AOT 原生 HTTP → 几百 ms 即释放 | 无法纯后台，WebView 常驻 |

### 结论

| 维度 | Flutter | Uni-App |
|---|---|---|
| 内存占用（空载） | 8-12 MB（可纯后台） | 45-80 MB（WebView 常驻） |
| 内存占用（带 UI） | 25-35 MB | 60-80 MB |
| 后台上报能力 | ✅ WorkManager / Isolate | ❌ WebView 模式后台不可控 |
| 待机功耗 | 系统级调度，≈ 0 额外耗电 | WebView 进程驻留增加耗电 |
| 双 App 代码复用 | ✅ 单项目双入口，~80% 共用 | ❌ 两个 App 要两套代码 |
| 学习成本 | 需学 Dart/Flutter | 会 Vue 即可上手 |

**推荐：Flutter**（除非团队只会 Vue 且不介意高于 2x 的内存开销）

---

## 四、实施路线图

```
第一阶段（1-2 天）：C Probe 改进
  └─ UltraLightProbe.c 加 EVENT_OBJECT_NAMECHANGE Hook

第二阶段（3-5 天）：App A 静默上报器
  └─ Flutter 项目搭建、platform 频道、WorkManager、上报逻辑

第三阶段（5-7 天）：App B 完整 UI
  └─ 所有页面、API 对接、状态管理、与上报引擎共存

第四阶段（2-3 天）：优化 & 测试
  └─ 功耗测试、离线缓存测试、各 Android/iOS 版本兼容
```

---

*文档版本：v1.0 / 2026-06-06*
