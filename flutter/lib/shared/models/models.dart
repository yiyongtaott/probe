/// 设备上报数据模型
class ReportPayload {
  final String window;
  final String lan;
  final String wifi;
  final String battery;
  final int start;
  final int end;
  final int dur;

  const ReportPayload({
    required this.window,
    required this.lan,
    required this.wifi,
    required this.battery,
    required this.start,
    required this.end,
    required this.dur,
  });

  Map<String, dynamic> toJson() => {
        'window': window,
        'lan': lan,
        'wifi': wifi,
        'battery': battery,
        'start': start,
        'end': end,
        'dur': dur,
      };
}

/// 活动历史记录（DB 行）
class ActivityRecord {
  final int id;
  final String deviceId;
  final String windowTitle;
  final String lan;
  final String wifi;
  final String battery;
  final int recordedAt;
  final int? startedAt;
  final int? durationMs;

  const ActivityRecord({
    required this.id,
    required this.deviceId,
    required this.windowTitle,
    this.lan = '',
    this.wifi = '',
    this.battery = '',
    required this.recordedAt,
    this.startedAt,
    this.durationMs,
  });
}
