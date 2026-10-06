import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';

/// 应用层唯一消费的在线音乐入口：把每个能力分发给被选中的 Provider。
///
/// 应用层只依赖 [OnlineMusicService]；具体是哪个 Provider 由注册与选择决定，
/// 因此搜索、歌曲列表、歌词、播放可以各自使用不同 Provider。
final class CompositeOnlineMusicService implements OnlineMusicService {
  CompositeOnlineMusicService({required this.registry})
    : capabilities = OnlineMusicCapabilities(
        searchablePlatforms: registry
            .providerFor(OnlineMusicCapability.search)
            .platformsFor(OnlineMusicCapability.search),
        resolvablePlatforms: registry
            .providerFor(OnlineMusicCapability.stream)
            .platformsFor(OnlineMusicCapability.stream),
        playlistPlatforms: registry
            .providerFor(OnlineMusicCapability.playlist)
            .platformsFor(OnlineMusicCapability.playlist),
        lyricPlatforms: registry
            .providerFor(OnlineMusicCapability.lyric)
            .platformsFor(OnlineMusicCapability.lyric),
      );

  final OnlineMusicProviderRegistry registry;

  @override
  final OnlineMusicCapabilities capabilities;

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => _provider(OnlineMusicCapability.search).search(
    platform: platform,
    keyword: keyword,
    limit: limit,
    offset: offset,
    cancelToken: cancelToken,
  );

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => _provider(OnlineMusicCapability.playlist).fetchPlaylist(
    platform: platform,
    playlistId: playlistId,
    cancelToken: cancelToken,
  );

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => _provider(
    OnlineMusicCapability.lyric,
  ).fetchLyrics(ref, cancelToken: cancelToken);

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => _provider(OnlineMusicCapability.stream).resolve(
    ref,
    requestedQuality: requestedQuality,
    cancelToken: cancelToken,
  );

  @override
  String defaultQualityFor(MusicPlatform platform) =>
      _provider(OnlineMusicCapability.stream).defaultQualityFor(platform);

  @override
  void dispose() {
    for (final provider in registry.providers) {
      provider.dispose();
    }
  }

  OnlineMusicProvider _provider(OnlineMusicCapability capability) =>
      registry.providerFor(capability);
}
