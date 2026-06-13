import 'dart:async';
import 'dart:convert';
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

  /// 缓存刷新间隔（C Probe: SLOW_REFRESH_MS = 5min）
  static const int cacheRefreshMs = 5 * 60 * 1000;
  static const int checkpointMs = 30 * 60 * 1000;

  ReporterService({required this.deviceId, required this.serverBase})
    : _api = ApiClient(baseUrl: serverBase) {
    _report = ReportClient(_api);
  }

  /// ── WorkManager / BGTaskScheduler 回调入口 ─────────────────────
  Future<void> onWake() async {
    try {
      await ProbeLog.info('wake device=$deviceId server=$serverBase');
      // 确保离线缓存已初始化
      await OfflineCache.ensureInitialized();
      // 每次唤醒优先重试队列中的离线数据
      await OfflineCache.autoFlush(_report, deviceId);
    } catch (e, st) {
      await ProbeLog.error('wake preparation failed', e, st);
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final currentApp = await DeviceInfo.getForegroundApp();

    if (_lastApp.isEmpty || _sessionStartMs == 0) {
      _lastApp = currentApp;
      _sessionStartMs = nowMs;
      _lastKeepaliveMs = nowMs;
      await ProbeLog.info('session start: $currentApp');
      await _sendKeepalive(currentApp);
      return;
    }

    if (currentApp == _lastApp && _sessionStartMs > 0) {
      if (nowMs - _sessionStartMs >= checkpointMs) {
        await ProbeLog.info('checkpoint: $currentApp');
        await _sendReport(currentApp, _sessionStartMs, nowMs);
        _sessionStartMs = nowMs;
        return;
      }
      await _maybeKeepalive(nowMs, currentApp);
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
    await _sendKeepalive(currentApp);
  }

  /// ── 前台 Service 连续循环 ─────────────────────────────────────
  /// 每 120s 检查一次（与 C Probe TIMER_TICK_MS = 120s 对齐）
  Future<void> startContinuousLoop() async {
    while (true) {
      try {
        await onWake();
      } catch (e, st) {
        await ProbeLog.error('continuous loop failed', e, st);
      }
      await Future.delayed(const Duration(seconds: 120));
    }
  }

  /// 240s keepalive 节流（与 C Probe KEEPALIVE_MS 对齐）
  Future<void> _maybeKeepalive(int nowMs, String app) async {
    if (nowMs - _lastKeepaliveMs < 240000) return;
    _lastKeepaliveMs = nowMs;
    await _sendKeepalive(app);
  }

  Future<void> _sendReport(String app, int start, int end) async {
    final (wifi, ip) = await DeviceInfo.getNetworkInfo();
    final battery = await DeviceInfo.getBattery();

    final ok = await _report.sendReport(
      deviceId: deviceId,
      window: app,
      lan: ip,
      wifi: wifi,
      battery: battery,
      start: start,
      end: end,
      dur: end - start,
    );
    if (!ok) {
      await ProbeLog.reportFail('enqueue offline report for $deviceId');
      await OfflineCache.enqueue(
        ReportPayload(
          window: app,
          lan: ip,
          wifi: wifi,
          battery: battery,
          start: start,
          end: end,
          dur: end - start,
        ),
      );
    }
  }

  Future<void> _sendKeepalive(String app) async {
    final (wifi, ip) = await DeviceInfo.getNetworkInfo();
    final battery = await DeviceInfo.getBattery();
    final ok = await _report.sendKeepalive(
      deviceId: deviceId,
      window: app,
      lan: ip,
      wifi: wifi,
      battery: battery,
    );
    if (!ok) {
      await ProbeLog.reportFail('keepalive failed for $deviceId');
    } else {
      await OfflineCache.autoFlush(_report, deviceId);
    }
  }
}

/// 离线缓存（与 C Probe pending ring buffer 功能一致）
/// 使用 SharedPreferences 持久化，应用重启后仍保留未上报的日志
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

  /// 自动刷空队列：逐条上报直到成功或队列为空
  static Future<void> autoFlush(
    ReportClient reportClient,
    String deviceId,
  ) async {
    while (_queue.isNotEmpty) {
      final payload = _queue.first;
      final ok = await reportClient.sendReport(
        deviceId: deviceId,
        window: payload.window,
        lan: payload.lan,
        wifi: payload.wifi,
        battery: payload.battery,
        start: payload.start,
        end: payload.end,
        dur: payload.dur,
      );
      if (!ok) break; // 网络不可用，留给下次唤醒重试
      _queue.removeAt(0);
      await ProbeLog.info('flushed offline report, remaining=${_queue.length}');
    }
    _lengthController.add(_queue.length);
    await _persist();
  }
}
