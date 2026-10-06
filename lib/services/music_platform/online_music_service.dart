import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
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

/// 多平台聚合搜索的结果（D6）。
///
/// 刻意**不改** [MusicSearchPage]：每个平台仍然是一个独立的、带自己分页游标的
/// `MusicSearchPage`，这里只是把它们收集起来，并保留**每个平台各自的错误**，
/// 这样一个平台失败不会让整次搜索失去其它平台的结果。
///
/// **不做跨平台去重**（D6b:a）：同名同艺术家也可能是不同 remoteId、不同歌词、
/// 不同播放与不同音质体系，合并会破坏来源语义。每项的来源身份在
/// `page.items[*].ref`（platform + remoteId）里。
final class AggregatedSearchResult {
  AggregatedSearchResult({
    required Map<MusicPlatform, MusicSearchPage> perPlatform,
    required Map<MusicPlatform, OnlineMusicException> failures,
  }) : perPlatform = Map.unmodifiable(perPlatform),
       failures = Map.unmodifiable(failures);

  /// 成功返回的平台 → 该平台的搜索页（含各自的分页信息与来源身份）。
  final Map<MusicPlatform, MusicSearchPage> perPlatform;

  /// 失败平台 → 该平台的最终错误（例如 `unavailable` / `endpointMismatch`）。
  final Map<MusicPlatform, OnlineMusicException> failures;

  Iterable<MusicPlatform> get platforms => perPlatform.keys;

  bool get hasFailures => failures.isNotEmpty;

  /// 所有平台的结果都为空（或根本没有平台）。
  bool get isEmpty => perPlatform.values.every((page) => page.items.isEmpty);

  int get totalItems =>
      perPlatform.values.fold(0, (sum, page) => sum + page.items.length);

  @override
  String toString() =>
      'AggregatedSearchResult(${perPlatform.length} platforms, '
      '$totalItems items, ${failures.length} failures)';
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
