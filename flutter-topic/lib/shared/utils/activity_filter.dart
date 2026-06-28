/// ── 活动数据噪声过滤器 ──────────────────────────────────
/// 改编自 probe 项目的 ActivityFilter，用于在素材采集阶段过滤无用噪声。
///
/// 策略：
///   - 规范化标题（去控制字符、前导表情/符号）
///   - 低价值标题检测（播放、暂停、缓冲中 等瞬态 UI 文本）
///   - 低信息量检测（纯数字、单字符、重复字符）
///   - 系统状态窗口检测（息屏、锁屏）
class ActivityFilter {
  // ── 前导表情/图形符号（大量出现在哔哩哔哩等 App 的标题前） ──────
  static const Set<int> _leadingVisualNoise = <int>{
    0x231B, 0x23F3, 0x25CC, 0x25D0, 0x25D1, 0x25D2, 0x25D3,
    0x25E6, 0x25EF, 0x2605, 0x2606, 0x2611, 0x2612, 0x2615,
    0x263A, 0x263B, 0x26A0, 0x26AA, 0x26AB, 0x2705, 0x2713,
    0x2714, 0x2726, 0x2728, 0x2733, 0x2734, 0x2747, 0x274C,
    0x2753, 0x2754, 0xFFFD,
  };

  // ── 低价值标题（在素材池中无意义，应被过滤） ──────────────────
  static const Set<String> _lowValueTitles = <String>{
    // 中英文播放控制
    'play', 'pause', 'paused', 'playing', 'speed', 'loading', 'buffering',
    '播放', '暂停', '倍速中', '加载中',
    '正在加载', '缓冲中', '重播', '点击重试',
    '播放/暂停', '拖动到此处锁定倍速',
    '发送中...', '一键已读',
    // 系统桌面/状态
    '系统桌面', '桌面',
    'program manager', '任务栏 / 文件资源管理器',
    '系统托盘溢出窗口。', '快速设置',
    '音量控制', '新通知',
    'windows 默认锁屏界面',
    // Tulpa 自身
    'TulpaTopic',
  };

  // ── 系统状态窗口（不写入素材池但可显示状态） ────────────────
  static const Set<String> _systemStateTitles = <String>{
    '系统息屏',
    '系统锁屏',
  };

  // ── 简短但有意义的标题（不受低信息量规则限制） ──────────────
  static const Set<String> _shortMeaningful = <String>{
    'qq',
    'tim',
    'yy',
  };

  // ── 公共接口 ──────────────────────────────────────────

  /// 规范化窗口标题
  /// 去除控制字符、零宽字符、前导表情/符号、浏览器后缀
  static String normalize(String value) {
    var title = (value ?? '')
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    title = _stripLeadingVisualNoise(title);

    // 浏览器窗口标题后缀标准化
    title = title
        .replaceAll(
          RegExp(r'\s+' + '和另外' + r'\s*\d+\s*个页面\s*-\s*个人\s*-\s*Microsoft(?:®|™)?\s*Edge$',
              caseSensitive: false),
          ' [Edge]',
        )
        .replaceAll(
          RegExp(r'\s+-\s*个人\s*-\s*Microsoft(?:®|™)?\s*Edge$',
              caseSensitive: false),
          ' [Edge]',
        )
        .replaceAll(
          RegExp(r'\s+-\s*Microsoft(?:®|™)?\s*Edge$', caseSensitive: false),
          ' [Edge]',
        )
        .replaceAll(
          RegExp(r'\s+-\s*Google Chrome$', caseSensitive: false),
          ' [Chrome]',
        )
        .replaceAll(
          RegExp(r'\s+-\s*Mozilla Firefox$', caseSensitive: false),
          ' [Firefox]',
        )
        .trim();

    return _stripLeadingVisualNoise(title);
  }

