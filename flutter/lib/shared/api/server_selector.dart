import 'package:http/http.dart' as http;
import 'dart:async';

/// 服务器地址选择器 — 支持主备自动切换
///
/// 策略：
///   1. 尝试 primary URL（http ip6.arpa）
///   2. 如果连接失败，自动切换到 secondary URL（https dpdns.org）
///   3. 记住最后一次成功的地址
///   4. 所有 API Client 共享同一个实例
class ServerSelector {
  static const String primary =
      'http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa';
  static const String secondary = 'https://flandretiamat.dpdns.org';

  String _active = primary;
  bool _switched = false;

  String get active => _active;
  bool get hasSwitched => _switched;

  /// 探测 primary 是否可用，不可用则切到 secondary
  /// 每次 App 启动时调用一次即可
  Future<String> probeAndFailover() async {
    if (_switched) return _active;

    try {
      final uri = Uri.parse('$_active/api/sync?since=0');
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) return _active;
    } catch (_) {
      // primary 连不上
    }

    _active = secondary;
    _switched = true;
    return _active;
  }

  void reset() {
    _active = primary;
    _switched = false;
  }
}
