import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

// `qualityTiersFor` / `selectQualityFor` 的返回类型属于契约本身的一部分，
// 因此从这里一并导出，调用方（含各测试替身）无需再单独 import 档位实现文件。
export 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

final class OnlineMusicCapabilities {
  OnlineMusicCapabilities({
    required Iterable<MusicPlatform> searchablePlatforms,
    required Iterable<MusicPlatform> resolvablePlatforms,
    Iterable<MusicPlatform> playlistPlatforms = const [],
    Iterable<MusicPlatform> playlistCollectionPlatforms = const [],
    Iterable<MusicPlatform> playlistCategoryPlatforms = const [],
    Iterable<MusicPlatform> chartPlatforms = const [],
    Iterable<MusicPlatform> newSongPlatforms = const [],
    Iterable<MusicPlatform> lyricPlatforms = const [],
    Map<MusicPlatform, String> unavailableSearchReasons = const {},
  }) : searchablePlatforms = Set.unmodifiable(searchablePlatforms),
       resolvablePlatforms = Set.unmodifiable(resolvablePlatforms),
       playlistPlatforms = Set.unmodifiable(playlistPlatforms),
       playlistCollectionPlatforms = Set.unmodifiable(
         playlistCollectionPlatforms,
       ),
       playlistCategoryPlatforms = Set.unmodifiable(
         playlistCategoryPlatforms,
       ),
       chartPlatforms = Set.unmodifiable(chartPlatforms),
       newSongPlatforms = Set.unmodifiable(newSongPlatforms),
       lyricPlatforms = Set.unmodifiable(lyricPlatforms),
       unavailableSearchReasons = Map.unmodifiable(unavailableSearchReasons);

  /// **可参与搜索**的平台（D3 硬门槛：必须同时具备可用的 Search 与 Stream 候选）。
  final Set<MusicPlatform> searchablePlatforms;

  /// 可做播放解析的平台。
  final Set<MusicPlatform> resolvablePlatforms;

  final Set<MusicPlatform> playlistPlatforms;
  final Set<MusicPlatform> lyricPlatforms;

  /// 能列出**歌单集合**的平台（Spec §19.2）。与 [playlistPlatforms] 各算各的：
  /// 只实现"歌单详情"的 Provider 不该被当成能列歌单。
  final Set<MusicPlatform> playlistCollectionPlatforms;

  /// 能列出**歌单分类**的平台。
  ///
  /// 只有当某平台同时具备本能力与 [playlistCollectionPlatforms] 时，按分类浏览才真的
  /// 可用 —— 只能列分类、取不到分类下歌单的平台，chip 墙上会是一排点不动的空 chip。
  /// 界面用 [browsableCategoryPlatforms] 判断。
  final Set<MusicPlatform> playlistCategoryPlatforms;

  /// 分类浏览**真的可用**的平台：必须同时具备分类索引与歌单列表能力。
  Set<MusicPlatform> get browsableCategoryPlatforms => {
    for (final platform in playlistCategoryPlatforms)
      if (playlistCollectionPlatforms.contains(platform)) platform,
  };

  /// 能列出**榜单索引**的平台。
  ///
  /// 榜单的曲目走既有的 [playlistPlatforms] 链路，所以"能列榜单"与"能打开榜单"
  /// 是两件事，见 [openableChartPlatforms]。
  final Set<MusicPlatform> chartPlatforms;

  /// 榜单**真的点得开**的平台：必须同时具备榜单索引与歌单详情能力。
  ///
  /// 为什么需要这条推导：榜单曲目复用歌单详情链路（网易云实测 `/toplist` 的 id
  /// 可直接用于 `/playlist/detail`）。若某平台只能列榜、不能取歌单详情，
  /// 它的榜单就是**死链**——界面必须把它排除，而不是让用户点进去看到失败。
  Set<MusicPlatform> get openableChartPlatforms => {
    for (final platform in chartPlatforms)
      if (playlistPlatforms.contains(platform)) platform,
  };

  /// 能列出**新歌**的平台。
  final Set<MusicPlatform> newSongPlatforms;

  /// 新歌**真的点得动**的平台：必须同时具备新歌与播放解析能力。
  ///
  /// 理由与搜索的 Stream 硬门槛（D3）一致：列表里放一批点不响的曲目，比不显示更糟。
  /// 曲目的 `availability` 在映射层拿不到可靠取值，所以只能在平台粒度上把这道门关住。
  Set<MusicPlatform> get playableNewSongPlatforms => {
    for (final platform in newSongPlatforms)
      if (resolvablePlatforms.contains(platform)) platform,
  };

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

  /// 多平台聚合搜索（D6:A / D6b:a / D6c:a）。
  ///
  /// 只对 ∈ [OnlineMusicCapabilities.searchablePlatforms] 的平台发请求；各平台**并行**、
  /// **各自分页**、**不做跨平台去重**；单平台的失败只进
  /// [AggregatedSearchResult.failures]，不影响其它平台的结果。
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  });

  /// 该平台**自己声明**的音质档位（含平台文案）。
  ///
  /// 空列表表示该平台没有档位声明（内部偏好原样透传）；UI 此时不得伪造平台档位名称
  /// （D2:A / 补充口径④）。
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform);

  /// 把内部偏好解析成该平台实际使用的档位（Spec §7.2 的确定式规则）。
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
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

  /// **歌单集合**（歌单列表，Spec §19.2）：元数据列表，**不含曲目**。
  ///
  /// [categoryId] 可选：给了就只取该分类下的歌单（取值必须是平台自己返回的分类标识，
  /// 见 [fetchPlaylistCategories]）。刻意**不**为它另开能力 —— 同一内容加一个筛选条件
  /// 不是新语义。
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Playlist collection is not supported');

  /// **歌单分类索引**：平台把歌单分成了哪些类，用于按分类浏览。
  ///
  /// 返回项的 `id` 必须**原样**回传给 `fetchPlaylistCollection(categoryId:)`：
  /// 各平台的分类标识形态不同（网易云实测用分类名）。
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Playlist categories are not supported');

  /// **榜单索引**：该平台发布了哪些名次集合，**不含曲目**。
  ///
  /// 返回的每一项的 `id` 就是后续用来打开它的 id（在榜单以歌单形态存在的平台上即歌单 id）。
  /// `limit` / `offset` 只是给能分页的平台用的**建议**：真实服务可能一次返回全部并忽略它们
  /// （例如网易云 `/toplist` 不接受任何分页参数）。**调用方不得据此刻画"分页"**，
  /// 只能按实际返回条数展示。
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Chart listing is not supported');

  /// **新歌**：该平台最近发布的曲目。
  ///
  /// `limit` / `offset` 只是**建议**：真实服务未必支持分页（网易云 `/personalized/newsong`
  /// 实测 `offset` 被忽略、只认 `limit`）。**调用方不得据此刻画"分页"**，只能按实际
  /// 返回条数展示。
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('New songs are not supported');

  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Lyric reading is not supported');

  /// 该平台**应请求的内部偏好档位**（不是平台请求值）。
  ///
  /// 调用方（播放链路）把它当"用户偏好"继续传递；真正发给平台的取值由 [resolve]
  /// 按该 Track 所属平台的档位声明转换（D2:A / D10:A）。
  String defaultQualityFor(MusicPlatform platform);

  void dispose();
}
