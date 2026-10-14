import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// 配置层的平台感知路由（S1c）。
///
/// 关键点：`routing` 与旧的 `capabilities{cap→providerId}` **并存**（D13:A 不迁移），
/// 解析候选时 `routing` 优先；旧的单值映射按**运行期同一条规则**回落
/// （P-59：该条目 `platformsFor(capability)` 真的包含查询平台才回落，
/// 而不是看配置里声明的 `contentPlatform`）；`defaultProvider` **不参与路由**（D14）。
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
      // ⚠️ 夹具修正（P-59 统一判据带来）：以前用"旧版内置条目 + `contentPlatform: qq`"
      // 代表"一个 qq 条目"——但内置实现运行时**只服务网易云**，声明 qq 只是配置里的
      // 一厢情愿。P-59 把"旧单值是否生效"统一到运行期规则后，这种自相矛盾的夹具
      // 不再能代表 qq 条目 ⇒ 换成**声明式** qq 条目（断言本身不变）。
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          _declarativeQqProvider('qqA'),
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

    test('★ P-59 内置条目被改了 contentPlatform，显式选择**不再被静默丢弃**', () {
      // 运行期：内置实现（chksz）**只服务网易云**，与 contentPlatform 无关。
      // 以前旧单值的回落判据却看 contentPlatform ⇒ 一旦它被改成 qq，这条显式选择
      // 就被判为"来源不匹配"而**静默丢弃**：界面从「已指定」变回「自动」，
      // 而功能看起来还是好的（条目实际仍在服务网易云）。
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz', 'contentPlatform': 'qq'},
        ],
        'capabilities': {'search': 'chksz'},
      });

      expect(
        settings.explicitCandidateIdsFor(MusicPlatform.netease, search),
        ['chksz'],
        reason: 'P-59：判据与运行期一致 ⇒ 显式选择必须还在',
      );
      expect(
        settings.selectedProviderIdFor(MusicPlatform.netease, search),
        'chksz',
      );
      // 跨平台仍然不回落（运行期也不服务 qq）。
      expect(
        settings.explicitCandidateIdsFor(MusicPlatform.qq, search),
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
          // 声明式 qq 条目：它**真的**服务 qq（见上一条的夹具说明）。
          _declarativeQqProvider('qqA'),
        ],
        'capabilities': {'search': 'qqA'},
      });

      // 旧值指 qq：在 netease 这一格上本来就不生效（运行期也不服务 netease）⇒ 清它不该动。
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

    test('★ P-14 旧旋钮**可见**：旧能力分配与旧默认提供商都会被如实说出来', () {
      final legacy = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
          {'id': 'neB', 'contentPlatform': 'netease'},
        ],
        'capabilities': {'search': 'neA'},
        'defaultProvider': 'neB',
      });

      final issues = legacy.legacyKnobIssues().join('\n');
      expect(issues, contains('能力分配'));
      expect(issues, contains('search→neA'));
      // 必须给出**清除路径**（否则"可见"没有出口）。
      expect(issues, contains('自动'));
      expect(issues, contains('默认提供商'));
      expect(issues, contains('neB'));
    });

    test('★ P-14 默认配置**不**产生旧旋钮提示（不误报）', () {
      expect(OnlineMusicSettings.defaults.legacyKnobIssues(), isEmpty);
    });

    test('★ P-14 + P-22 点「自动」清掉那一格之后，旧旋钮提示随之消失', () {
      final legacy = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'neA', 'contentPlatform': 'netease'},
        ],
        'capabilities': {'search': 'neA'},
      });
      expect(legacy.legacyKnobIssues(), isNotEmpty);

      final cleared = legacy.withRoutingCandidates(
        MusicPlatform.netease,
        search,
        const [],
      );

      expect(
        cleared.legacyKnobIssues(),
        isEmpty,
        reason: '可见 + 可清：清掉之后提示也要跟着消失',
      );
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
  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended playlists are not implemented here');

  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

  _FakeProvider(this.providerId, this._platforms);

  @override
  final String providerId;

  final Map<OnlineMusicCapability, Set<MusicPlatform>> _platforms;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _platforms[capability] ?? const {};
}

/// 一个**声明式**的 qq 条目（它真的服务 qq）。
///
/// ⚠️ 不能再用"旧版内置条目 + `contentPlatform: qq`"当夹具：内置实现运行时**只服务
/// 网易云**，声明 qq 只是配置里的一厢情愿 —— P-59 统一判据后，那种自相矛盾的夹具
/// 不再代表"一个 qq 条目"。
Map<String, Object?> _declarativeQqProvider(String id) => {
  'id': id,
  'contentPlatform': 'qq',
  'baseUrl': 'https://qq.invalid',
  'auth': {'kind': 'none'},
  'capabilities': {
    'search': OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/search'),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('data')!,
      ),
    ).toJson(),
  },
};
