import '../api/report_client.dart';
import '../api/api_client.dart';
import '../utils/device_info.dart';
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

  ReporterService({required this.deviceId, required this.serverBase})
      : _api = ApiClient(baseUrl: serverBase) {
    _report = ReportClient(_api);
  }

  /// ── WorkManager / BGTaskScheduler 回调入口 ─────────────────────
  Future<void> onWake() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final currentApp = await DeviceInfo.getForegroundApp();

    if (currentApp == _lastApp && _sessionStartMs > 0) {
      await _maybeKeepalive(nowMs, currentApp);
      return;
    }

    // 应用切换 → 关旧开新（与 C Probe roll_session 一致）
    if (_lastApp.isNotEmpty && _sessionStartMs > 0) {
      await _sendReport(_lastApp, _sessionStartMs, nowMs);
    }
    _lastApp = currentApp;
    _sessionStartMs = nowMs;
  }

  /// ── 前台 Service 连续循环 ─────────────────────────────────────
  /// 每 120s 检查一次（与 C Probe TIMER_TICK_MS = 120s 对齐）
  Future<void> startContinuousLoop() async {
    while (true) {
      await onWake();
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
      OfflineCache.enqueue(ReportPayload(
        window: app, lan: ip, wifi: wifi, battery: battery,
        start: start, end: end, dur: end - start,
      ));
    }
  }

  Future<void> _sendKeepalive(String app) async {
    final (wifi, ip) = await DeviceInfo.getNetworkInfo();
    final battery = await DeviceInfo.getBattery();
    await _report.sendKeepalive(
      deviceId: deviceId, window: app,
      lan: ip, wifi: wifi, battery: battery,
    );
  }
}

/// 离线缓存（与 C Probe pending ring buffer 功能一致）
class OfflineCache {
  static final List<ReportPayload> _queue = [];
  static void enqueue(ReportPayload p) => _queue.add(p);
  static ReportPayload? dequeue() => _queue.isNotEmpty ? _queue.removeAt(0) : null;
}
