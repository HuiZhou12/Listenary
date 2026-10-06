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
  }) {
    final provider = _candidateFor(platform, OnlineMusicCapability.search);
    if (provider == null) return Future.error(unsupportedCapability());
    return provider.search(
      platform: platform,
      keyword: keyword,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) {
    final provider = _candidateFor(platform, OnlineMusicCapability.playlist);
    if (provider == null) return Future.error(unsupportedCapability());
    return provider.fetchPlaylist(
      platform: platform,
      playlistId: playlistId,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) {
    final provider = _candidateFor(ref.platform, OnlineMusicCapability.lyric);
    if (provider == null) return Future.error(unsupportedCapability());
    return provider.fetchLyrics(ref, cancelToken: cancelToken);
  }

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) {
    final provider = _candidateFor(ref.platform, OnlineMusicCapability.stream);
    if (provider == null) return Future.error(unsupportedCapability());
    return provider.resolve(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    );
  }

  @override
  String defaultQualityFor(MusicPlatform platform) {
    final provider = _candidateFor(platform, OnlineMusicCapability.stream);
    if (provider == null) throw unsupportedCapability();
    return provider.defaultQualityFor(platform);
  }

  @override
  void dispose() {
    for (final provider in registry.providers) {
      provider.dispose();
    }
  }

  /// 平台感知分发：取 `(platform, capability)` 候选列表的**首个**。
  ///
  /// 返回 null 表示该平台此能力没有可用 Provider；四个异步能力据此在发出请求**之前**
  /// 以 `Future.error(unavailable)` 失败，而不是把请求交给一个不支持的 Provider
  /// （D14：不做平台无关的默认回落）。候选排序与受限回退分别在
  /// [OnlineMusicProviderRegistry.providersFor] 与后续切片中处理。
  OnlineMusicProvider? _candidateFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    final candidates = registry.providersFor(platform, capability);
    return candidates.isEmpty ? null : candidates.first;
  }
}
