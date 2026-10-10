import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// F4-S5（P-39 / D5:A）：**稳定唯一 ID + 展示名分离**，且**未知平台绝不静默回落 netease**。
///
/// I1 仍是 `(platform, remoteId)`：`platformId` / `platformName` **不参与内容身份**，
/// 只让自建/代理服务有稳定的平台标识与自己的展示名。
void main() {
  group('★ F4-S5 平台标识与展示名（P-39）', () {
    OnlineMusicProviderDefinition parse(Map<String, Object?> provider) =>
        OnlineMusicSettings.fromJson({
          'providers': [provider],
        }).providers.single;

    test('platformId / platformName 写盘并往返不变；缺省时不写这两个键', () {
      final declared = parse({
        'id': 'selfData',
        'baseUrl': 'https://self.invalid',
        'auth': {'kind': 'none'},
        'contentPlatform': 'netease',
        'platformId': 'self-netease-proxy',
        'platformName': '自建网易云代理',
        'capabilities': <String, Object?>{},
      });

      expect(declared.platformId, 'self-netease-proxy');
      expect(declared.platformName, '自建网易云代理');
      expect(declared.displayPlatformName, '自建网易云代理');
      expect(declared.platformConfigIssue, isNull);

      final json = declared.toJson();
      expect(json['platformId'], 'self-netease-proxy');
      expect(json['platformName'], '自建网易云代理');
      expect(
        parse(json).platformId,
        'self-netease-proxy',
        reason: '往返不丢',
      );

      // 缺省 ⇒ 不写键，且展示名回落到内置中文名。
      final bare = parse({
        'id': 'selfData',
        'baseUrl': 'https://self.invalid',
        'auth': {'kind': 'none'},
        'contentPlatform': 'qq',
        'capabilities': <String, Object?>{},
      });
      expect(bare.platformId, isNull);
      expect(bare.platformName, isNull);
      expect(bare.toJson().containsKey('platformId'), isFalse);
      expect(bare.toJson().containsKey('platformName'), isFalse);
      expect(bare.displayPlatformName, musicPlatformLabel(MusicPlatform.qq));
    });

    test('★ 未知 contentPlatform ⇒ **不再静默回落 netease**（保留原值 + 明确问题）', () {
      final definition = parse({
        'id': 'selfData',
        'baseUrl': 'https://self.invalid',
        'auth': {'kind': 'none'},
        'contentPlatform': 'mySelfHosted',
        'capabilities': <String, Object?>{},
      });

      expect(
        definition.platformId,
        'mySelfHosted',
        reason: '原始标识必须被保留（以前会被静默丢掉、当成 netease）',
      );
      expect(
        definition.platformConfigIssue,
        allOf(contains('不是内置平台'), contains('mySelfHosted')),
        reason: '必须**明确报出**，而不是悄悄当成网易云',
      );
      expect(
        definition.toJson().containsKey('platformConfigIssue'),
        isFalse,
        reason: '解析期问题不落盘（与 capabilityConfigIssues 同一口径）',
      );
    });

    test('显式 platformId 优先于"未知 contentPlatform"的原始串', () {
      final definition = parse({
        'id': 'selfData',
        'baseUrl': 'https://self.invalid',
        'auth': {'kind': 'none'},
        'contentPlatform': 'mySelfHosted',
        'platformId': 'stable-id-1',
        'platformName': '我的自建服务',
        'capabilities': <String, Object?>{},
      });

      expect(definition.platformId, 'stable-id-1');
      expect(definition.displayPlatformName, '我的自建服务');
      expect(definition.platformConfigIssue, isNotNull, reason: '平台依旧无法确定 ⇒ 仍要报出');
    });

    test('旧配置（内置平台）逐字节不变，且不产生任何问题', () {
      final json = <String, Object?>{
        'id': 'chksz',
        'protocol': 'chksz',
        'baseUrl': 'https://api.example',
        'contentPlatform': 'netease',
      };

      final definition = parse(json);

      expect(definition.platformConfigIssue, isNull);
      expect(
        definition.toJson()['contentPlatform'],
        'netease',
        reason: '内置平台的值与以前完全一致',
      );
    });

    test('★ 三条"重建定义"的路径都必须透传 platformId / platformName', () {
      final base = parse({
        'id': 'selfData',
        'baseUrl': 'https://self.invalid',
        'auth': {'kind': 'none'},
        'contentPlatform': 'netease',
        'platformId': 'pid-1',
        'platformName': '展示名 1',
        'capabilities': <String, Object?>{},
      });

      expect(
        base
            .editedBy(
              baseUrl: 'https://other.invalid',
              requiresCredential: false,
            )
            .platformId,
        'pid-1',
        reason: '设置页保存走 editedBy ⇒ 不得丢平台标识',
      );
      expect(
        base
            .withCapabilityBinding(
              OnlineMusicCapability.search,
              const OnlineMusicUnsupportedCapabilityBinding(),
            )
            .platformName,
        '展示名 1',
      );
      expect(
        base.withChkszCompatibleCapabilities().platformId,
        'pid-1',
      );
    });
  });
}
