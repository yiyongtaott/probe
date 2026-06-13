import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProbeLog {
  static const String statusKey = 'probe_last_report_status';
  static const String statusAtKey = 'probe_last_report_at';
  static const String errorKey = 'probe_last_report_error';
  static const String logKey = 'probe_report_log';
  static const int _maxEntries = 80;

  static Future<void> info(String message) => _write('INFO', message);

  static Future<void> warn(String message) => _write('WARN', message);

  static Future<void> error(
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    final detail = error == null ? message : '$message: $error';
    if (stack != null) {
      developer.log(detail, name: 'UltraLightProbe', stackTrace: stack);
    }
    return _write('ERROR', detail);
  }

  static Future<void> reportOk(String message) async {
    await _setStatus('OK', message);
    await info(message);
  }

  static Future<void> reportFail(String message) async {
    await _setStatus('FAIL', message);
    await warn(message);
  }

  static Future<String?> lastStatusText() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final status = prefs.getString(statusKey);
      final at = prefs.getString(statusAtKey);
      final error = prefs.getString(errorKey);
      if (status == null || at == null) return null;
      if (status == 'OK') return '$at OK';
      return '$at FAIL ${error ?? ''}'.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> recentEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(logKey) ?? const <String>[];
    } catch (_) {
      return const <String>[];
    }
  }

  static Future<void> _setStatus(String status, String detail) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(statusKey, status);
      await prefs.setString(statusAtKey, DateTime.now().toIso8601String());
      if (status == 'OK') {
        await prefs.remove(errorKey);
      } else {
        await prefs.setString(errorKey, detail);
      }
    } catch (_) {}
  }

  static Future<void> _write(String level, String message) async {
    final line = '${DateTime.now().toIso8601String()} [$level] $message';
    developer.log(line, name: 'UltraLightProbe');
    debugPrint(line);

    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(logKey) ?? <String>[];
      entries.add(line);
      if (entries.length > _maxEntries) {
        entries.removeRange(0, entries.length - _maxEntries);
      }
      unawaited(prefs.setStringList(logKey, entries));
    } catch (_) {}
  }
}
