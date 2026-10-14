import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// 服务层分发已切到**平台感知候选**（S1b）。
///
/// 取候选首个；候选为空时在发请求**之前**就报 `unavailable`（D14：不做平台无关回落）。
void main() {
  final neteaseSearch = <OnlineMusicCapability, Set<MusicPlatform>>{
    OnlineMusicCapability.search: {MusicPlatform.netease},
    OnlineMusicCapability.stream: {MusicPlatform.netease},
  };
  final qqSearch = <OnlineMusicCapability, Set<MusicPlatform>>{
    OnlineMusicCapability.search: {MusicPlatform.qq},
    OnlineMusicCapability.stream: {MusicPlatform.qq},
  };

  test('search 分发给该平台候选列表的首个，且不受其他平台 Provider 影响', () async {
    final netease = _RecordingProvider('neteaseA', neteaseSearch);
    final qq = _RecordingProvider('qqA', qqSearch);
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(providers: [netease, qq]),
    );

    await service.search(
      platform: MusicPlatform.netease,
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(netease.calls, ['search:netease']);
    expect(qq.calls, isEmpty);
  });

  test('显式配置的候选排在首位并被使用', () async {
    final first = _RecordingProvider('neteaseA', neteaseSearch);
    final explicit = _RecordingProvider('neteaseB', neteaseSearch);
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(
        providers: [first, explicit],
        capabilityProviders: {OnlineMusicCapability.search: 'neteaseB'},
      ),
    );

    await service.search(
      platform: MusicPlatform.netease,
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(explicit.calls, ['search:netease']);
    expect(first.calls, isEmpty);
  });

  test('该平台没有候选时，在发请求之前就报 unavailable', () async {
    final netease = _RecordingProvider('neteaseA', neteaseSearch);
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(
        providers: [netease],
        defaultProviderId: 'neteaseA',
      ),
    );

    await expectLater(
      service.search(
        platform: MusicPlatform.kugou,
        keyword: 'x',
        cancelToken: OnlineMusicCancelToken(),
      ),
      throwsA(
        isA<OnlineMusicException>().having(
          (error) => error.kind,
          'kind',
          OnlineMusicErrorKind.unavailable,
        ),
      ),
    );
    expect(netease.calls, isEmpty, reason: '不应把不支持该平台的请求交给任何 Provider');
  });

  test('播放解析按 ref.platform 选 Provider', () async {
    final netease = _RecordingProvider('neteaseA', neteaseSearch);
    final qq = _RecordingProvider('qqA', qqSearch);
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(providers: [netease, qq]),
    );

    await service.resolve(
      const PlatformTrackRef(platform: MusicPlatform.qq, trackId: '42'),
      requestedQuality: 'lossless',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(qq.calls, ['resolve:qq']);
    expect(netease.calls, isEmpty);
  });
}

final class _RecordingProvider extends UnsupportedOnlineMusicProvider {
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

  _RecordingProvider(this.providerId, this._platforms);

  @override
  final String providerId;

  final Map<OnlineMusicCapability, Set<MusicPlatform>> _platforms;

  final List<String> calls = [];

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
    calls.add('search:${platform.name}');
    return MusicSearchPage(platform: platform, items: const []);
  }

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    calls.add('resolve:${ref.platform.name}');
    return ResolvedStream(
      ref: ref,
      uri: Uri.parse('https://media.invalid/a.flac'),
      requestedQuality: requestedQuality,
      resolvedAt: DateTime.now(),
    );
  }

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';
}
