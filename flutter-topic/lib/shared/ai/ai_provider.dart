import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/models.dart';

/// ── AI 提供商抽象接口 ──────────────────────────────────
abstract class AiProvider {
  final AiConfig config;
  AiProvider(this.config);

  String get displayName;

  /// 最后一次错误的详细信息（用于调试面板展示）
  String? _lastError;
  String? get lastError => _lastError;

  /// 通用聊天补全接口
  Future<String?> chatCompletion({
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 1024,
  });

  void dispose();
}

/// ── 工厂 ──────────────────────────────────────────────
AiProvider createAiProvider(AiConfig config) {
  switch (config.provider) {
    case 'openai':
    case 'openrouter':
    case 'custom':
      return OpenAiCompatibleProvider(config);
    case 'anthropic':
      return AnthropicProvider(config);
    case 'gemini':
      return GeminiProvider(config);
    case 'ollama':
      return OllamaProvider(config);
    default:
      return OpenAiCompatibleProvider(config);
  }
}

// ════════════════════════════════════════════════════════
//  OpenAI 兼容格式（OpenAI / OpenRouter / DeepSeek / 自定义）
// ════════════════════════════════════════════════════════
class OpenAiCompatibleProvider extends AiProvider {
  final http.Client _http;

  OpenAiCompatibleProvider(super.config) : _http = http.Client();

  @override
  String get displayName => 'OpenAI 兼容';

  @override
  Future<String?> chatCompletion({
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 1024,
  }) async {
    try {
      final uri = Uri.parse('${config.baseUrl}/chat/completions');
      final body = jsonEncode({
        'model': config.model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
        'temperature': temperature,
        'max_tokens': maxTokens,
      });

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (config.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${config.apiKey}';
      }
      // OpenRouter 推荐的应用标识头
      if (config.provider == 'openrouter') {
        headers['HTTP-Referer'] = 'https://tulpa-topic.app';
        headers['X-Title'] = 'TulpaTopic';
      }

      _lastError = null;
      final res = await _http
          .post(uri, body: body, headers: headers)
          .timeout(const Duration(seconds: 30));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices == null || choices.isEmpty) {
          _lastError = '响应中缺少 choices 字段';
          return null;
        }
        final message = choices.first['message'] as Map<String, dynamic>?;
        final content = message?['content'] as String?;
        if (content == null || content.trim().isEmpty) {
          _lastError = '响应 content 为空';
          return null;
        }
        return content;
      }

