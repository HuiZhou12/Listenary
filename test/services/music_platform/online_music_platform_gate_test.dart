import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';

/// S3：平台集合按**候选**推导，且搜索有 **Stream 硬门槛**（D3）。
void main() {
  const search = OnlineMusicCapability.search;
  const stream = OnlineMusicCapability.stream;
  const playlist = OnlineMusicCapability.playlist;
  const lyric = OnlineMusicCapability.lyric;
  const netease = MusicPlatform.netease;
  const qq = MusicPlatform.qq;

  OnlineMusicCapabilities capabilitiesOf(List<_FakeProvider> providers) =>
      CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: providers),
      ).capabilities;

  test('同时有 Search 与 Stream 的平台才可搜索', () {
    final capabilities = capabilitiesOf([
      _FakeProvider('full', {
        search: const {netease},
        stream: const {netease},
      }),
    ]);

    expect(capabilities.searchablePlatforms, {netease});
    expect(capabilities.resolvablePlatforms, {netease});
    expect(capabilities.unavailableSearchReasonFor(netease), isNull);
  });

  test('只有 Search、缺 Stream 的平台不参与搜索，并给出原因（D3b:a）', () {
    final capabilities = capabilitiesOf([
      _FakeProvider('searchOnly', {
        search: const {netease},
      }),
    ]);

    expect(capabilities.searchablePlatforms, isEmpty);
    expect(
      capabilities.unavailableSearchReasonFor(netease),
      contains('缺少播放解析能力'),
    );
    // 它仍然有搜索候选，只是被门槛挡下；resolvable 集合不受影响。
    expect(capabilities.resolvablePlatforms, isEmpty);
  });

  test('只有 Stream、缺 Search 的平台同样不参与搜索，原因指向搜索能力', () {
    final capabilities = capabilitiesOf([
      _FakeProvider('streamOnly', {
        stream: const {netease},
      }),
    ]);

    expect(capabilities.searchablePlatforms, isEmpty);
    expect(
      capabilities.unavailableSearchReasonFor(netease),
      contains('缺少搜索能力'),
    );
    expect(capabilities.resolvablePlatforms, {netease});
  });

  test('同平台的能力可以由不同 Provider 提供（并集，不是"看被选中的那个"）', () {
    final capabilities = capabilitiesOf([
      _FakeProvider('searchProvider', {
        search: const {netease},
      }),
      _FakeProvider('streamProvider', {
        stream: const {netease},
      }),
    ]);

    expect(capabilities.searchablePlatforms, {netease});
    expect(capabilities.resolvablePlatforms, {netease});
    expect(capabilities.unavailableSearchReasons, isEmpty);
  });

  test('多平台各自独立判定，未配置的平台不进入任何集合', () {
    final capabilities = capabilitiesOf([
      _FakeProvider('neteaseFull', {
        search: const {netease},
        stream: const {netease},
        playlist: const {netease},
        lyric: const {netease},
      }),
      _FakeProvider('qqSearchOnly', {
        search: const {qq},
      }),
    ]);

    expect(capabilities.searchablePlatforms, {netease});
    expect(capabilities.playlistPlatforms, {netease});
    expect(capabilities.lyricPlatforms, {netease});
    expect(capabilities.unavailableSearchReasonFor(qq), contains('缺少播放解析能力'));
    // 完全没有 Provider 的平台既不"可用"也不在"原因"表里：那是"未配置服务"，
    // 由设置页的平台卡负责说明（S8），不是能力门槛的结论。
    expect(
      capabilities.unavailableSearchReasonFor(MusicPlatform.kugou),
      isNull,
    );
  });

  test('补齐 Stream 后平台自动进入可搜索集合', () {
    final searchOnly = _FakeProvider('searchOnly', {
      search: const {netease},
    });
    expect(capabilitiesOf([searchOnly]).searchablePlatforms, isEmpty);

    final capabilities = capabilitiesOf([
      searchOnly,
      _FakeProvider('streamProvider', {
        stream: const {netease},
      }),
    ]);
    expect(capabilities.searchablePlatforms, {netease});
    expect(capabilities.unavailableSearchReasons, isEmpty);
  });

  test('被停用的平台不进任何能力集合，其能力也不可用（D8:A）', () {
    final registry = OnlineMusicProviderRegistry(
      providers: [
        _FakeProvider('full', {
          search: const {netease, qq},
          stream: const {netease, qq},
          playlist: const {netease, qq},
          lyric: const {netease, qq},
        }),
      ],
      enabledPlatforms: const {netease},
    );
    final service = CompositeOnlineMusicService(registry: registry);

    expect(service.capabilities.searchablePlatforms, {netease});
    expect(service.capabilities.resolvablePlatforms, {netease});
    expect(service.capabilities.playlistPlatforms, {netease});
    expect(service.capabilities.lyricPlatforms, {netease});
    // 停用的平台：候选按"空"处理 ⇒ 调用时报 unavailable。
    expect(registry.providersFor(qq, search), isEmpty);
    expect(registry.providersFor(qq, stream), isEmpty);
    expect(registry.providersFor(qq, playlist), isEmpty);
    // "停用"不是能力门槛的结论，原因表里不出现它 —— 由设置页平台卡显示"已停用"。
    expect(service.capabilities.unavailableSearchReasonFor(qq), isNull);
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
