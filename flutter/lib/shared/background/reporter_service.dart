import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';
import '../api/report_client.dart';
import '../api/api_client.dart';
import '../utils/device_info.dart';
import '../utils/probe_log.dart';
import '../models/models.dart';

/// 核心上报引擎 — App A（静默器）/ App B（后台 Isolate）共用
/// 接口/算法与 C Probe (UltraLightProbe.c) 完全对齐。
/// 对齐项：
///   - Payload 字段 (window/lan/wifi/battery/start/end/dur)
///   - Keepalive 格式 (keepalive:1 + 前4字段)
///   - Keepalive 间隔 240s
///   - Checkpoint 间隔 30min
///   - 离线缓存 & 重试
class ReporterService {
  final String deviceId;
  final String serverBase;
  final ApiClient _api;
  late final ReportClient _report;

  String _lastApp = '';
  int _sessionStartMs = 0;
  int _lastKeepaliveMs = 0;
  bool _wakeRunning = false;
  bool _wakePending = false;
  String _pendingReason = 'wake';
  _ReportVitals? _cachedVitals;
  int _cachedVitalsAtMs = 0;

  /// 缓存刷新间隔（C Probe: SLOW_REFRESH_MS = 5min）
  static const int cacheRefreshMs = 5 * 60 * 1000;
  static const int checkpointMs = 30 * 60 * 1000;

  ReporterService({required this.deviceId, required this.serverBase})
    : _api = ApiClient(baseUrl: serverBase) {
    _report = ReportClient(_api);
  }

  /// ── 唤醒入口：文件事件、前台 Service、兜底定时器共用 ────────────────
  Future<void> onWake({String reason = 'wake'}) async {
    if (_wakeRunning) {
      _wakePending = true;
      _pendingReason = reason;
      return;
    }

    _wakeRunning = true;
    var currentReason = reason;
    try {
      while (true) {
        _wakePending = false;
        await _runWake(currentReason);
        if (!_wakePending) break;
        currentReason = _pendingReason;
      }
    } finally {
      _wakeRunning = false;
    }
  }

