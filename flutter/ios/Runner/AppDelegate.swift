import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // 原生后台抓取（旧版 Background Fetch，iOS 12+；未声明
    // BGTaskSchedulerPermittedIdentifiers 时在 iOS 13+ 同样生效）。
    // 系统按使用习惯调度，频率由 iOS 决定。
    UIApplication.shared.setMinimumBackgroundFetchInterval(
      UIApplication.backgroundFetchIntervalMinimum
    )

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // 后台抓取回调：把事件转发给 Dart（main_full.dart 里的
  // 'ultralightprobe/ios' 通道 backgroundFetch 方法），成功后上报一次。
  // 每次后台执行约 30 秒，必须在预算内调用 completionHandler。
  override func application(
    _ application: UIApplication,
    performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    invokeBackgroundFetch(attempts: 40, completionHandler: completionHandler)
  }

  private func invokeBackgroundFetch(
    attempts: Int,
    completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard attempts > 0 else {
      completionHandler(.noData)
      return
    }

    // 后台冷启动时 FlutterViewController / Dart 处理程序可能尚未就绪，轮询等待。
    guard let controller = window?.rootViewController as? FlutterViewController else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.invokeBackgroundFetch(attempts: attempts - 1, completionHandler: completionHandler)
      }
      return
    }

    let channel = FlutterMethodChannel(
      name: "ultralightprobe/ios",
      binaryMessenger: controller.binaryMessenger
    )
    channel.invokeMethod("backgroundFetch", arguments: nil) { result in
      if let ok = result as? Bool {
        completionHandler(ok ? .newData : .noData)
      } else if result is FlutterError {
        // Dart handler 尚未注册完成，稍后重试。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          self.invokeBackgroundFetch(attempts: attempts - 1, completionHandler: completionHandler)
        }
      } else {
        completionHandler(.noData)
      }
    }
  }
}
