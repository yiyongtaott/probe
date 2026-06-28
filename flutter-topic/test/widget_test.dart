import 'package:flutter_test/flutter_test.dart';

import 'package:tulpa_topic/shared/models/models.dart';
import 'package:tulpa_topic/shared/engine/topic_engine.dart';

void main() {
  group('MaterialItem', () {
    test('dateKey formats correctly', () {
      final item = MaterialItem(
        title: '测试标题',
        sourceApp: 'QQ',
        timestamp: DateTime(2026, 6, 27, 10, 30).millisecondsSinceEpoch,
      );
      expect(item.dateKey, '2026-06-27');
    });

    test('toMap and fromMap roundtrip', () {
      final item = MaterialItem(
        id: 1,
        title: '赛博朋克音乐推荐',
        sourceApp: '哔哩哔哩',
        timestamp: 1234567890,
        topic: '音乐',
        weight: 3.5,
      );
      final map = item.toMap();
      final restored = MaterialItem.fromMap(map);
      expect(restored.title, item.title);
      expect(restored.sourceApp, item.sourceApp);
      expect(restored.timestamp, item.timestamp);
      expect(restored.topic, item.topic);
      expect(restored.weight, item.weight);
    });
  });

  group('TopicEngine.rankMaterials', () {
    test('ranks by weight and count', () {
      final materials = [
        MaterialItem(title: '宇宙', sourceApp: '知乎', timestamp: 1000, weight: 1),
        MaterialItem(title: '宇宙', sourceApp: '微博', timestamp: 2000, weight: 1),
        MaterialItem(title: '猫', sourceApp: 'B站', timestamp: 3000, weight: 1),
      ];
      final ranked = TopicEngine.rankMaterials(materials);
      expect(ranked.length, 2);
      expect(ranked.first.topic, '宇宙');
      expect(ranked.first.count, 2);
    });

    test('empty list returns empty', () {
      expect(TopicEngine.rankMaterials([]), isEmpty);
    });
  });

  group('AiConfig', () {
    test('isConfigured checks required fields', () {
      expect(AiConfig.defaultOllama().isConfigured, isFalse);
      expect(
        AiConfig(provider: 'ollama', baseUrl: 'http://localhost:11434', apiKey: '', model: 'qwen2.5:7b').isConfigured,
        isTrue,
      );
      expect(
        AiConfig(provider: 'openai', baseUrl: 'https://api.openai.com/v1', apiKey: 'sk-test', model: 'gpt-4o-mini').isConfigured,
        isTrue,
      );
      expect(
        AiConfig(provider: 'openai', baseUrl: '', apiKey: '', model: '').isConfigured,
        isFalse,
      );
    });
  });
}
