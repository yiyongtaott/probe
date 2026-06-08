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

  factory ReportPayload.fromJson(Map<String, dynamic> json) => ReportPayload(
        window: json['window'] as String,
        lan: json['lan'] as String,
        wifi: json['wifi'] as String,
        battery: json['battery'] as String,
        start: json['start'] as int,
        end: json['end'] as int,
        dur: json['dur'] as int,
      );
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

  factory ActivityRecord.fromJson(Map<String, dynamic> json) => ActivityRecord(
        id: json['id'] as int,
        deviceId: json['deviceId'] as String? ?? '',
        windowTitle:
            json['windowTitle'] as String? ?? json['window'] as String? ?? '',
        lan: json['lan'] as String? ?? '',
        wifi: json['wifi'] as String? ?? '',
        battery: json['battery'] as String? ?? '',
        recordedAt: json['recordedAt'] as int,
        startedAt: json['startedAt'] as int?,
        durationMs: json['durationMs'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceId': deviceId,
        'windowTitle': windowTitle,
        'lan': lan,
        'wifi': wifi,
        'battery': battery,
        'recordedAt': recordedAt,
        'startedAt': startedAt,
        'durationMs': durationMs,
      };
}

/// 设备状态（来自同步数据）
class DeviceState {
  final String id;
  final String status;
  final int lastSeen;
  final String lan;
  final String wifi;
  final String battery;
  final String ip;

  const DeviceState({
    required this.id,
    this.status = '',
    this.lastSeen = 0,
    this.lan = '',
    this.wifi = '',
    this.battery = '',
    this.ip = '',
  });
}

/// 聊天消息
class ChatMessage {
  final int id;
  final String user;
  final String message;
  final int timestamp;
  final String sessionId;

  const ChatMessage({
    this.id = 0,
    this.user = '',
    this.message = '',
    this.timestamp = 0,
    this.sessionId = '',
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as int? ?? 0,
        user: json['user'] as String? ?? '',
        message: json['message'] as String? ?? '',
        timestamp: json['timestamp'] as int? ?? 0,
        sessionId: json['sessionId'] as String? ?? '',
      );
}

/// 在线用户
class OnlineUser {
  final String sessionId;
  final String userName;
  final String ip;
  final int lastSeen;

  const OnlineUser({
    this.sessionId = '',
    this.userName = '',
    this.ip = '',
    this.lastSeen = 0,
  });

  factory OnlineUser.fromJson(Map<String, dynamic> json) => OnlineUser(
        sessionId: json['sessionId'] as String? ?? '',
        userName: json['userName'] as String? ?? json['user'] as String? ?? '',
        ip: json['ip'] as String? ?? '',
        lastSeen: json['lastSeen'] as int? ?? 0,
      );
}

/// 聚合同步接口响应
class SyncPayload {
  final Map<String, dynamic> devices;
  final List<ChatMessage> chatHistory;
  final int onlineCount;
  final Map<String, OnlineUser> onlineUsers;

  const SyncPayload({
    required this.devices,
    required this.chatHistory,
    required this.onlineCount,
    required this.onlineUsers,
  });

  factory SyncPayload.fromJson(Map<String, dynamic> json) => SyncPayload(
        devices: json['deviceData'] ?? {},
        chatHistory: (json['chatHistory'] as List?)
                ?.map(
                    (e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
        onlineCount: json['onlineCount'] as int? ?? 0,
        onlineUsers:
            (json['onlineUsers'] as Map<String, dynamic>?)?.map(
                  (k, v) => MapEntry(
                      k, OnlineUser.fromJson(v as Map<String, dynamic>)),
                ) ??
                {},
      );
}

/// 活动历史分页结果
class HistoryResult {
  final List<ActivityRecord> rows;
  final bool done;
  final int? nextTs;
  final int? nextId;

  const HistoryResult({
    required this.rows,
    required this.done,
    this.nextTs,
    this.nextId,
  });
}

/// 心跳结果
class HeartbeatResult {
  final bool success;
  final int onlineCount;
  final Map<String, dynamic> onlineUsers;

  const HeartbeatResult({
    required this.success,
    this.onlineCount = 0,
    this.onlineUsers = const {},
  });
}

/// AI 摘要结果
class AiSummaryResult {
  final String summary;
  final String provider;
  final int usedToday;

  const AiSummaryResult({
    this.summary = '',
    this.provider = '',
    this.usedToday = 0,
  });
}

/// AI 用量结果
class AiUsageResult {
  final String day;
  final Map<String, int> usage;

  const AiUsageResult({
    this.day = '',
    this.usage = const {},
  });
}
