import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';

/// AI 摘要结果
class AiSummaryResult {
  final String summary;
  final String provider;
  final int usedToday;

  const AiSummaryResult({
    required this.summary,
    required this.provider,
    required this.usedToday,
  });

  factory AiSummaryResult.fromJson(Map<String, dynamic> json) =>
      AiSummaryResult(
        summary: json['summary'] ?? '',
        provider: json['provider'] ?? '',
        usedToday: json['usedToday'] ?? 0,
      );
}

/// POST /api/ai-summary — 调用 AI 生成摘要
class AiSummaryClient {
  final ApiClient _api;
  final http.Client _http;

  AiSummaryClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 请求 AI 摘要
  /// [prompt] 提示词
  /// [provider] AI 提供商
  /// [model] 模型名称
  /// [baseUrl] 可选的自定义 base URL
  /// [apiKey] 可选的 API 密钥
  Future<AiSummaryResult?> summarize({
    required String prompt,
    required String provider,
    required String model,
    String? baseUrl,
    String? apiKey,
  }) async {
    try {
      final body = <String, dynamic>{
        'prompt': prompt,
        'provider': provider,
        'model': model,
      };
      if (baseUrl != null) body['baseUrl'] = baseUrl;
      if (apiKey != null) body['apiKey'] = apiKey;

      final uri = _api.uri('/api/ai-summary');
      final res = await _http.post(
        uri,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      );
      if (res.statusCode == 200) {
        return AiSummaryResult.fromJson(jsonDecode(res.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// GET /api/ai-data — 获取合并后的会话数据（AI 分析用）
class AiDataClient {
  final ApiClient _api;
  final http.Client _http;

  AiDataClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 获取 AI 分析用的原始合并会话数据
  /// [devices] 设备 ID（逗号分隔）
  /// [start] / [end] 时间范围（Unix 毫秒）
  Future<Map<String, dynamic>> getData({
    required String devices,
    int? start,
    int? end,
  }) async {
    try {
      final params = <String, String>{
        'devices': devices,
      };
      if (start != null) params['start'] = start.toString();
      if (end != null) params['end'] = end.toString();

      final uri = _api.uri('/api/ai-data', params);
      final res = await _http.get(uri);
      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }
      return {};
    } catch (_) {
      return {};
    }
  }
}
