import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// F5-P-39（P3）：平台**展示名**的统一出口 `platformDisplayLabel`（P0：不回落网易云、不靠名称反推）。
void main() {
  test('★ P3 内置平台：沿用既有中文名（行为不变）', () {
    expect(
      platformDisplayLabel(const PlatformIdentity.builtin(MusicPlatform.netease)),
      '网易云',
    );
    expect(
      platformDisplayLabel(const PlatformIdentity.builtin(MusicPlatform.qq)),
      'QQ音乐',
    );
  });

  test('★ P3 自定义平台：用条目声明的 platformName；缺失时回落「自定义平台」', () {
    const id = '0f9a1c2e-dddd-4ddd-8ddd-dddddddddddd';
    expect(
      platformDisplayLabel(const PlatformIdentity.custom(id), platformName: '我的自建'),
      '我的自建',
    );
    expect(
      platformDisplayLabel(const PlatformIdentity.custom(id)),
      '自定义平台',
    );
    expect(
      platformDisplayLabel(const PlatformIdentity.custom(id), platformName: '   '),
      '自定义平台',
      reason: '空白声明等同没有声明',
    );
    // 历史遗留的未知名：显示为自定义平台（**保留身份**，不猜、不回落网易云）。
    expect(
      platformDisplayLabel(const PlatformIdentity.custom('LegacyProxy')),
      '自定义平台',
    );
  });

  test('★ P3 身份无效：显示「未知平台」，**绝不回落网易云**', () {
    final label = platformDisplayLabel(const PlatformIdentity.custom(''));
    expect(label, '未知平台');
    expect(label, isNot('网易云'));
    expect(
      platformDisplayLabel(const PlatformIdentity.custom('   ')),
      '未知平台',
    );
  });

  test('★ P3 条目级 displayPlatformName 走同一出口（含自定义与缺省形态）', () {
    OnlineMusicProviderDefinition definitionOf(Map<String, Object?> provider) =>
        OnlineMusicSettings.fromJson({
          'providers': [provider],
        }).providers.single;

    expect(
      definitionOf({
        'id': 'builtin',
        'contentPlatform': 'netease',
        'baseUrl': 'http://127.0.0.1:3000',
      }).displayPlatformName,
      '网易云',
    );
    expect(
      definitionOf({
        'id': 'named',
        'contentPlatform': 'custom',
        'platformId': 'id-named',
        'platformName': '我的自建平台',
        'baseUrl': 'http://127.0.0.1:3100',
      }).displayPlatformName,
      '我的自建平台',
    );
    expect(
      definitionOf({
        'id': 'unnamed',
        'contentPlatform': 'custom',
        'platformId': 'id-unnamed',
        'baseUrl': 'http://127.0.0.1:3101',
      }).displayPlatformName,
      '自定义平台',
    );
  });
}