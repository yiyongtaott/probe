import 'package:http/http.dart' as http;
import 'dart:convert';

/// GET /api/sync?since=N — 聚合同步接口
class SyncClient {
  final http.Client _http;
  final String baseUrl;

  SyncClient(this.baseUrl) : _http = http.Client();

  void dispose() => _http.close();

  Future<SyncPayload> sync({int since = 0}) async {
    final uri = Uri.parse('$baseUrl/api/sync?since=$since');
    final res = await _http.get(uri);
    if (res.statusCode == 200) {
      return SyncPayload.fromJson(jsonDecode(res.body));
    }
    throw Exception('Sync failed: ${res.statusCode}');
  }
}

class SyncPayload {
  final Map<String, dynamic> devices;
  final List<Map<String, dynamic>> chatHistory;
  final int onlineCount;
  final Map<String, dynamic> onlineUsers;

  const SyncPayload({
    required this.devices,
    required this.chatHistory,
    required this.onlineCount,
    required this.onlineUsers,
  });

  factory SyncPayload.fromJson(Map<String, dynamic> json) => SyncPayload(
        devices: json['deviceData'] ?? {},
        chatHistory: List<Map<String, dynamic>>.from(json['chatHistory'] ?? []),
        onlineCount: json['onlineCount'] ?? 0,
        onlineUsers: json['onlineUsers'] ?? {},
      );
}
