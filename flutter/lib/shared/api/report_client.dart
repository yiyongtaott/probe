import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';

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
      final res = await _http.post(uri, body: jsonEncode(body), headers: {'Content-Type': 'application/json'});
      return res.statusCode == 200;
    } catch (_) {
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
      final res = await _http.post(uri, body: jsonEncode(body), headers: {'Content-Type': 'application/json'});
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
