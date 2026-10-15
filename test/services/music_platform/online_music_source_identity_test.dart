import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';

/// **不变量 I1（本阶段的验收内核）**：Source Identity 必须贯穿
/// `Search → SearchResult → Track → Playlist/PlaylistItem → Lyric → Stream → Quality`，
/// 任何环节都不能丢失 Platform / remoteId。
///
/// 本文件补上此前没被覆盖的那一环：**搜索结果 → 播放队列项 → 播放解析**。
/// （其余环节已有各自测试：搜索聚合见 `online_music_aggregated_search_test.dart`，
/// 歌词见 `online_music_lyric_source_test.dart`，音质见 `online_music_quality_tiers_test.dart`。）
void main() {
  const qqRef = PlatformTrackRef(
    platform: MusicPlatform.qq,
    trackId: '0039MnYb0qxYhV',
  );
  const neteaseRef = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: '347230',
  );

  test('I1：搜索结果 → 队列项 → 播放解析，来源身份全程不丢', () async {
    // ① 搜索结果项（Domain Model）自带来源。
    final track = MusicTrack(
      ref: qqRef,
      title: '海阔天空',
      artists: const ['Beyond'],
      album: '乐与怒',
      duration: const Duration(milliseconds: 239560),
    );

    // ② 入队：队列项必须原样保留来源，否则后续无法按来源选播放 Provider。
    final item = RemotePlaybackQueueItem.fromTrack(track);
    expect(item.ref, qqRef, reason: '入队不得丢失 platform / remoteId');
    expect(item.title, '海阔天空');
    expect(item.artists, const ['Beyond']);

    // ③ 解析：必须按队列项的 ref.platform 选 Provider，且结果回到同一条来源。
    final qqProvider = _StreamProvider('qqStream', MusicPlatform.qq);
    final neteaseProvider = _StreamProvider(
      'neteaseStream',
      MusicPlatform.netease,
    );
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(
        providers: [neteaseProvider, qqProvider],
      ),
    );

    final stream = await service.resolve(
      item.ref,
      requestedQuality: 'lossless',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(qqProvider.resolveCalls, 1, reason: 'QQ 的来源必须由 QQ 的播放 Provider 解析');
    expect(
      neteaseProvider.resolveCalls,
      0,
      reason: '不能因为"另一个平台有 Provider"就把 QQ 的歌交给它',
    );
    expect(stream.ref, qqRef, reason: '解析结果必须指回同一条来源');
  });

  test('I1：不同来源的同名歌曲各自入队、各自解析，互不串源', () async {
    final qqItem = RemotePlaybackQueueItem.fromTrack(
      MusicTrack(ref: qqRef, title: '海阔天空', artists: const ['Beyond']),
    );
    final neteaseItem = RemotePlaybackQueueItem.fromTrack(
      MusicTrack(ref: neteaseRef, title: '海阔天空', artists: const ['Beyond']),
    );

    expect(qqItem.ref, isNot(neteaseItem.ref));

    final qqProvider = _StreamProvider('qqStream', MusicPlatform.qq);
    final neteaseProvider = _StreamProvider(
      'neteaseStream',
      MusicPlatform.netease,
    );
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(
        providers: [neteaseProvider, qqProvider],
      ),
    );

    await service.resolve(
      qqItem.ref,
      requestedQuality: 'lossless',
      cancelToken: OnlineMusicCancelToken(),
    );
    await service.resolve(
      neteaseItem.ref,
      requestedQuality: 'lossless',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(qqProvider.resolveCalls, 1);
    expect(neteaseProvider.resolveCalls, 1);
  });
}

final class _StreamProvider extends UnsupportedOnlineMusicProvider {
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

  _StreamProvider(this.providerId, this.platform);

  @override
  final String providerId;

  final MusicPlatform platform;

  int resolveCalls = 0;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      capability == OnlineMusicCapability.stream ? {platform} : const {};

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    resolveCalls++;
    return ResolvedStream(
      ref: ref,
      uri: Uri.parse('https://media.invalid/${platform.name}.flac'),
      requestedQuality: requestedQuality,
      resolvedAt: DateTime.now(),
    );
  }
}
