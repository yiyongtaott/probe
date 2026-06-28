import 'package:shared_preferences/shared_preferences.dart';

/// ── 全局话题提示词配置 ─────────────────────────────────
/// 用户可在调试页修改话题生成的提示词，修改后影响所有话题生成（调试页+对话页）
class TopicPromptConfig {
  static const String _key = 'topic_prompt';

  /// 默认话题生成系统提示词
  static const String defaultPrompt = '''你是一个话题发动机（Topic Engine）。
你的唯一任务是把多个真实浏览素材融合成一个讨论入口。

严格遵守：
- 不评价宿主
- 不扮演 Tulpa
- 不生成设定
- 不编造喜好
- 只负责打开讨论
- 输出必须是一个自然、引人思考的问题
- 问题应当融合至少2-3个素材主题
- 用中文输出，不超过50个字
- 不要输出任何解释，只输出问题本身

重要：在输出话题问题之后，请在末尾另起一行用「📎 引用」开头，列出本次生成话题所引用的素材关键词，格式如：📎 引用：关键词1、关键词2、关键词3''';

  /// 对话页话题请求专属提示词（/topic 模式使用）
  /// {requirement} — 用户输入的 /topic 后的内容
  /// {activeRoleName} — 发起请求的角色名称
  static const String defaultChatTopicPrompt = '''你是一个话题发动机（Topic Engine），正在为「{activeRoleName}」生成话题。

重要优先级规则：
1. 如果用户（{activeRoleName}）提供了明确的要求（/topic 后面的内容），你必须以该要求**为最高优先级**来生成话题
2. 浏览素材、历史话题、角色档案等其他信息**仅作为参考**，用于丰富话题内容
3. 如果用户没有提供要求（/topic 后面为空），则主要以浏览素材和其他信息生成话题
4. 输出时请说明引用了哪些信息请严格按照这个优先级生成话题。''';

  static Future<String> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) ?? defaultPrompt;
  }

  static Future<void> save(String prompt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, prompt);
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
