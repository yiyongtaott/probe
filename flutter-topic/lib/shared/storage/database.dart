import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import '../utils/activity_filter.dart';

/// 本地数据库
class LocalDatabase {
  static Database? _db;
  static const int _version = 4; // v4: role_profiles 角色档案表

  static Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'tulpa_topic.db');
    _db = await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return _db!;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE material_pool (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        title       TEXT    NOT NULL,
        source_app  TEXT    NOT NULL DEFAULT '',
        timestamp   INTEGER NOT NULL,
        topic       TEXT,
        weight      REAL    NOT NULL DEFAULT 1.0,
        date_key    TEXT    NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_material_date ON material_pool(date_key)');
    await db.execute('CREATE INDEX idx_material_title ON material_pool(title)');

    await db.execute('''
      CREATE TABLE topic_suggestions (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        topic       TEXT    NOT NULL,
        question    TEXT    NOT NULL,
        context     TEXT,
        created_at  INTEGER NOT NULL,
        used        INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE conversations (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id  TEXT    NOT NULL UNIQUE,
        topic       TEXT    NOT NULL,
        created_at  INTEGER NOT NULL
      )
    ''');

    // v2: 增加 role_id 字段
    await db.execute('''
      CREATE TABLE conversation_messages (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id  TEXT    NOT NULL,
        text        TEXT    NOT NULL,
        timestamp   INTEGER NOT NULL,
        role_id     INTEGER,
        FOREIGN KEY (session_id) REFERENCES conversations(session_id)
      )
    ''');
    await db.execute('CREATE INDEX idx_msg_session ON conversation_messages(session_id)');

    // v2: 角色表
    await db.execute('''
      CREATE TABLE chat_roles (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT    NOT NULL,
        avatar      TEXT    NOT NULL DEFAULT '🧑',
        avatar_path TEXT,
        is_default  INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // v2: 插入默认角色
    await db.insert('chat_roles', {'name': 'Host', 'avatar': '🧑', 'is_default': 1});
    await db.insert('chat_roles', {'name': 'Tulpa', 'avatar': '🫧', 'is_default': 1});

    await db.execute('''
      CREATE TABLE facts (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        text              TEXT    NOT NULL,
        source_message_id TEXT,
        created_at        INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE daily_topics (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        date_key    TEXT    NOT NULL,
        topics_json TEXT    NOT NULL,
        created_at  INTEGER NOT NULL,
        UNIQUE(date_key)
      )
    ''');
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2: conversation_messages 增加 role_id, 新建 chat_roles 表
      await db.execute('ALTER TABLE conversation_messages ADD COLUMN role_id INTEGER');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS chat_roles (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          name        TEXT    NOT NULL,
          avatar      TEXT    NOT NULL DEFAULT '🧑',
          avatar_path TEXT,
          is_default  INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.insert('chat_roles', {'name': 'Host', 'avatar': '🧑', 'is_default': 1});
      await db.insert('chat_roles', {'name': 'Tulpa', 'avatar': '🫧', 'is_default': 1});
    }
    if (oldVersion < 3) {
      // v2 → v3: chat_roles 增加 avatar_path 列
      // 注意：v1→v2 路径已创建带 avatar_path 的表，这里可能重复，用 try-catch
      try {
        await db.execute('ALTER TABLE chat_roles ADD COLUMN avatar_path TEXT');
      } catch (_) {
        // 列已存在（v1→v2 路径已创建），忽略
      }
    }
    if (oldVersion < 4) {
      // v3 → v4: 新增 role_profiles 表
    await db.execute('''
      CREATE TABLE IF NOT EXISTS role_profiles (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        role_id     INTEGER NOT NULL,
        role_name   TEXT    NOT NULL DEFAULT '',
        profile_text TEXT   NOT NULL,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL,
        avatar_path TEXT
      )
    ''');
    }
  }

  // ════════════════════════════════════════════════════
  //  素材池 CRUD
  // ════════════════════════════════════════════════════

  static Future<void> insertMaterial(MaterialItem item) async {
    final sanitizedTitle = ActivityFilter.sanitize(item.title);
    if (sanitizedTitle == null) return;

    final db = await database;
    final cleanItem = MaterialItem(
      title: sanitizedTitle,
      sourceApp: item.sourceApp,
      timestamp: item.timestamp,
      weight: item.weight,
    );

    final existing = await db.query(
      'material_pool',
      where: 'date_key = ? AND title = ?',
      whereArgs: [cleanItem.dateKey, cleanItem.title],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final row = existing.first;
      final newWeight = (row['weight'] as double) + cleanItem.weight;
      await db.update(
        'material_pool',
        {'weight': newWeight, 'timestamp': cleanItem.timestamp, 'source_app': cleanItem.sourceApp},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    } else {
      await db.insert('material_pool', cleanItem.toMap());
    }
  }

  static Future<List<MaterialItem>> getMaterialsForDate(String dateKey) async {
    final db = await database;
    final rows = await db.query(
      'material_pool',
      where: 'date_key = ?',
      whereArgs: [dateKey],
      orderBy: 'weight DESC, timestamp DESC',
    );
    return rows.map(MaterialItem.fromMap).toList();
  }

  static Future<List<MaterialItem>> getTodayMaterials() async {
    return getMaterialsForDate(_todayKey());
  }

  static Future<List<MaterialItem>> getRecentMaterials({int days = 1}) async {
    final db = await database;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final cutoffMs = cutoff.millisecondsSinceEpoch;
    final rows = await db.query(
      'material_pool',
      where: 'timestamp >= ?',
      whereArgs: [cutoffMs],
      orderBy: 'timestamp DESC',
    );
    return rows.map(MaterialItem.fromMap).toList();
  }

  static Future<int> cleanupOldMaterials({int keepDays = 7}) async {
    final db = await database;
    final cutoff = DateTime.now().subtract(Duration(days: keepDays));
    final cutoffMs = cutoff.millisecondsSinceEpoch;
    return db.delete('material_pool', where: 'timestamp < ?', whereArgs: [cutoffMs]);
  }

  static Future<int> getTodayMaterialCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(DISTINCT title) as cnt FROM material_pool WHERE date_key = ?',
      [_todayKey()],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  // ════════════════════════════════════════════════════
  //  话题建议 CRUD
  // ════════════════════════════════════════════════════

  static Future<int> insertTopicSuggestion(TopicSuggestion suggestion) async {
    final db = await database;
    return db.insert('topic_suggestions', suggestion.toMap());
  }

  static Future<List<TopicSuggestion>> getUnusedSuggestions() async {
    final db = await database;
    final rows = await db.query('topic_suggestions', where: 'used = 0', orderBy: 'created_at DESC');
    return rows.map(TopicSuggestion.fromMap).toList();
  }

  static Future<void> markSuggestionUsed(int id) async {
    final db = await database;
    await db.update('topic_suggestions', {'used': 1}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<TopicSuggestion?> getSuggestionById(int id) async {
    final db = await database;
    final rows = await db.query('topic_suggestions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return TopicSuggestion.fromMap(rows.first);
  }

  // ════════════════════════════════════════════════════
  //  对话 CRUD
  // ════════════════════════════════════════════════════

  static Future<int> insertConversation(Conversation conv) async {
    final db = await database;
    return db.insert('conversations', conv.toMap());
  }

  static Future<List<Conversation>> getAllConversations() async {
    final db = await database;
    final rows = await db.query('conversations', orderBy: 'created_at DESC');
    return rows.map(Conversation.fromMap).toList();
  }

  static Future<Conversation?> getConversation(String sessionId) async {
    final db = await database;
    final rows = await db.query('conversations', where: 'session_id = ?', whereArgs: [sessionId], limit: 1);
    if (rows.isEmpty) return null;
    return Conversation.fromMap(rows.first);
  }

  static Future<void> insertMessage(ConversationMessage msg) async {
    final db = await database;
    await db.insert('conversation_messages', msg.toMap());
  }

  static Future<List<ConversationMessage>> getMessages(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'conversation_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(ConversationMessage.fromMap).toList();
  }

  /// 批量删除消息
  static Future<void> deleteMessages(List<int> ids) async {
    final db = await database;
    final placeholders = ids.map((_) => '?').join(',');
    await db.delete('conversation_messages', where: 'id IN ($placeholders)', whereArgs: ids);
  }

  /// 删除整个对话及其消息
  static Future<void> deleteConversation(String sessionId) async {
    final db = await database;
    await db.delete('conversation_messages', where: 'session_id = ?', whereArgs: [sessionId]);
    await db.delete('conversations', where: 'session_id = ?', whereArgs: [sessionId]);
  }

  // ════════════════════════════════════════════════════
  //  角色 CRUD
  // ════════════════════════════════════════════════════

  static Future<List<ChatRole>> getAllRoles() async {
    final db = await database;
    final rows = await db.query('chat_roles', orderBy: 'id ASC');
    return rows.map(ChatRole.fromMap).toList();
  }

  static Future<int> insertRole(ChatRole role) async {
    final db = await database;
    return db.insert('chat_roles', role.toMap());
  }

  static Future<int> updateRole(ChatRole role) async {
    final db = await database;
    return db.update('chat_roles', role.toMap(), where: 'id = ?', whereArgs: [role.id]);
  }

  static Future<void> deleteRole(int id) async {
    final db = await database;
    // 同时将该角色的消息置为无角色
    await db.update('conversation_messages', {'role_id': null}, where: 'role_id = ?', whereArgs: [id]);
    await db.delete('chat_roles', where: 'id = ?', whereArgs: [id]);
  }

  static Future<ChatRole?> getRole(int id) async {
    final db = await database;
    final rows = await db.query('chat_roles', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return ChatRole.fromMap(rows.first);
  }

  static Future<void> initDefaultRoles() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM chat_roles'),
    );
    if (count == null || count == 0) {
      await db.insert('chat_roles', {'name': 'Host', 'avatar': '🧑', 'is_default': 1});
      await db.insert('chat_roles', {'name': 'Tulpa', 'avatar': '🫧', 'is_default': 1});
    }
  }

  // ════════════════════════════════════════════════════
  //  事实 CRUD
  // ════════════════════════════════════════════════════

  static Future<int> insertFact(Fact fact) async {
    final db = await database;
    return db.insert('facts', fact.toMap());
  }

  static Future<List<Fact>> getAllFacts() async {
    final db = await database;
    final rows = await db.query('facts', orderBy: 'created_at DESC');
    return rows.map(Fact.fromMap).toList();
  }

  // ════════════════════════════════════════════════════
  //  每日主题缓存
  // ════════════════════════════════════════════════════

  static Future<void> saveDailyTopics(String dateKey, String topicsJson) async {
    final db = await database;
    await db.insert('daily_topics', {
      'date_key': dateKey,
      'topics_json': topicsJson,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String?> getDailyTopics(String dateKey) async {
    final db = await database;
    final rows = await db.query('daily_topics', where: 'date_key = ?', whereArgs: [dateKey], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['topics_json'] as String?;
  }

  // ════════════════════════════════════════════════════
  //  工具
  // ════════════════════════════════════════════════════

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  static Future<void> clearAll() async {
    final db = await database;
    await db.delete('material_pool');
    await db.delete('topic_suggestions');
    await db.delete('conversations');
    await db.delete('conversation_messages');
    await db.delete('chat_roles');
    await db.delete('facts');
    await db.delete('daily_topics');
    await db.delete('role_profiles');
  }

  // ════════════════════════════════════════════════════
  //  角色档案 CRUD
  // ════════════════════════════════════════════════════

  static Future<List<RoleProfile>> getAllProfiles() async {
    final db = await database;
    final rows = await db.query('role_profiles', orderBy: 'updated_at DESC');
    return rows.map(RoleProfile.fromMap).toList();
  }

  static Future<RoleProfile?> getProfileByRoleId(int roleId) async {
    final db = await database;
    final rows = await db.query('role_profiles', where: 'role_id = ?', whereArgs: [roleId], limit: 1);
    if (rows.isEmpty) return null;
    return RoleProfile.fromMap(rows.first);
  }

  static Future<int> upsertProfile(RoleProfile profile) async {
    final db = await database;
    final existing = await db.query('role_profiles', where: 'role_id = ?', whereArgs: [profile.roleId], limit: 1);
    if (existing.isNotEmpty) {
      await db.update('role_profiles', profile.toMap(), where: 'role_id = ?', whereArgs: [profile.roleId]);
      return existing.first['id'] as int;
    }
    return db.insert('role_profiles', profile.toMap());
  }

  static Future<void> deleteProfile(int id) async {
    final db = await database;
    await db.delete('role_profiles', where: 'id = ?', whereArgs: [id]);
  }
}
