import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';

/// POST /api/chat — 发送聊天消息
class ChatClient {
  final ApiClient _api;
  final http.Client _http;

  ChatClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 发送聊天消息
  /// [user] 用户名
  /// [message] 消息内容
  /// [sessionId] 会话 ID
  Future<bool> sendMessage({
    required String user,
    required String message,
    required String sessionId,
  }) async {
    try {
      final body = {
        'user': user,
        'message': message,
        'sessionId': sessionId,
      };
      final uri = _api.uri('/api/chat');
      final res = await _http.post(
        uri,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
