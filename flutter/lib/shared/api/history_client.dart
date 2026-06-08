import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_client.dart';

/// 活动历史记录分页结果
class HistoryResult {
  final List<Map<String, dynamic>> rows;
  final bool done;
  final int? nextTs;
  final int? nextId;

  const HistoryResult({
    required this.rows,
    required this.done,
    this.nextTs,
    this.nextId,
  });

  factory HistoryResult.fromJson(Map<String, dynamic> json) => HistoryResult(
        rows: List<Map<String, dynamic>>.from(json['history'] ?? []),
        done: json['done'] ?? true,
        nextTs: json['nextTs'] as int?,
        nextId: json['nextId'] as int?,
      );
}

/// GET /api/history — keyset 分页活动历史
class HistoryClient {
  final ApiClient _api;
  final http.Client _http;

  HistoryClient(this._api) : _http = http.Client();

  void dispose() => _http.close();

  /// 获取活动历史，使用 keyset 分页
  /// [device] 设备 ID 过滤
  /// [start] / [end] 时间范围（Unix 毫秒）
  /// [pageSize] 每页条数，默认 2000
  /// [cursorTs] / [cursorId] keyset 游标
  Future<HistoryResult?> getHistory({
    String? device,
    int? start,
    int? end,
    int pageSize = 2000,
    int? cursorTs,
    int? cursorId,
  }) async {
    try {
      final params = <String, String>{};
      if (device != null && device.isNotEmpty) params['device'] = device;
      if (start != null) params['start'] = start.toString();
      if (end != null) params['end'] = end.toString();
      params['pageSize'] = pageSize.toString();
      if (cursorTs != null) params['cursorTs'] = cursorTs.toString();
      if (cursorId != null) params['cursorId'] = cursorId.toString();

      final uri = _api.uri('/api/history', params);
      final res = await _http.get(uri);
      if (res.statusCode == 200) {
        return HistoryResult.fromJson(jsonDecode(res.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
