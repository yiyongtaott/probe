// ═══════════════════════════════════════════════════════════════
// App A — 纯后端静默上报器
// 无 UI、无渲染引擎初始化，仅启动后台 Service + WorkManager
// 目标内存: ~8-12 MB
//
// TODO: 根据实际 workmanager / flutter_background_service 版本
//       调整以下 API 调用（当前版本号见 pubspec.yaml）
// ═══════════════════════════════════════════════════════════════
import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';
import 'shared/background/reporter_service.dart';
import 'shared/utils/device_info.dart';

/// WorkManager 回调（需是顶层函数或静态方法）
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final reporter = ReporterService(
      deviceId: 'phone',
      serverBase: DeviceInfo.defaultServerBase,
    );
    await reporter.onWake();
    return true;
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 注册 WorkManager 周期性任务（~15min 系统窗口唤醒）
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    'phone_report',
    'reportActivity',
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );

  // TODO: 可选 — 启动前台 Service（更频繁上报）
  // flutter_background_service 的 API 请按 pub 版本调整

  // App A 不需要 runApp() — 不初始化渲染引擎
}
