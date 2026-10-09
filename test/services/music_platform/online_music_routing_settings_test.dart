import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// 配置层的平台感知路由（S1c）。
///
/// 关键点：`routing` 与旧的 `capabilities{cap→providerId}` **并存**（D13:A 不迁移），
/// 解析候选时 `routing` 优先、旧的单值映射仅在"该 Provider 的 contentPlatform 正好
/// 等于查询平台"时回落；`defaultProvider` **不参与路由**（D14）。
void main() {
  const search = OnlineMusicCapability.search;

  OnlineMusicSettings twoPlatforms() => OnlineMusicSettings.fromJson({
    'providers': [
      {'id': 'neA', 'contentPlatform': 'netease'},
      {'id': 'neB', 'contentPlatform': 'netease'},
      {'id': 'qqA', 'contentPlatform': 'qq'},
    ],
  });

  group('routing 解析', () {
    test('按平台 + 能力读出显式候选，非法项逐项丢弃', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          {'id': 'qqA', 'contentPlatform': 'qq'},
        ],
        'routing': {
          'netease': {
            'search': ['neA'],
            'bogusCapability': ['neA'],
          },
          'qq': {
            'search': ['qqA', 'missing', 'qqA'],
          },
          'kugou': 'not-a-map',
          'bogusPlatform': {
            'search': ['neA'],
          },
        },
      });

      expect(settings.explicitCandidateIdsFor(MusicPlatform.netease, search), [
        'neA',
      ]);
      // 未注册 id 与重复项被丢弃，不影响剩下的合法项。
      expect(settings.explicitCandidateIdsFor(MusicPlatform.qq, search), [
        'qqA',
      ]);
      // 平台名非法 / 值不是 map → 整项忽略。
      expect(
        settings.explicitCandidateIdsFor(MusicPlatform.kugou, search),
        isEmpty,
      );
    });

    test('round-trip：routing 非空才写回，空时不产生该键', () {
      final settings = twoPlatforms();
      expect(settings.toJson().containsKey('routing'), isFalse);

      final routed = settings.withRoutingCandidates(MusicPlatform.qq, search, [
        'qqA',
      ]);
      final json = routed.toJson();
      expect(json['routing'], {
        'qq': {
          'search': ['qqA'],
        },
      });
      expect(OnlineMusicSettings.fromJson(json), routed);
    });

    test('显式候选中未注册的 id 不会被写进配置', () {
      final routed = twoPlatforms().withRoutingCandidates(
        MusicPlatform.qq,
        search,
        ['missing', 'qqA'],
      );
      expect(routed.explicitCandidateIdsFor(MusicPlatform.qq, search), ['qqA']);
    });
  });

  group('routing 与旧单值映射并存', () {
    test('旧 capabilities 只在同一平台内回落', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          {'id': 'qqA', 'contentPlatform': 'qq'},
        ],
        'capabilities': {'search': 'qqA'},
      });

      expect(settings.explicitCandidateIdsFor(MusicPlatform.qq, search), [
        'qqA',
      ]);
      // 旧单值是平台无关的，但**不允许跨平台**回落。
      expect(
        settings.explicitCandidateIdsFor(MusicPlatform.netease, search),
        isEmpty,
      );
    });

    test('★ P-22 点「自动」（清空）真的清掉**这一格**的旧单值', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          {'id': 'neB', 'contentPlatform': 'netease'},
        ],
        'capabilities': {'search': 'neA', 'lyric': 'neA'},
      });
      expect(settings.explicitCandidateIdsFor(MusicPlatform.netease, search), [
        'neA',
      ]);
      expect(
        settings.selectedProviderIdFor(MusicPlatform.netease, search),
        'neA',
      );

      final cleared = settings.withRoutingCandidates(
        MusicPlatform.netease,
        search,
        const [],
      );

      // 起点症状（P-22）：以前只清 `routing`，回落立刻把「已指定 neA」又拉回来。
      expect(
        cleared.explicitCandidateIdsFor(MusicPlatform.netease, search),
        isEmpty,
      );
      expect(
        cleared.selectedProviderIdFor(MusicPlatform.netease, search),
        isNull,
        reason: '界面必须真的回到「自动」',
      );
      // 只清**点过的那一格**：别的能力上的旧值原样保留（D13:A）。
      expect(
        cleared.explicitCandidateIdsFor(
          MusicPlatform.netease,
          OnlineMusicCapability.lyric,
        ),
        ['neA'],
      );
      expect(cleared.toJson().toString(), contains('lyric'));
    });

    test('★ P-22 点「自动」不会碰**别的平台**上的旧值', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          {'id': 'qqA', 'contentPlatform': 'qq'},
        ],
        'capabilities': {'search': 'qqA'},
      });

      // 旧值指 qq：在 netease 这一格上本来就不生效（不跨平台回落）⇒ 清 netease 不该动它。
      final cleared = settings.withRoutingCandidates(
        MusicPlatform.netease,
        search,
        const [],
      );

      expect(
        cleared.capabilityProviders[search],
        'qqA',
        reason: '别的平台上的旧值不该被牵连',
      );
      expect(cleared.explicitCandidateIdsFor(MusicPlatform.qq, search), [
        'qqA',
      ]);
    });

    test('routing 优先于旧 capabilities', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          {'id': 'neB', 'contentPlatform': 'netease'},
        ],
        'capabilities': {'search': 'neA'},
        'routing': {
          'netease': {
            'search': ['neB'],
          },
        },
      });

      expect(settings.explicitCandidateIdsFor(MusicPlatform.netease, search), [
        'neB',
      ]);
    });

    test('删除条目会同时清掉旧单值映射与平台候选里的它', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          {'id': 'neB', 'contentPlatform': 'netease'},
        ],
        'capabilities': {'search': 'neA'},
        'routing': {
          'netease': {
            'search': ['neA', 'neB'],
          },
        },
      });

      final removed = settings.withoutProvider('neA');
      expect(removed.capabilityProviders.containsKey(search), isFalse);
      expect(removed.explicitCandidateIdsFor(MusicPlatform.netease, search), [
        'neB',
      ]);
    });
  });

  group('defaultProvider 不参与路由（D14）', () {
    test('平台没有候选时返回空，不回落默认 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          _FakeProvider('neA', {
            search: {MusicPlatform.netease},
          }),
        ],
        defaultProviderId: 'neA',
        explicitCandidates: (platform, capability) => const [],
      );

      expect(
        registry.providersFor(MusicPlatform.netease, search),
        hasLength(1),
      );
      expect(registry.providersFor(MusicPlatform.qq, search), isEmpty);
    });

    test('配置层的平台候选被注册表采纳，且只使用这些候选（D17:b）', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          _FakeProvider('neA', {
            search: {MusicPlatform.netease},
          }),
          _FakeProvider('neB', {
            search: {MusicPlatform.netease},
          }),
        ],
        explicitCandidates: (platform, capability) =>
            platform == MusicPlatform.netease && capability == search
            ? const ['neB']
            : const [],
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, search)
            .map((provider) => provider.providerId),
        ['neB'],
      );
    });
  });
}

final class _FakeProvider extends UnsupportedOnlineMusicProvider {
  _FakeProvider(this.providerId, this._platforms);

  @override
  final String providerId;

  final Map<OnlineMusicCapability, Set<MusicPlatform>> _platforms;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _platforms[capability] ?? const {};
}
