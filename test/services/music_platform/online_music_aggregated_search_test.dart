import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';

/// S4：多平台并行聚合（D6:A）、单平台失败隔离、门槛过滤（D3）、不去重（D6b:a）。
void main() {
  const search = OnlineMusicCapability.search;
  const stream = OnlineMusicCapability.stream;
  const netease = MusicPlatform.netease;
  const qq = MusicPlatform.qq;

  // 每个 fake 只服务**自己那个平台**：否则它也会成为另一个平台的隐式候选，
  // 把本该发给 qq Provider 的请求接走。
  final neteasePlatforms = <OnlineMusicCapability, Set<MusicPlatform>>{
    search: const {netease},
    stream: const {netease},
  };
  final qqPlatforms = <OnlineMusicCapability, Set<MusicPlatform>>{
    search: const {qq},
    stream: const {qq},
  };

  CompositeOnlineMusicService serviceWith(List<_PagedProvider> providers) =>
      CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: providers),
      );

  Future<AggregatedSearchResult> aggregate(
    CompositeOnlineMusicService service,
    List<MusicPlatform> platforms,
  ) => service.searchAggregated(
    platforms: platforms,
    keyword: '海阔天空',
    cancelToken: OnlineMusicCancelToken(),
  );

  test('并行聚合各平台的独立分页结果，且每项都保留来源身份', () async {
    final neteaseProvider = _PagedProvider(
      'neteaseA',
      neteasePlatforms,
      titles: ['海阔天空(网易云)'],
    );
    final qqProvider = _PagedProvider('qqA', qqPlatforms, titles: ['海阔天空(QQ)']);
    final service = serviceWith([neteaseProvider, qqProvider]);

    final result = await aggregate(service, [netease, qq]);

    expect(result.failures, isEmpty);
    expect(result.platforms.toSet(), {netease, qq});
    expect(result.totalItems, 2);
    expect(result.isEmpty, isFalse);

    final neteaseItem = result.perPlatform[netease]!.items.single;
    final qqItem = result.perPlatform[qq]!.items.single;
    // 来源不丢：每个平台的结果只带自己的 platform + remoteId。
    expect(neteaseItem.ref.platform, netease);
    expect(qqItem.ref.platform, qq);
    expect(neteaseItem.ref.trackId, isNot(qqItem.ref.trackId));
    // 两个平台各请求了一次。
    expect(neteaseProvider.searchCalls, 1);
    expect(qqProvider.searchCalls, 1);
  });

  test('单平台失败不影响其它平台的结果', () async {
    final healthy = _PagedProvider(
      'neteaseA',
      neteasePlatforms,
      titles: ['ok'],
    );
    final broken = _PagedProvider(
      'qqA',
      qqPlatforms,
      failure: OnlineMusicErrorKind.endpointMismatch,
    );
    final service = serviceWith([healthy, broken]);

    final result = await aggregate(service, [netease, qq]);

    expect(result.platforms.toSet(), {netease});
    expect(result.perPlatform[netease]!.items.single.title, 'ok');
    expect(result.hasFailures, isTrue);
    expect(result.failures[qq]!.kind, OnlineMusicErrorKind.endpointMismatch);
  });

  test('不可搜索的平台（缺 Stream）不参与，也不发请求（D3）', () async {
    final neteaseProvider = _PagedProvider(
      'neteaseA',
      {
        search: const {netease},
        stream: const {netease},
      },
      titles: ['ok'],
    );
    // qq 只有 search、没有 stream ⇒ 被门槛挡下。
    final qqProvider = _PagedProvider(
      'qqA',
      {
        search: const {qq},
      },
      titles: ['should not be requested'],
    );
    final service = serviceWith([neteaseProvider, qqProvider]);

    final result = await aggregate(service, [netease, qq]);

    expect(result.platforms.toSet(), {netease});
    expect(result.failures, isEmpty, reason: '被门槛挡下不算失败');
    expect(qqProvider.searchCalls, 0);
  });

  test('不跨平台去重：同名同艺术家仍是两条独立结果（D6b:a）', () async {
    final neteaseProvider = _PagedProvider(
      'neteaseA',
      neteasePlatforms,
      titles: ['海阔天空'],
      artists: ['Beyond'],
    );
    final qqProvider = _PagedProvider(
      'qqA',
      qqPlatforms,
      titles: ['海阔天空'],
      artists: ['Beyond'],
    );
    final service = serviceWith([neteaseProvider, qqProvider]);

    final result = await aggregate(service, [netease, qq]);

    expect(result.totalItems, 2);
    final refs = [
      for (final page in result.perPlatform.values)
        for (final item in page.items) item.ref,
    ];
    expect(refs.toSet(), hasLength(2), reason: '两个平台的 remoteId 不同');
  });

  test('被请求的平台集合为空时返回空聚合结果', () async {
    final provider = _PagedProvider('neteaseA', neteasePlatforms);
    final service = serviceWith([provider]);

    final result = await aggregate(service, const []);

    expect(result.perPlatform, isEmpty);
    expect(result.failures, isEmpty);
    expect(result.isEmpty, isTrue);
    expect(provider.searchCalls, 0);
  });
}

final class _PagedProvider extends UnsupportedOnlineMusicProvider {
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

  _PagedProvider(
    this.providerId,
    this._platforms, {
    this.titles = const [],
    List<String> artists = const [],
    this.failure,
  }) : _artists = artists;

  @override
  final String providerId;

  final Map<OnlineMusicCapability, Set<MusicPlatform>> _platforms;
  final List<String> titles;
  final List<String> _artists;
  final OnlineMusicErrorKind? failure;

  int searchCalls = 0;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _platforms[capability] ?? const {};

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    searchCalls++;
    final kind = failure;
    if (kind != null) {
      throw OnlineMusicException(
        kind: kind,
        safeMessage: 'failed:${kind.name}',
      );
    }
    return MusicSearchPage(
      platform: platform,
      items: [
        for (var index = 0; index < titles.length; index++)
          MusicTrack(
            ref: PlatformTrackRef(
              platform: platform,
              trackId: '${providerId}_$index',
            ),
            title: titles[index],
            artists: _artists.isEmpty ? const ['artist'] : _artists,
          ),
      ],
      offset: offset,
      limit: limit,
    );
  }
}
