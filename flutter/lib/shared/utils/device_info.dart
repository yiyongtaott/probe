/// 获取设备信息的工具类
class DeviceInfo {
  static const String defaultServerBase =
      'http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa';

  /// 获取前台应用包名/进程名
  static Future<String> getForegroundApp() async {
    // TODO: Android — UsageStatsManager via MethodChannel
    // TODO: iOS — 通过 AppGroup 或回退到 lastActive
    return 'unknown';
  }

  /// 获取 (SSID, 局域网IP)
  static Future<(String, String)> getNetworkInfo() async {
    // TODO: network_info_plus
    return ('unknown', 'unknown');
  }

  /// 获取电量状态 "85% · 放电中"
  static Future<String> getBattery() async {
    // TODO: battery_plus
    return 'unknown';
  }
}
