import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// S9：**默认配置的兼容回归**。
///
/// 用户确认的兼容口径是"**默认配置下对外可观察行为与现有版本保持兼容**"
/// （不是逐字节一致）。本文件在**配置与路由层**把这句话变成断言：
/// 默认条目仍是单个内置 chksz、四个能力仍是内置、落盘结构不新增键、
/// 单条目的路由结果与改造前完全一致。
void main() {
  const netease = MusicPlatform.netease;

  test('默认配置：单个内置 chksz 条目，只声明它真正实现的四个能力', () {
    const settings = OnlineMusicSettings.defaults;

    expect(settings.providers, hasLength(1));
    final definition = settings.providers.single;
    expect(definition.id, defaultOnlineMusicProviderId);
    expect(definition.contentPlatform, netease);
    // ⚠️ 语义变更（F1-c / P-19）：旧断言是"**全部 8 个**能力都是内置实现"
    //（而这条测试的名字却写着"四个能力"）—— 那正是缺陷本身：平台卡声称 8 个，
    // 运行时只服务 4 个（`chksz_online_music_provider.dart` 的 `_defaultPlatforms`），
    // 另外 4 项在界面上可选、调用时却是静默 `unavailable`。
    // 现在声明侧与运行时侧是同一个集合（[builtinOnlineMusicCapabilities]）。
    expect(
      builtinOnlineMusicCapabilities,
      const {
        OnlineMusicCapability.search,
        OnlineMusicCapability.playlist,
        OnlineMusicCapability.lyric,
        OnlineMusicCapability.stream,
      },
      reason: '内置实现真正实现的就是这四项（改这里必须同步运行时并让下面的断言解释原因）',
    );
    for (final capability in OnlineMusicCapability.values) {
      final supported = builtinOnlineMusicCapabilities.contains(capability);
      expect(
        definition.bindingFor(capability),
        supported
            ? isA<OnlineMusicBuiltinCapabilityBinding>()
            : isA<OnlineMusicUnsupportedCapabilityBinding>(),
        reason:
            '${capability.name} 在默认配置下'
            '${supported ? '必须是内置实现' : '必须明确是不支持（不得假装可用）'}',
      );
      expect(
        definition.platformsFor(capability),
        supported ? {netease} : isEmpty,
        reason: 'P-19：平台卡声称的能力必须与运行时一致',
      );
    }
  });

  test('★ P-19 跨层一致性：声明的能力集 == 运行时注册的能力集', () async {
    // 这条取代了以前"两个绿色测试各钉矛盾一方"的局面：
    // 一个断言"默认条目 8 个能力全内置"、另一个断言"运行时只有 4 个能力集"，
    // 两条都绿而没有任何地方比较二者。现在直接比较。
    const settings = OnlineMusicSettings.defaults;
    final definition = settings.providers.single;
    final composition = createOnlineMusicComposition(
      settings: settings,
      portableBuild: true,
    );
    addTearDown(composition.service.dispose);
    final runtime = composition.service.capabilities;

    // 运行时按能力暴露的平台集合（search 额外带**D3 硬门槛**：还要有播放解析）。
    final runtimeSets = <OnlineMusicCapability, Set<MusicPlatform>>{
      OnlineMusicCapability.search: runtime.searchablePlatforms,
      OnlineMusicCapability.playlist: runtime.playlistPlatforms,
      OnlineMusicCapability.playlistCollection:
          runtime.playlistCollectionPlatforms,
      OnlineMusicCapability.playlistCategories:
          runtime.playlistCategoryPlatforms,
      OnlineMusicCapability.chartList: runtime.chartPlatforms,
      OnlineMusicCapability.newSongs: runtime.newSongPlatforms,
      // artist（2026-10-12）：默认条目**不声明**它，运行时也**不注册**它 ⇒ 两侧都空 ✓。
      OnlineMusicCapability.artist: runtime.artistPlatforms,
      OnlineMusicCapability.album: runtime.albumPlatforms,
      OnlineMusicCapability.artistAlbums: runtime.artistAlbumPlatforms,
      OnlineMusicCapability.artistSongs: runtime.artistSongPlatforms,
      OnlineMusicCapability.newAlbums: runtime.newAlbumPlatforms,
      OnlineMusicCapability.searchAlbums: runtime.searchableAlbumPlatforms,
      OnlineMusicCapability.lyric: runtime.lyricPlatforms,
      OnlineMusicCapability.stream: runtime.resolvablePlatforms,
    };

    for (final capability in OnlineMusicCapability.values) {
      final declared = definition.platformsFor(capability);
      final registered = runtimeSets[capability]!;
      if (capability == OnlineMusicCapability.search) {
        // search 的运行时集合是**门槛后**的：允许它比声明侧更窄，
        // 但不允许出现"运行时能搜、界面却说不能"。
        expect(
          declared.containsAll(registered),
          isTrue,
          reason: '运行时能搜的平台必须是声明侧声称支持的平台',
        );
        expect(registered, declared, reason: '默认配置下这道门槛不会真的削掉平台');
        continue;
      }
      expect(
        registered,
        declared,
        reason:
            '${capability.name}：平台卡声称 $declared，运行时注册 $registered'
            '（P-19 就是这个不一致：界面说能、运行说不能）',
      );
    }
  });

  test('默认配置落盘结构不新增键（D13:A：不迁移、不改写用户文件）', () {
    final json = OnlineMusicSettings.defaults.toJson();

    expect(json.containsKey('routing'), isFalse, reason: '空 routing 不写盘');
    expect(
      json.containsKey('capabilities'),
      isTrue,
      reason: '旧的 capabilities 键仍然照写，旧版本可继续读',
    );
    expect(json['defaultProvider'], defaultOnlineMusicProviderId);
  });

  test('旧配置读取后不产生显式候选，路由完全由"单条目"推导', () {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {'id': 'chksz', 'protocol': 'chksz'},
      ],
    });

    for (final capability in OnlineMusicCapability.values) {
      expect(
        settings.explicitCandidateIdsFor(netease, capability),
        isEmpty,
        reason: '${capability.name} 没有显式候选 → 由注册顺序推导',
      );
    }
  });

  test('单条目路由结果与改造前一致：四能力都命中同一个 Provider', () {
    // 用"声明支持四能力的单条目"代表内置 chksz 条目（这里不需要真实运行时）。
    final chkszLike = _AllCapabilityProvider('chksz', netease);
    final registry = OnlineMusicProviderRegistry(
      providers: [chkszLike],
      explicitCandidates: OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz'},
        ],
      }).explicitCandidateIdsFor,
    );

    for (final capability in OnlineMusicCapability.values) {
      expect(
        registry.providersFor(netease, capability).map((p) => p.providerId),
        ['chksz'],
        reason: '${capability.name} 必须仍然只走这一个条目',
      );
    }
  });

  test('未被任何条目服务的平台不可用，且不静默回落（D14）', () {
    final registry = OnlineMusicProviderRegistry(
      providers: [_AllCapabilityProvider('chksz', netease)],
      defaultProviderId: 'chksz',
    );

    for (final platform in [MusicPlatform.qq, MusicPlatform.kugou]) {
      for (final capability in OnlineMusicCapability.values) {
        expect(
          registry.providersFor(platform, capability),
          isEmpty,
          reason: '${platform.name} 没有 Provider 时必须为空，而不是回落到 netease 的条目',
        );
      }
    }
  });
}

final class _AllCapabilityProvider extends UnsupportedOnlineMusicProvider {
  _AllCapabilityProvider(this.providerId, this.platform);

  @override
  final String providerId;

  final MusicPlatform platform;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) => {
    platform,
  };
}
