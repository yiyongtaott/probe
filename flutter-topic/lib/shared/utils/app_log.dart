import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

/// 简单日志工具
class AppLog {
  static void info(String message) {
    developer.log(message, name: 'TulpaTopic');
    debugPrint('[TulpaTopic] $message');
  }

  static void error(String message, [Object? error, StackTrace? stack]) {
    final detail = error == null ? message : '$message: $error';
    developer.log(detail, name: 'TulpaTopic', level: 1000, stackTrace: stack);
    debugPrint('[TulpaTopic ERROR] $detail');
  }
}
