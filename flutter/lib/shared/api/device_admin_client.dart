import 'package:http/http.dart' as http;
import 'api_client.dart';

/// 设备管理 API
class DeviceAdminClient {
  final ApiClient _api;
  final http.Client _http;

  DeviceAdminClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// DELETE /api/device/{id} — 删除单台设备
  Future<bool> deleteDevice(String id) async {
    try {
      final uri = _api.uri('/api/device/$id');
      final res = await _http.delete(uri);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// DELETE /api/devices — 删除所有设备
  Future<bool> deleteAllDevices() async {
    try {
      final uri = _api.uri('/api/devices');
      final res = await _http.delete(uri);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
