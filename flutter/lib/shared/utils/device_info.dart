import 'dart:io' show Platform;

import 'package:battery_plus/battery_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 获取设备信息的工具类
class DeviceInfo {
  /// 主服务器地址（HTTP）
  static const String defaultServerBase =
      'http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa';

  /// 备用服务器地址（HTTPS）
  static const String fallbackServerBase =
      'https://flandretiamat.dpdns.org';

  /// 检测设备 ID，优先级：
  ///   1. SharedPreferences 运行时值（Android 用户在设置页修改）
  ///   2. --dart-define=device=xxx 编译参数
  ///   3. 桌面端: exe 名最后一个 "-" 之后的部分
  ///   4. 移动端默认 "phone"
  static Future<String> detectDeviceId() async {
    // 1) 运行时持久化覆盖（用户可在设置页修改）
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('device_id');
      if (saved != null && saved.isNotEmpty) return saved;
    } catch (_) {}

    // 2) 编译参数
    const dartDefine = String.fromEnvironment('device');
    if (dartDefine.isNotEmpty) return dartDefine;

    // 3) 桌面端：exe 名解析
    try {
      final exe = Platform.resolvedExecutable;
      final base = exe.split(RegExp(r'[/\\]')).last;
      final stem = base.contains('.')
          ? base.substring(0, base.lastIndexOf('.'))
          : base;
      final dash = stem.lastIndexOf('-');
      if (dash >= 0 && dash < stem.length - 1) {
        return stem.substring(dash + 1);
      }
    } catch (_) {}

    // 4) 移动端 / 默认
    try {
      if (Platform.isAndroid || Platform.isIOS) return 'phone';
    } catch (_) {}
    return 'notebook';
  }

  /// 同步版本 — 在不方便 await 的场合使用
  /// 注意：此时 SharedPreferences 尚未加载，优先级低于异步版本
  static String detectDeviceIdSync() {
    const dartDefine = String.fromEnvironment('device');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      if (Platform.isAndroid || Platform.isIOS) return 'phone';
    } catch (_) {}
    return 'notebook';
  }

  /// 获取前台应用包名/进程名
  static Future<String> getForegroundApp() async {
    return 'unknown';
  }

  /// 获取 (SSID, 局域网IP)
  static Future<(String, String)> getNetworkInfo() async {
    try {
      final info = NetworkInfo();
      final wifi = await info.getWifiName() ?? 'unknown';
      final ip = await info.getWifiIP() ?? 'unknown';
      return (wifi, ip);
    } catch (_) {
      return ('unknown', 'unknown');
    }
  }

  /// 获取电量状态 "85% · 放电中"
  static Future<String> getBattery() async {
    try {
      final batt = Battery();
      final level = await batt.batteryLevel;
      final state = await batt.batteryState;
      String status;
      switch (state) {
        case BatteryState.charging:
          status = '充电中';
        case BatteryState.full:
          status = '已充满';
        case BatteryState.discharging:
          status = '放电中';
        default:
          status = level >= 100 ? '已充满' : '放电中';
      }
      return '$level% · $status';
    } catch (_) {
      return 'unknown';
    }
  }
}