      // HTTP 错误 — 解析响应体获取详细信息
      final errorDetail = _parseErrorBody(res.body, res.statusCode);
      _lastError = 'HTTP ${res.statusCode}: $errorDetail';
      return null;
    } on http.ClientException catch (e) {
      _lastError = '网络错误: ${e.message}';
      return null;
    } on FormatException catch (e) {
      _lastError = '响应格式错误: ${e.message}';
      return null;
    } catch (e) {
      _lastError = '未知错误: $e';
      return null;
    }
  }

  /// 解析 OpenAI 兼容 API 的错误响应体
  String _parseErrorBody(String body, int statusCode) {
    try {
      final data = jsonDecode(body);
      // OpenAI 格式: error.message
      final err = data['error'];
      if (err is Map) {
        final msg = err['message']?.toString() ?? '';
        final code = err['code']?.toString() ?? '';
        return code.isNotEmpty ? '[$code] $msg' : msg;
      }
      // OpenRouter 格式: error.message
      if (err is String) return err;
      // fallback
      return body.length > 200 ? '${body.substring(0, 200)}…' : body;
    } catch (_) {
      return statusCode == 401
          ? 'API Key 无效或未授权'
          : statusCode == 429
              ? '请求过于频繁，请稍后重试'
              : statusCode == 500
                  ? '服务端内部错误'
                  : 'HTTP $statusCode（无法解析响应体）';
    }
  }

  /// 获取模型列表（OpenRouter / OpenAI 兼容 API）
  Future<List<String>> fetchModels() async {
    try {
      final uri = Uri.parse('${config.baseUrl}/models');
      final headers = <String, String>{};
      if (config.apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer ${config.apiKey}';
      }
      if (config.provider == 'openrouter') {
        headers['HTTP-Referer'] = 'https://tulpa-topic.app';
        headers['X-Title'] = 'TulpaTopic';
      }

      final res = await _http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        _lastError = '获取模型列表失败: HTTP ${res.statusCode}';
        return [];
      }

      final data = jsonDecode(res.body);

      // OpenRouter 返回: { data: [{ id: "...", pricing: {...} }] }
      // OpenAI 返回: { data: [{ id: "..." }] }
      final list = data['data'] as List?;
      if (list == null || list.isEmpty) {
        _lastError = '模型列表为空';
        return [];
      }

      final models = <String>[];
      if (config.provider == 'openrouter') {
        // OpenRouter: 过滤出免费模型（pricing.prompt == "0" && pricing.completion == "0"）
        for (final m in list) {
          final id = m['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final pricing = m['pricing'] as Map?;
          final isFree = pricing != null &&
              pricing['prompt']?.toString() == '0' &&
              pricing['completion']?.toString() == '0';
          if (isFree) models.add(id);
        }
        // 同时添加 openrouter/auto 和 openrouter/free 路由
        if (!models.contains('openrouter/auto')) models.insert(0, 'openrouter/auto');
        if (!models.contains('openrouter/free')) models.insert(0, 'openrouter/free');
      } else {
        // OpenAI 等: 全部返回
        for (final m in list) {
          final id = m['id']?.toString() ?? '';
          if (id.isNotEmpty) models.add(id);
        }
      }

      return models;
    } on http.ClientException catch (e) {
      _lastError = '获取模型列表网络错误: ${e.message}';
      return [];
    } catch (e) {
      _lastError = '获取模型列表错误: $e';
      return [];
    }
  }

  @override
  void dispose() => _http.close();
}

// ════════════════════════════════════════════════════════
//  Anthropic Claude
// ════════════════════════════════════════════════════════
class AnthropicProvider extends AiProvider {
  final http.Client _http;

  AnthropicProvider(super.config) : _http = http.Client();

  @override
  String get displayName => 'Anthropic Claude';

  @override
  Future<String?> chatCompletion({
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 1024,
  }) async {
    try {
      final uri = Uri.parse('${config.baseUrl}/v1/messages');
      final body = jsonEncode({
        'model': config.model,
        'max_tokens': maxTokens,
        'temperature': temperature,
        'system': systemPrompt,
        'messages': [
          {'role': 'user', 'content': userPrompt},
        ],
      });
      final res = await _http
          .post(uri, body: body, headers: {
            'Content-Type': 'application/json',
            'x-api-key': config.apiKey,
            'anthropic-version': '2023-06-01',
          })
          .timeout(const Duration(seconds: 30));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final content = data['content'] as List?;
        if (content == null || content.isEmpty) {
          _lastError = '响应中缺少 content 字段';
          return null;
        }
        final textBlock = content.first as Map<String, dynamic>?;
        final text = textBlock?['text'] as String?;
        if (text == null || text.trim().isEmpty) {
          _lastError = '响应 text 为空';
          return null;
        }
        return text;
      }

      final err = _parseAnthropicError(res.body, res.statusCode);
      _lastError = 'HTTP ${res.statusCode}: $err';
      return null;
    } on http.ClientException catch (e) {
      _lastError = '网络错误: ${e.message}';
      return null;
    } catch (e) {
      _lastError = '未知错误: $e';
      return null;
    }
  }

  String _parseAnthropicError(String body, int statusCode) {
    try {
      final data = jsonDecode(body);
      final err = data['error'];
      if (err is Map) {
        final msg = err['message']?.toString() ?? '';
        final type = err['type']?.toString() ?? '';
        return type.isNotEmpty ? '[$type] $msg' : msg;
      }
      return body.length > 200 ? '${body.substring(0, 200)}…' : body;
    } catch (_) {
      return 'HTTP $statusCode';
    }
  }

  @override
  void dispose() => _http.close();
}