  Future<void> _runWake(String reason) async {
    try {
      await ProbeLog.info('wake reason=$reason device=$deviceId');
      // 确保离线缓存已初始化
      await OfflineCache.ensureInitialized();
    } catch (e, st) {
      await ProbeLog.error('wake preparation failed', e, st);
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final isPollingFallback =
        reason == 'event:fallback' || reason == 'fallback';
    final rawCurrentApp = await DeviceInfo.getForegroundApp();
    var currentApp = ActivityFilter.normalize(rawCurrentApp);
    if (ActivityFilter.shouldReusePrevious(rawCurrentApp) &&
        _lastApp.isNotEmpty) {
      currentApp = _lastApp;
    }
    if (currentApp.isEmpty) return;
    final canKeepalive = await DeviceInfo.canSendKeepaliveFor(currentApp);

    if (_lastApp.isEmpty || _sessionStartMs == 0) {
      _lastApp = currentApp;
      _sessionStartMs = nowMs;
      _lastKeepaliveMs = nowMs;
      await ProbeLog.info('session start: $currentApp');
      if (canKeepalive) await _sendKeepalive(currentApp);
      return;
    }

    if (currentApp == _lastApp && _sessionStartMs > 0) {
      if (!isPollingFallback && nowMs - _sessionStartMs >= checkpointMs) {
        await ProbeLog.info('checkpoint: $currentApp');
        await _sendReport(currentApp, _sessionStartMs, nowMs);
        _sessionStartMs = nowMs;
        return;
      }
      if (!isPollingFallback) {
        await _maybeKeepalive(nowMs, currentApp, canKeepalive);
      }
      if (!reason.startsWith('event:')) {
        await OfflineCache.autoFlush(_report, deviceId);
      }
      return;
    }

    // 应用切换 → 关旧开新（与 C Probe roll_session 一致）
    if (_lastApp.isNotEmpty && _sessionStartMs > 0) {
      await _sendReport(_lastApp, _sessionStartMs, nowMs);
    }
    _lastApp = currentApp;
    _sessionStartMs = nowMs;
    _lastKeepaliveMs = nowMs;
    await ProbeLog.info('session switch: $currentApp');
    if (DeviceInfo.isAndroidSystemStateWindow(currentApp)) {
      // screen-off / locked: one-shot status update (no history, no further keepalive)
      await _sendStatusOnly(currentApp);
    } else if (canKeepalive) {
      await _sendKeepalive(currentApp);
    }
  }

  /// ── 前台 Service 连续循环 ─────────────────────────────────────
  /// Android 使用 Accessibility/屏幕状态文件事件即时唤醒，120s 定时器仅兜底。
  Future<void> startContinuousLoop({
    Future<void> Function(String reason)? onAfterWake,
  }) async {
    StreamSubscription<String>? eventSubscription;
    Timer? trailingEventTimer;
    var lastEventWakeMs = 0;

    Future<void> run(String reason) async {
      try {
        await onWake(reason: reason);
        await onAfterWake?.call(reason);
      } catch (e, st) {
        await ProbeLog.error('continuous loop failed', e, st);
      }
    }

    void scheduleEventWake(String source) {
      // Device-state change (screen off/on, lock/unlock) fires immediately with
      // no debounce, so screen-off is reported instantly.
      if (source == 'probe_device_state.json') {
        trailingEventTimer?.cancel();
        lastEventWakeMs = DateTime.now().millisecondsSinceEpoch;
        unawaited(run('event:devicestate'));
        return;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final elapsedMs = nowMs - lastEventWakeMs;
      if (elapsedMs >= 800) {
        lastEventWakeMs = nowMs;
        unawaited(run('event:$source'));
        return;
      }

      trailingEventTimer?.cancel();
      trailingEventTimer = Timer(Duration(milliseconds: 800 - elapsedMs), () {
        lastEventWakeMs = DateTime.now().millisecondsSinceEpoch;
        unawaited(run('event:$source'));
      });
    }

    if (Platform.isAndroid) {
      eventSubscription = DeviceInfo.watchAndroidForegroundChanges(
        fallbackInterval: const Duration(seconds: 30),
        enableFallback: true,
      ).listen(
        scheduleEventWake,
        onError: (Object e, StackTrace st) {
          unawaited(ProbeLog.error('foreground watcher failed', e, st));
        },
      );
    }

    try {
      await run('start');
      if (Platform.isAndroid) {
        await Completer<void>().future;
      } else {
        while (true) {
          await Future<void>.delayed(const Duration(seconds: 120));
          await run('timer');
        }
      }
    } finally {
      trailingEventTimer?.cancel();
      await eventSubscription?.cancel();
    }
  }

  /// 240s keepalive 节流（与 C Probe KEEPALIVE_MS 对齐）
  Future<void> _maybeKeepalive(int nowMs, String app, bool canKeepalive) async {
    if (nowMs - _lastKeepaliveMs < 240000) return;
    if (!canKeepalive) return;
    _lastKeepaliveMs = nowMs;
    await _sendKeepalive(app);
  }

  Future<void> _sendReport(String app, int start, int end) async {
    final window = ActivityFilter.normalize(app);
    final dur = end - start;
    if (!ActivityFilter.isReportable(window, dur)) {
      await ProbeLog.info('skip low-value report: $app');
      return;
    }
    final vitals = await _getVitals();

    final ok = await _report.sendReport(
      deviceId: deviceId,
      window: window,
      lan: vitals.ip,
      wifi: vitals.wifi,
      battery: vitals.battery,
      start: start,
      end: end,
      dur: dur,
    );
    if (!ok) {
      await ProbeLog.reportFail('enqueue offline report for $deviceId');
      await OfflineCache.enqueue(
        ReportPayload(
          window: window,
          lan: vitals.ip,
          wifi: vitals.wifi,
          battery: vitals.battery,
          start: start,
          end: end,
          dur: dur,
        ),
      );
    }
  }

  Future<void> _sendKeepalive(String app) async {
    final window = ActivityFilter.normalize(app);
    if (!ActivityFilter.isStatusReportable(window)) return;
    final vitals = await _getVitals();
    final ok = await _report.sendKeepalive(
      deviceId: deviceId,
      window: window,
      lan: vitals.ip,
      wifi: vitals.wifi,
      battery: vitals.battery,
    );
    if (!ok) {
      await ProbeLog.reportFail('keepalive failed for $deviceId');
    } else {
      await OfflineCache.autoFlush(_report, deviceId);
    }
  }

  /// System-state (screen-off / locked) one-shot status: refresh the live device
  /// status, bypassing the system-state guard; never written to history.
  Future<void> _sendStatusOnly(String app) async {
    final window = ActivityFilter.normalize(app);
    if (window.isEmpty) return;
    final vitals = await _getVitals();
    final ok = await _report.sendKeepalive(
      deviceId: deviceId,
      window: window,
      lan: vitals.ip,
      wifi: vitals.wifi,
      battery: vitals.battery,
    );
    if (ok) {
      await OfflineCache.autoFlush(_report, deviceId);
    } else {
      await ProbeLog.reportFail('status-only failed for $deviceId ($window)');
    }
  }

  Future<_ReportVitals> _getVitals() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cached = _cachedVitals;
    if (cached != null && nowMs - _cachedVitalsAtMs < cacheRefreshMs) {
      return cached;
    }

    final (wifi, ip) = await DeviceInfo.getNetworkInfo();
    final battery = await DeviceInfo.getBattery();
    final vitals = _ReportVitals(wifi: wifi, ip: ip, battery: battery);
    _cachedVitals = vitals;
    _cachedVitalsAtMs = nowMs;
    return vitals;
  }
}

class _ReportVitals {
  final String wifi;
  final String ip;
  final String battery;

