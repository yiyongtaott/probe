import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// ── 系统通知服务 ────────────────────────────────────────
/// design2.md 第八节：检测到注意力释放窗口时发送通知
/// 用户点击通知 → 进入话题聊天
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidSettings = AndroidInitializationSettings(
      '@drawable/ic_launcher_foreground',
    );
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTap,
    );
  }

  /// 通知点击回调（由 main.dart 设置）
  static void Function(String? payload)? onTopicNotificationTap;

  static void _onNotificationTap(NotificationResponse response) {
    onTopicNotificationTap?.call(response.payload);
  }

  /// 发送话题推送通知
  static Future<void> showTopicNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      'topic_channel',
      '话题推送',
      channelDescription: '注意力释放窗口检测到时推送讨论话题',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_launcher_foreground',
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      0,
      title,
      body,
      details,
      payload: payload,
    );
  }

  /// 取消所有通知
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
