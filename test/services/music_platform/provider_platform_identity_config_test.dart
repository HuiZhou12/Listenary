import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// F5（P-39 / 用户 P0 裁定）：**配置层的平台身份**（`contentPlatform` + `platformId`）。
///
/// 对应 P0 的必需测试：⑧旧配置仍可读且新字段不破坏已有数据；⑨改展示名 / Base URL 不改身份；
/// ⑩身份缺失 / 非法 ⇒ **明确错误**、不静默覆盖其他平台；以及规则④"认不出的值不回落网易云"。
void main() {
  OnlineMusicProviderDefinition definitionOf(Map<String, Object?> provider) =>
      OnlineMusicSettings.fromJson({
        'providers': [provider],
      }).providers.single;

  test('★ P-39 内置平台条目：身份 = 内置、稳定 ID 为空、无 issue', () {
    final definition = definitionOf({
      'id': 'builtinNetease',
      'displayName': '网易云自建',
      'contentPlatform': 'netease',
      'baseUrl': 'http://127.0.0.1:3000',
    });

    expect(
      definition.identity,
      const PlatformIdentity.builtin(MusicPlatform.netease),
    );
    expect(definition.identity.platformId, isNull);
    expect(definition.identity.isValid, isTrue);
    expect(definition.platformConfigIssue, isNull);
  });

  test('★ P-39 自定义平台：`custom` + 稳定 ID ⇒ 身份有效（规则②）', () {
    const id = '0f9a1c2e-6666-4666-8666-ffffffffffff';
    final definition = definitionOf({
      'id': 'customAlpha',
      'displayName': '自建甲',
      'contentPlatform': 'custom',
      'platformId': id,
      'baseUrl': 'http://127.0.0.1:3100',
    });

    expect(definition.contentPlatform, MusicPlatform.custom);
    expect(definition.identity.platformId, id);
    expect(definition.identity.isValid, isTrue);
    expect(definition.platformConfigIssue, isNull, reason: '给了稳定 ID ⇒ 配置无问题');
    expect(
      PlatformIdentity.tryParse(definition.identity.storageValue),
      definition.identity,
      reason: '身份必须能通过持久化值原样读回（读写成对）',
    );
  });

  test('★ P-39 规则⑩：写 `custom` 但没有稳定 ID ⇒ **明确报错**（fail-closed）', () {
    final definition = definitionOf({
      'id': 'customNoId',
      'displayName': '自建无 ID',
      'contentPlatform': 'custom',
      'baseUrl': 'http://127.0.0.1:3101',
    });

    expect(definition.identity.isValid, isFalse, reason: '没有稳定 ID ⇒ 身份无效');
    expect(
      definition.platformConfigIssue,
      allOf(contains('platformId'), contains('不会被路由')),
      reason: '必须明确报错，而不是静默当成内置平台',
    );
  });

  test('★ P-39 规则④：认不出的内容来源 ⇒ `custom` + **原样保留**，且不回落网易云', () {
    const raw = 'MySelfHosted';
    final definition = definitionOf({
      'id': 'selfData',
      'displayName': '自建',
      'contentPlatform': raw,
      'baseUrl': 'http://127.0.0.1:3102',
    });

    expect(
      definition.contentPlatform,
      MusicPlatform.custom,
      reason: '认不出的值绝不回落网易云',
    );
    expect(definition.identity.platformId, raw, reason: '原样保留原始标识（不归一、不推断）');
    expect(definition.platformConfigIssue, contains('不会回落网易云'));
  });

  test('★ P-39 规则④兼容：显式 `platformId` 优先于认不出的 `contentPlatform`', () {
    const declared = 'explicit-stable-id';
    final definition = definitionOf({
      'id': 'selfDataDeclared',
      'displayName': '自建（显式 ID）',
      'contentPlatform': 'SomeLegacyName',
      'platformId': declared,
      'baseUrl': 'http://127.0.0.1:3103',
    });

    expect(definition.contentPlatform, MusicPlatform.custom);
    expect(definition.identity.platformId, declared);
    expect(definition.identity.isValid, isTrue);
  });

  test('★ P-39 规则⑧：旧配置（无新字段）仍可读，且新字段不写回时不出现在 JSON', () {
    // 极简旧配置：只有 id / contentPlatform / baseUrl。
    final legacy = definitionOf({
      'id': 'legacy',
      'contentPlatform': 'netease',
      'baseUrl': 'http://127.0.0.1:3000',
    });
    expect(legacy.identity, const PlatformIdentity.builtin(MusicPlatform.netease));
    expect(legacy.platformId, isNull);
    expect(legacy.platformName, isNull);

    // 缺省字段不写回 ⇒ 不会凭空改变旧配置的形态。
    final json = legacy.toJson();
    expect(json.containsKey('platformId'), isFalse);
    expect(json.containsKey('platformName'), isFalse);
  });

  test('★ P-39 规则⑨：改展示名 / Base URL 不改身份；同名不同 ID 也不是同一平台', () {
    const id = '0f9a1c2e-7777-4777-8777-999999999999';
    final renamed = definitionOf({
      'id': 'customRename',
      'displayName': '新名字',
      'contentPlatform': 'custom',
      'platformId': id,
      'baseUrl': 'http://127.0.0.1:3999',
    });
    final original = definitionOf({
      'id': 'customRename',
      'displayName': '旧名字',
      'contentPlatform': 'custom',
      'platformId': id,
      'baseUrl': 'http://127.0.0.1:3200',
    });

    expect(renamed.identity, original.identity, reason: '展示名 / Base URL 不是身份');
    // ⚠️ 注意字段分工：`displayName` 是**条目**显示名；`platformName` 是**平台**显示名
    //（F4-S5 引入）。自定义平台没给 `platformName` 时，平台展示名回落到兜底文案（不参与身份判定）。
    expect(renamed.displayPlatformName, '自定义平台');
    final withPlatformName = definitionOf({
      'id': 'customNamed',
      'displayName': '条目名',
      'platformName': '我的自建平台',
      'contentPlatform': 'custom',
      'platformId': id,
      'baseUrl': 'http://127.0.0.1:3200',
    });
    expect(withPlatformName.displayPlatformName, '我的自建平台');
    expect(
      withPlatformName.identity,
      original.identity,
      reason: '平台展示名同样不参与身份',
    );

    final sameNameOtherId = definitionOf({
      'id': 'customOther',
      'displayName': '新名字',
      'contentPlatform': 'custom',
      'platformId': '0f9a1c2e-8888-4888-8888-aaaaaaaaaaaa',
      'baseUrl': 'http://127.0.0.1:3999',
    });
    expect(
      sameNameOtherId.identity == original.identity,
      isFalse,
      reason: '同名 + 同 URL 但 ID 不同 ⇒ **不是**同一个平台（不得静默并入）',
    );
  });
}