  /// 判断是否为噪声标题（应被过滤，不存入素材池）
  static bool isNoise(String value) {
    final title = normalize(value);
    if (title.isEmpty) return true;

    final lower = title.toLowerCase();
    final compact = lower.replaceAll(RegExp(r'\s+'), '');

    // 精确匹配低价值列表
    if (_lowValueTitles.contains(lower) || _lowValueTitles.contains(compact)) {
      return true;
    }

    // 按「 - 」分段，检查最后一段
    final segments = lower.split(RegExp(r'\s+-\s+'));
    final lastSegment = segments.isEmpty ? lower : segments.last;
    final lastCompact = lastSegment.replaceAll(RegExp(r'\s+'), '');
    if (_lowValueTitles.contains(lastSegment) ||
        _lowValueTitles.contains(lastCompact)) {
      return true;
    }

    // 系统状态提示
    if (RegExp(r'^(?:system|系统)\s*[:：]', caseSensitive: false)
        .hasMatch(title)) {
      return true;
    }

    // .exe 进程名
    if (RegExp(r'[:：]\s*(?:msedge|chrome|firefox|explorer|applicationframehost)\.exe\b',
            caseSensitive: false)
        .hasMatch(title)) {
      return true;
    }
    if (RegExp(r'[:：]\s*[a-z0-9_.-]+\.exe\b', caseSensitive: false)
            .hasMatch(title) &&
        title.length <= 80) {
      return true;
    }

    // 倍速控制
    if (RegExp(r'^(\d+(\.\d+)?x|\d+(\.\d+)?倍|倍速)$').hasMatch(compact)) {
      return true;
    }
    if ((title.contains('倍速中') ||
            title.contains('正在加载') ||
            title.contains('加载中') ||
            title.contains('缓冲中')) &&
        title.length <= 20) {
      return true;
    }

    // 纯符号：使用双引号原始字符串避免单引号冲突
    if (RegExp(r"^[\s._\-|/\\:;'" + '`' + r"~!?()\[\]{}<>*+=#@\$%^&]+$")
        .hasMatch(title)) {
      return true;
    }

    // 低信息量
    if (_hasLowInformation(title)) return true;

    return false;
  }

  /// 判断是否为系统状态窗口（息屏/锁屏）
  static bool isSystemState(String value) {
    return _systemStateTitles.contains(normalize(value));
  }

  /// 判断标题是否应为素材池关注（非噪声 + 非系统状态）
  static bool isMeaningfulForMaterial(String value) {
    if (value.isEmpty) return false;
    final title = normalize(value);
    if (title.isEmpty) return false;
    return !isNoise(title) && !isSystemState(title);
  }

  /// 过滤并返回有意义的内容标题（null 表示应跳过）
  static String? sanitize(String value) {
    final title = normalize(value);
    if (title.isEmpty) return null;
    if (isNoise(title)) return null;
    if (isSystemState(title)) return null;
    return title;
  }

  // ── 内部方法 ──────────────────────────────────────────

  /// 去除前导视觉噪声（表情符号、特殊图形）
  static String _stripLeadingVisualNoise(String text) {
    var result = text.trimLeft();
    var changed = true;
    while (result.isNotEmpty && changed) {
      changed = false;
      final cp = result.runes.first;

      if (_leadingVisualNoise.contains(cp) ||
          (cp >= 0x2800 && cp <= 0x28FF) ||
          (cp >= 0x1F300 && cp <= 0x1FAFF)) {
        result = result.substring(String.fromCharCode(cp).length).trimLeft();
        changed = true;
      }
    }
    return result;
  }

  /// 低信息量检测：纯数字、单字符、重复字符
  static bool _hasLowInformation(String title) {
    final compact = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (_shortMeaningful.contains(compact)) return false;

    // 提取所有字母和汉字
    final chars = title.runes
        .map((cp) => String.fromCharCode(cp))
        .where((ch) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(ch))
        .toList();

    if (chars.isEmpty) return true;
    if (chars.length <= 1) return true;

    // 全部是同一个字符且长度 <= 4
    return chars.toSet().length <= 1 && chars.length <= 4;
  }
}
