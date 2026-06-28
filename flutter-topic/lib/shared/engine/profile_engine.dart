import '../models/models.dart';
import '../storage/database.dart';
import '../ai/ai_provider.dart';
import '../ai/topic_prompt_config.dart';
import '../services/ai_config_manager.dart';
import '../services/background_service.dart';

/// ── 档案引擎 ────────────────────────────────────────────
/// 按角色从对话内容归纳整理出各角色（系统成员）的资料档案
class ProfileEngine {
  final AiProvider? _ai;

  ProfileEngine({AiProvider? ai}) : _ai = ai;

  /// 为指定角色生成档案（不需要 AI，从对话消息中提取）
  static Future<RoleProfile> compileProfileFromMessages(ChatRole role) async {
    // 获取该角色发送的所有消息
    final allConvs = await LocalDatabase.getAllConversations();
    final roleMessages = <ConversationMessage>[];
    final allMessages = <ConversationMessage>[];

    for (final conv in allConvs) {
      final msgs = await LocalDatabase.getMessages(conv.sessionId);
      allMessages.addAll(msgs);
      if (role.id != null) {
        roleMessages.addAll(msgs.where((m) => m.roleId == role.id));
      }
    }

    // 按会话分组
    final sessions = <String, List<ConversationMessage>>{};
    for (final m in roleMessages) {
      sessions.putIfAbsent(m.sessionId, () => []).add(m);
    }

    // 构建 MD 格式档案
    final buf = StringBuffer();
    buf.writeln('# ${role.name} 个人档案');
    buf.writeln();
    buf.writeln('> 最后更新: ${DateTime.now().toIso8601String().substring(0, 19)}');
    buf.writeln();

    if (sessions.isEmpty) {
      buf.writeln('*暂无对话记录*');
    } else {
      buf.writeln('## 📊 概览');
      buf.writeln();
      buf.writeln('- 总对话数: ${sessions.length}');
      buf.writeln('- 总消息数: ${roleMessages.length}');
      if (roleMessages.isNotEmpty) {
        final totalChars = roleMessages.fold<int>(0, (s, m) => s + m.text.length);
        buf.writeln('- 总字数: $totalChars');
      }
      buf.writeln();

      // 收集话题请求
      final topicRequests = roleMessages.where((m) =>
          m.text.startsWith('/topic') || m.text.startsWith('💡'));
      if (topicRequests.isNotEmpty) {
        buf.writeln('## 💬 发起的话题');
        buf.writeln();
        for (final t in topicRequests.take(10)) {
          final dt = DateTime.fromMillisecondsSinceEpoch(t.timestamp);
          final dateStr = '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          buf.writeln('- $dateStr ${t.text}');
        }
        buf.writeln();
      }

      // 按对话展示消息
      buf.writeln('## 📝 对话摘录');
      buf.writeln();
      int sessionIdx = 0;
      for (final entry in sessions.entries.take(10)) {
        sessionIdx++;
        final msgs = entry.value;
        if (msgs.isEmpty) continue;
        buf.writeln('### 对话 #$sessionIdx（${msgs.length} 条消息）');
        buf.writeln();
        for (final m in msgs.take(20)) {
          final dt = DateTime.fromMillisecondsSinceEpoch(m.timestamp);
          final dateStr = '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          final text = m.text.length > 100 ? '${m.text.substring(0, 100)}…' : m.text;
          buf.writeln('> _[$dateStr]_ $text');
          buf.writeln();
        }
        if (msgs.length > 20) {
          buf.writeln('> … 还有 ${msgs.length - 20} 条未显示');
          buf.writeln();
        }
      }
      if (sessions.length > 10) {
        buf.writeln('> … 共 ${sessions.length} 个对话');
      }
    }

    return RoleProfile(
      roleId: role.id ?? 0,
      roleName: role.name,
      profileText: buf.toString(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      avatarPath: role.avatarPath,
    );
  }

  /// 为所有角色生成档案
  static Future<List<RoleProfile>> compileAllProfiles() async {
    final roles = await LocalDatabase.getAllRoles();
    final profiles = <RoleProfile>[];
    for (final role in roles) {
      if (role.id == null) continue;
      final profile = await compileProfileFromMessages(role);
      await LocalDatabase.upsertProfile(profile);
      profiles.add(profile);
    }
    return profiles;
  }

  /// 用 AI 增强档案（可选：让 AI 分析后润色档案内容）
  Future<String?> enhanceWithAi(String rawProfile, ChatRole role) async {
    if (_ai == null) return null;
    final systemPrompt = '你是一个角色分析师。请根据提供的原始对话档案，'
        '提炼出一个清晰、有深度的角色个人资料卡片。'
        '使用 Markdown 格式，包含：性格特点、兴趣方向、说话风格、关注话题。'
        '保持客观，基于实际对话内容。';

    final userPrompt = '以下是 ${role.name} 的原始对话档案：\n\n$rawProfile\n\n'
        '请生成一份结构化的角色资料档案。';

    final result = await _ai!.chatCompletion(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: 0.5,
      maxTokens: 1024,
    );

    if (result != null && result.trim().isNotEmpty) {
      return result.trim();
    }
    return null;
  }
}