  const _ReportVitals({
    required this.wifi,
    required this.ip,
    required this.battery,
  });
}

/// 离线缓存（与 C Probe pending ring buffer 功能一致）
/// 使用 SharedPreferences 持久化，应用重启后仍保留未上报的日志
class ActivityFilter {
  static const int minReportMs = 1500;
  static final Set<int> _leadingGlyphs = <int>{
    0x231B,
    0x23F3,
    0x25CC,
    0x25D0,
    0x25D1,
    0x25D2,
    0x25D3,
    0x25E6,
    0x25EF,
    0x2605,
    0x2606,
    0x2705,
    0x2713,
    0x2714,
    0x2726,
    0x2728,
    0x2733,
    0x2734,
    0x2747,
    0x274C,
    0xFFFD,
  };

  static final Set<String> _lowValue = <String>{
    'play',
    'pause',
    'paused',
    'playing',
    'speed',
    'loading',
    'buffering',
    '\u64ad\u653e',
    '\u6682\u505c',
    '\u64ad\u653e/\u6682\u505c',
    '\u500d\u901f\u4e2d',
    '\u52a0\u8f7d\u4e2d',
    '\u6b63\u5728\u52a0\u8f7d',
    '\u7f13\u51b2\u4e2d',
    '\u91cd\u64ad',
    '\u70b9\u51fb\u91cd\u8bd5',
    '\u62d6\u52a8\u5230\u6b64\u5904\u9501\u5b9a\u500d\u901f',
    '\u53d1\u9001\u4e2d...',
    '\u4e00\u952e\u5df2\u8bfb',
    // screen-off / locked moved out of low-value set: handled as system-state
    // (one-shot status report, never written to history)
    '\u7cfb\u7edf\u684c\u9762',
    'ultralightprobe',
  };

  static final Set<String> _shortMeaningful = <String>{'qq', 'tim', 'yy'};

