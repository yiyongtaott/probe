import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:workmanager/workmanager.dart';
import 'shared/background/reporter_service.dart';
import 'shared/utils/device_info.dart';
import 'shared/api/server_selector.dart';

/// 全局服务器 URL（main() 中探测决定）
String activeServerBase = ServerSelector.primary;

/// WorkManager 回调
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) {
      await service.startService();
    }
    return true;
  });
}

/// 前台 Service 入口
@pragma('vm:entry-point')
void onStart(ServiceInstance service) {
  final reporter = ReporterService(
    deviceId: DeviceInfo.detectDeviceIdSync(),
    serverBase: activeServerBase,
  );

  unawaited(reporter.startContinuousLoop());

  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}

/// 初始化并启动前台 Service
Future<void> initializeForegroundService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'probe_reporter',
      initialNotificationTitle: 'UltraLightProbe',
      initialNotificationContent: '正在上报活动状态',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(autoStart: true, onForeground: onStart),
  );
  await service.startService();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 探测服务器地址
  final selector = ServerSelector();
  activeServerBase = await selector.probeAndFailover();

  // 注册 WorkManager 周期性任务
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    'phone_report',
    'reportActivity',
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );

  // 启动前台 Service
  await initializeForegroundService();

  // App A 不需要 runApp()
}
