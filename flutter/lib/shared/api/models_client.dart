import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';

/// POST /api/models — 查询 AI 提供商可用模型列表
class ModelsClient {
  final ApiClient _api;
  final http.Client _http;

  ModelsClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 获取可用模型列表
  /// [provider] AI 提供商
  /// [baseUrl] 服务地址
  /// [apiKey] API 密钥
  Future<List<String>> getModels({
    required String provider,
    required String baseUrl,
    required String apiKey,
  }) async {
    try {
      final body = {
        'provider': provider,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
      };
      final uri = _api.uri('/api/models');
      final res = await _http.post(
        uri,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is List) {
          return data.cast<String>();
        }
      }
      return [];
    } catch (_) {
      return [];
    }
  }
}
