/// API 基类 — 所有 Client 的公共配置
class ApiClient {
  final String baseUrl;

  ApiClient({required this.baseUrl});

  /// 默认服务器地址（与 worker.js 的 ip6.arpa 保持一致）
  static const String defaultHost =
      'http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa';

  Uri uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('$baseUrl$path');
    if (query != null && query.isNotEmpty) {
      return u.replace(queryParameters: query);
    }
    return u;
  }
}
