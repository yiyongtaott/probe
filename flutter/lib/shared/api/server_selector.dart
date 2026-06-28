import 'package:http/http.dart' as http;
import 'dart:async';

/// Server address selector — primary/secondary auto-failover.
///
/// Strategy:
///   1. Try the primary URL (https dpdns.org).
///   2. If it fails, fall back to the secondary URL (http ip6.arpa direct).
///   3. Remember the last working address.
///   4. All API clients share one instance.
class ServerSelector {
  static const String primary = 'https://flandretiamat.dpdns.org';
  static const String secondary =
      'http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa';

  String _active = primary;
  bool _switched = false;

  String get active => _active;
  bool get hasSwitched => _switched;

  /// Probe the primary; fail over to secondary if unreachable.
  /// Call once per app start.
  Future<String> probeAndFailover() async {
    if (_switched) return _active;

    try {
      final uri = Uri.parse('$_active/api/sync?since=0');
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) return _active;
    } catch (_) {
      // primary unreachable
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
