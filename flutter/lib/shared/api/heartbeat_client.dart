import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';

/// 心跳结果
class HeartbeatResult {
  final bool success;
  final int onlineCount;
  final Map<String, dynamic> onlineUsers;

  const HeartbeatResult({
    required this.success,
    required this.onlineCount,
    required this.onlineUsers,
  });

  factory HeartbeatResult.fromJson(Map<String, dynamic> json) =>
      HeartbeatResult(
        success: json['success'] ?? false,
        onlineCount: json['onlineCount'] ?? 0,
        onlineUsers: json['onlineUsers'] ?? {},
      );
}

/// POST /api/heartbeat — 心跳保活
class HeartbeatClient {
  final ApiClient _api;
  final http.Client _http;

  HeartbeatClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 发送心跳
  /// [sessionId] 会话 ID
  /// [userName] 用户名
  Future<HeartbeatResult?> sendHeartbeat({
    required String sessionId,
    required String userName,
  }) async {
    try {
      final body = {
        'sessionId': sessionId,
        'userName': userName,
      };
      final uri = _api.uri('/api/heartbeat');
      final res = await _http.post(
        uri,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      );
      if (res.statusCode == 200) {
        return HeartbeatResult.fromJson(jsonDecode(res.body));
      }
      return HeartbeatResult(success: false, onlineCount: 0, onlineUsers: {});
    } catch (_) {
      return null;
    }
  }
}
