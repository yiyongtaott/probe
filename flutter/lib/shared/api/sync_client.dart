import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/models.dart';

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
