import Flutter
import UIKit
import workmanager

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // 让后台任务引擎也能注册 Flutter 插件（BGAppRefreshTask 冷启动时需要）
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    // iOS 13+: BGTaskScheduler 后台刷新，每 ~15 分钟一次（系统决定实际时机）。
    // 标识符需与 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 一致。
    if #available(iOS 13.0, *) {
      WorkmanagerPlugin.registerPeriodicTask(
        withIdentifier: "com.example.probeApp.iOSBackgroundRefresh",
        frequency: NSNumber(value: 15 * 60)
      )
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