  static String normalize(String value) {
    final title =
        value
            .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
            .replaceAll(
              RegExp(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'),
              '',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    return _stripLeadingGlyphs(title);
  }

  static bool shouldReusePrevious(String value) {
    final title = normalize(value);
    if (_isLowValue(title)) return true;
    final parts = title.split(' - ');
    return parts.length > 1 && _isLowValue(parts.last.trim());
  }

  static bool isStatusReportable(String value) {
    final title = normalize(value);
    if (title.isEmpty) return false;
    if (_isLowValue(title)) return false;
    if (DeviceInfo.isAndroidSystemStateWindow(title)) return false;
    return true;
  }

  static bool isReportable(String value, int durationMs) {
    final title = normalize(value);
    if (durationMs > 0 && durationMs < minReportMs) return false;
    if (!isStatusReportable(title)) return false;
    if (_hasLowInformation(title)) return false;
    return true;
  }

  static String _stripLeadingGlyphs(String value) {
    var s = value.trimLeft();
    while (s.isNotEmpty) {
      final cp = s.runes.first;
      if (!_leadingGlyphs.contains(cp) &&
          (cp < 0x2800 || cp > 0x28FF) &&
          (cp < 0x1F300 || cp > 0x1FAFF)) {
        break;
      }
      s = s.substring(String.fromCharCode(cp).length).trimLeft();
    }
    return s;
  }

  static bool _isLowValue(String value) {
    final title = normalize(value);
    final lower = title.toLowerCase();
    final compact = lower.replaceAll(RegExp(r'\s+'), '');
    if (_lowValue.contains(lower) || _lowValue.contains(compact)) return true;
    final parts = lower.split(RegExp(r'\s+-\s+'));
    final last = parts.isEmpty ? lower : parts.last;
    final lastCompact = last.replaceAll(RegExp(r'\s+'), '');
    if (_lowValue.contains(last) || _lowValue.contains(lastCompact))
      return true;
    if (RegExp(r'^(\d+(\.\d+)?x|\d+(\.\d+)?倍|倍速)$').hasMatch(compact)) {
      return true;
    }
    if (title.contains('\u500d\u901f\u4e2d') && title.length <= 12) return true;
    return false;
  }

  static bool _hasLowInformation(String title) {
    final compact = title.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (_shortMeaningful.contains(compact)) return false;
    final chars =
        title.runes
            .map((cp) => String.fromCharCode(cp))
            .where((ch) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch))
            .toList();
    if (chars.length <= 1) return true;
    return chars.toSet().length <= 1 && chars.length <= 4;
  }
}

class OfflineCache {
  static const int maxEntries = 200;

  static bool _initialized = false;
  static final List<ReportPayload> _queue = [];
  static final StreamController<int> _lengthController =
      StreamController<int>.broadcast();

  /// 供 UI 监听的队列长度流
  static Stream<int> get lengthStream => _lengthController.stream;
  static int get length => _queue.length;

  /// 从 SharedPreferences 恢复持久化的队列
  /// 在后台 Isolate 中不可用（无 channel 访问），静默回退到内存模式
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('offline_cache_queue');
      if (stored != null && stored.isNotEmpty) {
        final list = jsonDecode(stored) as List;
        for (final item in list) {
          _queue.add(ReportPayload.fromJson(item as Map<String, dynamic>));
        }
        _trimToLimit();
      }
      _lengthController.add(_queue.length);
    } catch (e, st) {
      await ProbeLog.error('offline cache init failed', e, st);
      // 后台 Isolate 不支持 SharedPreferences，静默使用内存模式
    }
  }

  /// 将当前队列持久化到 SharedPreferences
  static Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_queue.map((p) => p.toJson()).toList());
      await prefs.setString('offline_cache_queue', encoded);
    } catch (e, st) {
      await ProbeLog.error('offline cache persist failed', e, st);
      // 后台 Isolate 不支持 SharedPreferences，忽略
    }
  }

  static Future<void> enqueue(ReportPayload p) async {
    if (!ActivityFilter.isReportable(p.window, p.dur)) return;
    _queue.add(p);
    _trimToLimit();
    _lengthController.add(_queue.length);
    await _persist();
  }

  static void _trimToLimit() {
    while (_queue.length > maxEntries) {
      _queue.removeAt(0);
    }
  }

  static ReportPayload? dequeue() {
    if (_queue.isEmpty) return null;
    final item = _queue.removeAt(0);
    _lengthController.add(_queue.length);
    return item;
  }

  /// Auto-drain the queue: send in batches (one array POST) until empty or offline.
  static Future<void> autoFlush(
    ReportClient reportClient,
    String deviceId,
  ) async {
    _queue.removeWhere((p) => !ActivityFilter.isReportable(p.window, p.dur));
    while (_queue.isNotEmpty) {
      final batch = _queue.take(20).toList();
      final ok = await reportClient.sendReportBatch(
        deviceId: deviceId,
        items: batch.map((p) => p.toJson()).toList(),
      );
      if (!ok) break; // still offline; retry on next wake
      _queue.removeRange(0, batch.length);
      await ProbeLog.info(
        'flushed ${batch.length} offline reports, remaining=${_queue.length}',
      );
    }
    _lengthController.add(_queue.length);
    await _persist();
  }
}
