/// ── 素材池条目 ──────────────────────────────────────────
class MaterialItem {
  final int? id;
  final String title;
  final String sourceApp;
  final int timestamp;
  final String? topic;
  final double weight;

  const MaterialItem({
    this.id,
    required this.title,
    required this.sourceApp,
    required this.timestamp,
    this.topic,
    this.weight = 1.0,
  });

  String get dateKey {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'title': title,
        'source_app': sourceApp,
        'timestamp': timestamp,
        'topic': topic,
        'weight': weight,
        'date_key': dateKey,
      };

  factory MaterialItem.fromMap(Map<String, dynamic> map) => MaterialItem(
        id: map['id'] as int?,
        title: map['title'] as String,
        sourceApp: map['source_app'] as String? ?? '',
        timestamp: map['timestamp'] as int,
        topic: map['topic'] as String?,
        weight: (map['weight'] as num?)?.toDouble() ?? 1.0,
      );
}

/// ── 聚类后的主题 ────────────────────────────────────────
class TopicCluster {
  final String topic;
  final int count;
  final double totalWeight;
  final int lastSeen;
  final List<String> sampleTitles;
  final Set<String> sourceApps;

  const TopicCluster({
    required this.topic,
    required this.count,
    required this.totalWeight,
    required this.lastSeen,
    required this.sampleTitles,
    this.sourceApps = const {},
  });

  double get avgWeight => count > 0 ? totalWeight / count : 0;
}

/// ── 话题建议 ──────────────────────────────────────────
class TopicSuggestion {
  final int? id;
  final String topic;
  final String question;
  final String? context;
  final int createdAt;
  final bool used;

  const TopicSuggestion({
    this.id,
    required this.topic,
    required this.question,
    this.context,
    required this.createdAt,
    this.used = false,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'topic': topic,
        'question': question,
        'context': context,
        'created_at': createdAt,
        'used': used ? 1 : 0,
      };

  factory TopicSuggestion.fromMap(Map<String, dynamic> map) => TopicSuggestion(
        id: map['id'] as int?,
        topic: map['topic'] as String? ?? '',
        question: map['question'] as String,
        context: map['context'] as String?,
        createdAt: map['created_at'] as int,
        used: (map['used'] as int?) == 1,
      );
}

/// ── 对话会话 ──────────────────────────────────────────
class Conversation {
  final int? id;
  final String sessionId;
  final String topic;
  final int createdAt;

  const Conversation({
    this.id,
    required this.sessionId,
    required this.topic,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'topic': topic,
        'created_at': createdAt,
      };

  factory Conversation.fromMap(Map<String, dynamic> map) => Conversation(
        id: map['id'] as int?,
        sessionId: map['session_id'] as String,
        topic: map['topic'] as String? ?? '',
        createdAt: map['created_at'] as int,
      );
}

/// ── 聊天角色 ──────────────────────────────────────────
class ChatRole {
  final int? id;
  final String name;
  final String avatar; // emoji 字符或本地文件路径
  final String? avatarPath; // 本地图片文件路径（优先于 avatar）
  final bool isDefault;

  const ChatRole({
    this.id,
    required this.name,
    this.avatar = '🧑',
    this.avatarPath,
    this.isDefault = false,
  });

  static const defaultRoles = [
    ChatRole(id: 1, name: 'Host', avatar: '🧑', isDefault: true),
    ChatRole(id: 2, name: 'Tulpa', avatar: '🫧', isDefault: true),
  ];

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'avatar': avatar,
        'avatar_path': avatarPath,
        'is_default': isDefault ? 1 : 0,
      };

  factory ChatRole.fromMap(Map<String, dynamic> map) => ChatRole(
        id: map['id'] as int?,
        name: map['name'] as String? ?? '',
        avatar: map['avatar'] as String? ?? '🧑',
        avatarPath: map['avatar_path'] as String?,
        isDefault: (map['is_default'] as int?) == 1,
      );

  ChatRole copyWith({String? name, String? avatar, String? avatarPath}) => ChatRole(
        id: id,
        name: name ?? this.name,
        avatar: avatar ?? this.avatar,
        avatarPath: avatarPath ?? this.avatarPath,
        isDefault: isDefault,
      );
}

/// ── 对话消息 ──────────────────────────────────────────
class ConversationMessage {
  final int? id;
  final String sessionId;
  final String text;
  final int timestamp;
  final int? roleId; // null = 系统/不区分

