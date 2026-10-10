import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// F5-P-39（P3）：`platformLabelForIdentity`（界面收口的单一事实源）。
void main() {
  OnlineMusicSettings settingsOf(List<Map<String, Object?>> providers) =>
      OnlineMusicSettings.fromJson({'providers': providers});

  test('★ P3 自定义平台：用配置里同身份条目的 platformName', () {
    const id = '0f9a1c2e-eeee-4eee-8eee-eeeeeeeeeeee';
    final settings = settingsOf([
      {
        'id': 'custom',
        'contentPlatform': 'custom',
        'platformId': id,
        'platformName': '我的自建平台',
        'baseUrl': 'http://127.0.0.1:3100',
      },
    ]);

    expect(
      platformLabelForIdentity(settings, const PlatformIdentity.custom(id)),
      '我的自建平台',
    );
  });

  test('★ P3 未登记的 custom 身份 / 无效身份 ⇒ 兜底文案，绝不回落网易云', () {
    final settings = settingsOf([
      {
        'id': 'custom',
        'contentPlatform': 'custom',
        'platformId': 'id-registered',
        'platformName': '已登记',
        'baseUrl': 'http://127.0.0.1:3100',
      },
    ]);

    expect(
      platformLabelForIdentity(settings, const PlatformIdentity.custom('id-unknown')),
      '自定义平台',
    );
    final invalid = platformLabelForIdentity(
      settings,
      const PlatformIdentity.custom(''),
    );
    expect(invalid, '未知平台');
    expect(invalid, isNot('网易云'));
  });

  test('★ P3 内置平台：沿用既有文案（行为不变）', () {
    final settings = settingsOf([
      {
        'id': 'builtin',
        'contentPlatform': 'netease',
        'baseUrl': 'http://127.0.0.1:3000',
      },
    ]);

    expect(
      platformLabelForIdentity(
        settings,
        const PlatformIdentity.builtin(MusicPlatform.netease),
      ),
      '网易云',
    );
  });

  test('★ P3 改展示名不影响身份解析（同名不同 ID 不会互相顶替）', () {
    const idA = '0f9a1c2e-1111-4111-8111-111111111111';
    const idB = '0f9a1c2e-2222-4222-8222-222222222222';
    final settings = settingsOf([
      {
        'id': 'a',
        'contentPlatform': 'custom',
        'platformId': idA,
        'platformName': '同名',
        'baseUrl': 'http://127.0.0.1:3100',
      },
      {
        'id': 'b',
        'contentPlatform': 'custom',
        'platformId': idB,
        'platformName': '同名',
        'baseUrl': 'http://127.0.0.1:3200',
      },
    ]);

    expect(platformLabelForIdentity(settings, const PlatformIdentity.custom(idA)), '同名');
    expect(platformLabelForIdentity(settings, const PlatformIdentity.custom(idB)), '同名');
    // 身份仍然不同（展示名相同不改变身份）。
    expect(const PlatformIdentity.custom(idA) == const PlatformIdentity.custom(idB), isFalse);
  });
}