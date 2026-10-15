import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// 路由层的平台感知候选解析（S1）。
///
/// `providerFor` 保持旧的平台无关单值语义；`providersFor` 是新增的
/// `(platform, capability)` 有序候选，且**不做**平台无关的默认回落（D14）。
void main() {
  _FakeProvider provider(
    String id,
    Map<OnlineMusicCapability, Set<MusicPlatform>> platforms,
  ) => _FakeProvider(id, platforms);

  final neteaseOnly = <OnlineMusicCapability, Set<MusicPlatform>>{
    OnlineMusicCapability.search: {MusicPlatform.netease},
    OnlineMusicCapability.stream: {MusicPlatform.netease},
  };
  final qqOnly = <OnlineMusicCapability, Set<MusicPlatform>>{
    OnlineMusicCapability.search: {MusicPlatform.qq},
    OnlineMusicCapability.stream: {MusicPlatform.qq},
  };

  group('providersFor（平台感知候选）', () {
    test('只返回声明支持该平台 + 该能力的 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [provider('neteaseA', neteaseOnly), provider('qqA', qqOnly)],
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['neteaseA'],
      );
      expect(
        registry
            .providersFor(MusicPlatform.qq, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['qqA'],
      );
    });

    test('显式配置时只用这些候选，不再按注册顺序补齐（D17:b）', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          provider('neteaseA', neteaseOnly),
          provider('neteaseB', neteaseOnly),
          provider('neteaseC', neteaseOnly),
        ],
        capabilityProviders: {OnlineMusicCapability.search: 'neteaseC'},
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['neteaseC'],
      );
    });

    test('没有显式配置时才按注册顺序使用隐式候选', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          provider('neteaseA', neteaseOnly),
          provider('neteaseB', neteaseOnly),
          provider('neteaseC', neteaseOnly),
        ],
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['neteaseA', 'neteaseB', 'neteaseC'],
      );
    });

    test('旧单值映射只对"该 Provider 自己支持的平台"算显式候选', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [provider('neteaseA', neteaseOnly), provider('qqA', qqOnly)],
        // 把能力显式指向 qq 的 Provider，但查询的是 netease。
        capabilityProviders: {OnlineMusicCapability.search: 'qqA'},
      );

      // 旧单值映射平台无关：D13:A 把它解释为"qq 上的候选"，因此对 netease 而言
      // **没有**显式候选，仍按注册顺序使用隐式条目（与配置层 explicitCandidateIdsFor
      // 的 `contentPlatform != platform ⇒ 空` 一致）。
      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['neteaseA'],
      );
      expect(
        registry
            .providersFor(MusicPlatform.qq, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['qqA'],
      );
    });

    test('显式候选不支持该平台时，该组合没有候选也不补隐式条目（D17:b）', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [provider('neteaseA', neteaseOnly), provider('qqA', qqOnly)],
        // 配置层**显式**把 (netease, search) 指给了只在 qq 上的条目：
        // 这是用户表达过的偏好，不能再用隐式条目救场。
        explicitCandidates: (platform, capability) =>
            platform == MusicPlatform.netease &&
                capability == OnlineMusicCapability.search
            ? const ['qqA']
            : const [],
      );

      expect(
        registry.providersFor(
          MusicPlatform.netease,
          OnlineMusicCapability.search,
        ),
        isEmpty,
      );
    });

    test('该平台没有任何 Provider 时返回空列表，不回落到默认 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [provider('neteaseA', neteaseOnly)],
        defaultProviderId: 'neteaseA',
      );

      expect(
        registry.providersFor(
          MusicPlatform.kugou,
          OnlineMusicCapability.search,
        ),
        isEmpty,
      );
      expect(
        registry.providersFor(
          MusicPlatform.netease,
          OnlineMusicCapability.lyric,
        ),
        isEmpty,
      );
    });

    test('能力不分平台时，候选只包含真正声明了该能力的 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          provider('withLyric', {
            ...neteaseOnly,
            OnlineMusicCapability.lyric: {MusicPlatform.netease},
          }),
          provider('withoutLyric', neteaseOnly),
        ],
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.lyric)
            .map((it) => it.providerId),
        ['withLyric'],
      );
    });
  });

  group('providerFor（旧语义保持不变）', () {
    test('指向未注册 Provider 时仍回落默认 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          provider('neteaseA', neteaseOnly),
          provider('neteaseB', neteaseOnly),
        ],
        defaultProviderId: 'neteaseB',
        capabilityProviders: {OnlineMusicCapability.search: 'missing'},
      );

      expect(registry.providerIdFor(OnlineMusicCapability.search), 'neteaseB');
    });
  });
}

final class _FakeProvider extends UnsupportedOnlineMusicProvider {
  @override
  Future<List<RemotePlaylistSummary>> fetchPersonalizedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Personalized playlists are not implemented here');

  @override
  Future<List<OnlineArtistSummary>> fetchFollowedArtists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Followed artists are not implemented here');

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
