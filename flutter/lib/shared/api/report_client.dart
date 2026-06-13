import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';
import '../utils/probe_log.dart';

/// POST /api/report/{device_id}
class ReportClient {
  final ApiClient _api;
  final http.Client _http;

  ReportClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 上报活动会话（静默器核心调用）
  Future<bool> sendReport({
    required String deviceId,
    required String window,
    required String lan,
    required String wifi,
    required String battery,
    required int start,
    required int end,
    required int dur,
  }) async {
    try {
      final body = {
        'window': window,
        'lan': lan,
        'wifi': wifi,
        'battery': battery,
        'start': start,
        'end': end,
        'dur': dur,
      };
      final uri = _api.uri('/api/report/$deviceId');
      final encoded = jsonEncode(body);
      final res = await _http
          .post(
            uri,
            body: encoded,
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));
      final ok = res.statusCode >= 200 && res.statusCode < 400;
      if (ok) {
        await ProbeLog.reportOk(
          'report $deviceId [$window] -> ${uri.host} ${res.statusCode}',
        );
      } else {
        await ProbeLog.reportFail(
          'report $deviceId [$window] -> $uri ${res.statusCode}: ${_shortBody(res.body)}',
        );
      }
      return ok;
    } catch (e, st) {
      await ProbeLog.error('report $deviceId failed', e, st);
      await ProbeLog.reportFail('report $deviceId failed: $e');
      return false;
    }
  }

  /// 保活 (keepalive=1)
  Future<bool> sendKeepalive({
    required String deviceId,
    required String window,
    required String lan,
    required String wifi,
    required String battery,
  }) async {
    try {
      final body = {
        'keepalive': 1,
        'window': window,
        'lan': lan,
        'wifi': wifi,
        'battery': battery,
      };
      final uri = _api.uri('/api/report/$deviceId');
      final encoded = jsonEncode(body);
      final res = await _http
          .post(
            uri,
            body: encoded,
            headers: {'Content-Type': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));
      final ok = res.statusCode >= 200 && res.statusCode < 400;
      if (ok) {
        await ProbeLog.reportOk(
          'keepalive $deviceId [$window] -> ${uri.host} ${res.statusCode}',
        );
      } else {
        await ProbeLog.reportFail(
          'keepalive $deviceId [$window] -> $uri ${res.statusCode}: ${_shortBody(res.body)}',
        );
      }
      return ok;
    } catch (e, st) {
      await ProbeLog.error('keepalive $deviceId failed', e, st);
      await ProbeLog.reportFail('keepalive $deviceId failed: $e');
      return false;
    }
  }

  String _shortBody(String body) {
    if (body.length <= 300) return body;
    return '${body.substring(0, 300)}...';
  }
}
