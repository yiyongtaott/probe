import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

/// ── AI 配置管理器 ───────────────────────────────────────
class AiConfigManager {
  static const String _key = 'ai_config';

  static Future<AiConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_key);
      if (json == null) return AiConfig.defaultOpenRouter();
      final map = jsonDecode(json) as Map<String, dynamic>;
      return AiConfig.fromMap(map);
    } catch (_) {
      return AiConfig.defaultOpenRouter();
    }
  }

  static Future<void> save(AiConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(config.toMap()));
  }

  /// 预设配置列表（默认选中 OpenRouter）
  static List<AiConfig> get presets => [
        AiConfig.defaultOpenRouter(),
        AiConfig.defaultOpenAi(),
        AiConfig.defaultAnthropic(),
        AiConfig.defaultGemini(),
        AiConfig.defaultOllama(),
        AiConfig.defaultCustom(),
      ];

  /// provider 友好名称
  static const Map<String, String> providerNames = {
    'openrouter': 'OpenRouter',
    'openai': 'OpenAI 兼容',
    'anthropic': 'Anthropic Claude',
    'gemini': 'Google Gemini',
    'ollama': 'Ollama (本地)',
    'custom': '自定义',
  };
}