  const ConversationMessage({
    this.id,
    required this.sessionId,
    required this.text,
    required this.timestamp,
    this.roleId,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'text': text,
        'timestamp': timestamp,
        'role_id': roleId,
      };

  factory ConversationMessage.fromMap(Map<String, dynamic> map) =>
      ConversationMessage(
        id: map['id'] as int?,
        sessionId: map['session_id'] as String,
        text: map['text'] as String,
        timestamp: map['timestamp'] as int,
        roleId: map['role_id'] as int?,
      );
}

/// ── 事实记录 ──────────────────────────────────────────
class Fact {
  final int? id;
  final String text;
  final String? sourceMessageId;
  final int createdAt;

  const Fact({
    this.id,
    required this.text,
    this.sourceMessageId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'text': text,
        'source_message_id': sourceMessageId,
        'created_at': createdAt,
      };

  factory Fact.fromMap(Map<String, dynamic> map) => Fact(
        id: map['id'] as int?,
        text: map['text'] as String,
        sourceMessageId: map['source_message_id'] as String?,
        createdAt: map['created_at'] as int,
      );
}

/// ── AI 配置 ────────────────────────────────────────────
class AiConfig {
  final String provider;
  final String baseUrl;
  final String apiKey;
  final String model;

  const AiConfig({
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  Map<String, dynamic> toMap() => {
        'provider': provider,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  factory AiConfig.fromMap(Map<String, dynamic> map) => AiConfig(
        provider: map['provider'] as String? ?? 'openrouter',
        baseUrl: map['baseUrl'] as String? ?? '',
        apiKey: map['apiKey'] as String? ?? '',
        model: map['model'] as String? ?? '',
      );

  factory AiConfig.defaultOpenRouter() => const AiConfig(
        provider: 'openrouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'your-key-here',
        model: 'openrouter/free',
      );

  factory AiConfig.defaultOpenAi() => const AiConfig(
        provider: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: '',
        model: 'gpt-4o-mini',
      );

  factory AiConfig.defaultOllama() => const AiConfig(
        provider: 'ollama',
        baseUrl: 'http://localhost:11434',
        apiKey: '',
        model: 'qwen2.5:7b',
      );

  factory AiConfig.defaultAnthropic() => const AiConfig(
        provider: 'anthropic',
        baseUrl: 'https://api.anthropic.com',
        apiKey: '',
        model: 'claude-3-5-sonnet-20241022',
      );

  factory AiConfig.defaultGemini() => const AiConfig(
        provider: 'gemini',
        baseUrl: 'https://generativelanguage.googleapis.com',
        apiKey: '',
        model: 'gemini-1.5-flash',
      );

  factory AiConfig.defaultCustom() => const AiConfig(
        provider: 'custom',
        baseUrl: '',
        apiKey: '',
        model: '',
      );

  bool get isConfigured =>
      provider.isNotEmpty &&
      baseUrl.isNotEmpty &&
      model.isNotEmpty &&
      (provider == 'ollama' || apiKey.isNotEmpty);
}

/// ── 角色档案（MD 格式） ────────────────────────────────
class RoleProfile {
  final int? id;
  final int roleId;
  final String roleName;
  final String profileText;
  final int createdAt;
  final int updatedAt;
  final String? avatarPath;

  const RoleProfile({
    this.id,
    required this.roleId,
    required this.roleName,
    required this.profileText,
    required this.createdAt,
    required this.updatedAt,
    this.avatarPath,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'role_id': roleId,
        'role_name': roleName,
        'profile_text': profileText,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'avatar_path': avatarPath,
      };

  factory RoleProfile.fromMap(Map<String, dynamic> map) => RoleProfile(
        id: map['id'] as int?,
        roleId: map['role_id'] as int,
        roleName: map['role_name'] as String? ?? '',
        profileText: map['profile_text'] as String? ?? '',
        createdAt: map['created_at'] as int,
        updatedAt: map['updated_at'] as int,
        avatarPath: map['avatar_path'] as String?,
      );

  RoleProfile copyWith({String? profileText, String? roleName}) => RoleProfile(
        id: id,
        roleId: roleId,
        roleName: roleName ?? this.roleName,
        profileText: profileText ?? this.profileText,
        createdAt: createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        avatarPath: avatarPath,
      );
}

/// ── 注意力状态快照 ────────────────────────────────────
class AttentionSnapshot {
  final String app;
  final int startedAt;
  final int endedAt;
  final int durationMs;

  const AttentionSnapshot({
    required this.app,
    required this.startedAt,
    this.endedAt = 0,
    this.durationMs = 0,
  });

  AttentionSnapshot copyWith({
    String? app,
    int? startedAt,
    int? endedAt,
    int? durationMs,
  }) =>
      AttentionSnapshot(
        app: app ?? this.app,
        startedAt: startedAt ?? this.startedAt,
        endedAt: endedAt ?? this.endedAt,
        durationMs: durationMs ?? this.durationMs,
      );
}