// ════════════════════════════════════════════════════════
//  Google Gemini
// ════════════════════════════════════════════════════════
class GeminiProvider extends AiProvider {
  final http.Client _http;

  GeminiProvider(super.config) : _http = http.Client();

  @override
  String get displayName => 'Google Gemini';

  @override
  Future<String?> chatCompletion({
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 1024,
  }) async {
    try {
      final uri = Uri.parse(
        '${config.baseUrl}/v1beta/models/${config.model}:generateContent?key=${config.apiKey}',
      );
      final body = jsonEncode({
        'system_instruction': {
          'parts': [{'text': systemPrompt}],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [{'text': userPrompt}],
          },
        ],
        'generationConfig': {
          'temperature': temperature,
          'maxOutputTokens': maxTokens,
        },
      });
      final res = await _http
          .post(uri, body: body, headers: {'Content-Type': 'application/json'})
          .timeout(const Duration(seconds: 30));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final candidates = data['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) {
          _lastError = '响应中缺少 candidates 字段';
          if (data['promptFeedback'] != null) {
            _lastError = '请求被屏蔽: ${jsonEncode(data['promptFeedback'])}';
          }
          return null;
        }
        final content = candidates.first['content'] as Map<String, dynamic>?;
        final parts = content?['parts'] as List?;
        if (parts == null || parts.isEmpty) {
          _lastError = '响应 parts 为空';
          return null;
        }
        final text = parts.first['text'] as String?;
        if (text == null || text.trim().isEmpty) {
          _lastError = '响应 text 为空';
          return null;
        }
        return text;
      }

      _lastError = 'HTTP ${res.statusCode}: ${_truncateBody(res.body)}';
      return null;
    } on http.ClientException catch (e) {
      _lastError = '网络错误: ${e.message}';
      return null;
    } catch (e) {
      _lastError = '未知错误: $e';
      return null;
    }
  }

  String _truncateBody(String body) {
    if (body.length <= 200) return body;
    try {
      final data = jsonDecode(body);
      final err = data['error'];
      if (err is Map) {
        final msg = err['message']?.toString() ?? '';
        final status = err['status']?.toString() ?? '';
        return status.isNotEmpty ? '[$status] $msg' : msg;
      }
    } catch (_) {}
    return '${body.substring(0, 200)}…';
  }

  @override
  void dispose() => _http.close();
}

// ════════════════════════════════════════════════════════
//  Ollama（本地部署）
// ════════════════════════════════════════════════════════
class OllamaProvider extends AiProvider {
  final http.Client _http;

  OllamaProvider(super.config) : _http = http.Client();

  @override
  String get displayName => 'Ollama (本地)';

  @override
  Future<String?> chatCompletion({
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 1024,
  }) async {
    try {
      final uri = Uri.parse('${config.baseUrl}/api/chat');
      final body = jsonEncode({
        'model': config.model,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
        'stream': false,
        'options': {
          'temperature': temperature,
          'num_predict': maxTokens,
        },
      });
      final res = await _http
          .post(uri, body: body, headers: {'Content-Type': 'application/json'})
          .timeout(const Duration(seconds: 60));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final message = data['message'] as Map<String, dynamic>?;
        final content = message?['content'] as String?;
        if (content == null || content.trim().isEmpty) {
          _lastError = '响应 content 为空';
          return null;
        }
        return content;
      }

      _lastError = 'HTTP ${res.statusCode}: ${_truncateBody(res.body)}';
      return null;
    } on http.ClientException catch (e) {
      _lastError = '网络错误: ${e.message}';
      return null;
    } catch (e) {
      _lastError = '未知错误: $e';
      return null;
    }
  }

  String _truncateBody(String body) {
    return body.length <= 200 ? body : '${body.substring(0, 200)}…';
  }

  @override
  void dispose() => _http.close();
}
