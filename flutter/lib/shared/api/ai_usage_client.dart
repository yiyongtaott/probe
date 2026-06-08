import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';

/// AI 用量结果
class AiUsageResult {
  final String day;
  final Map<String, int> usage;

  const AiUsageResult({
    required this.day,
    required this.usage,
  });

  factory AiUsageResult.fromJson(Map<String, dynamic> json) => AiUsageResult(
        day: json['day'] ?? '',
        usage: (json['usage'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(k, v as int)) ??
            {},
      );
}

/// GET /api/ai-usage — 查询 AI 用量
class AiUsageClient {
  final ApiClient _api;
  final http.Client _http;

  AiUsageClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 获取当日 AI 用量统计
  Future<AiUsageResult?> getUsage() async {
    try {
      final uri = _api.uri('/api/ai-usage');
      final res = await _http.get(uri);
      if (res.statusCode == 200) {
        return AiUsageResult.fromJson(jsonDecode(res.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
