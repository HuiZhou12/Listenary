import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';

final class OnlineMusicCapabilities {
  OnlineMusicCapabilities({
    required Iterable<MusicPlatform> searchablePlatforms,
    required Iterable<MusicPlatform> resolvablePlatforms,
    Iterable<MusicPlatform> playlistPlatforms = const [],
    Iterable<MusicPlatform> lyricPlatforms = const [],
    Map<MusicPlatform, String> unavailableSearchReasons = const {},
  }) : searchablePlatforms = Set.unmodifiable(searchablePlatforms),
       resolvablePlatforms = Set.unmodifiable(resolvablePlatforms),
       playlistPlatforms = Set.unmodifiable(playlistPlatforms),
       lyricPlatforms = Set.unmodifiable(lyricPlatforms),
       unavailableSearchReasons = Map.unmodifiable(unavailableSearchReasons);

  /// **可参与搜索**的平台（D3 硬门槛：必须同时具备可用的 Search 与 Stream 候选）。
  final Set<MusicPlatform> searchablePlatforms;

  /// 可做播放解析的平台。
  final Set<MusicPlatform> resolvablePlatforms;

  final Set<MusicPlatform> playlistPlatforms;
  final Set<MusicPlatform> lyricPlatforms;

  /// 「有内容能力、但进不了搜索」的平台及其原因（D3b:a）。
  ///
  /// 用途：搜索页的平台筛选不列这些平台，设置页则据此说明"为什么它不能搜"
  /// （例如"缺少播放解析能力"），而不是让用户自己猜。
  final Map<MusicPlatform, String> unavailableSearchReasons;

  /// 该平台为何不能参与搜索；[searchablePlatforms] 里的平台返回 null。
  String? unavailableSearchReasonFor(MusicPlatform platform) =>
      unavailableSearchReasons[platform];
}

abstract interface class OnlineMusicService {
  OnlineMusicCapabilities get capabilities;

  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  });

  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  });

  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Playlist reading is not supported');

  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Lyric reading is not supported');

  String defaultQualityFor(MusicPlatform platform);

  void dispose();
}
