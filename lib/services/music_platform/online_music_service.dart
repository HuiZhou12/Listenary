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
    Iterable<MusicPlatform> newAlbumPlatforms = const [],
    Iterable<MusicPlatform> searchableAlbumPlatforms = const [],
    Iterable<MusicPlatform> searchableArtistPlatforms = const [],
    Iterable<MusicPlatform> artistPlatforms = const [],
    Iterable<MusicPlatform> albumPlatforms = const [],
    Iterable<MusicPlatform> artistAlbumPlatforms = const [],
    Iterable<MusicPlatform> artistSongPlatforms = const [],
    Iterable<MusicPlatform> lyricPlatforms = const [],
    Iterable<PlatformIdentity> resolvableIdentities = const [],
    Map<MusicPlatform, String> unavailableSearchReasons = const {},
  }) : searchablePlatforms = Set.unmodifiable(searchablePlatforms),
       resolvablePlatforms = Set.unmodifiable(resolvablePlatforms),
       resolvableIdentities = Set.unmodifiable(resolvableIdentities),
       playlistPlatforms = Set.unmodifiable(playlistPlatforms),
       playlistCollectionPlatforms = Set.unmodifiable(
         playlistCollectionPlatforms,
       ),
       playlistCategoryPlatforms = Set.unmodifiable(
         playlistCategoryPlatforms,
       ),
       chartPlatforms = Set.unmodifiable(chartPlatforms),
       newSongPlatforms = Set.unmodifiable(newSongPlatforms),
       newAlbumPlatforms = Set.unmodifiable(newAlbumPlatforms),
       searchableAlbumPlatforms = Set.unmodifiable(searchableAlbumPlatforms),
       searchableArtistPlatforms = Set.unmodifiable(searchableArtistPlatforms),
       artistPlatforms = Set.unmodifiable(artistPlatforms),
       albumPlatforms = Set.unmodifiable(albumPlatforms),
       artistAlbumPlatforms = Set.unmodifiable(artistAlbumPlatforms),
       artistSongPlatforms = Set.unmodifiable(artistSongPlatforms),
       lyricPlatforms = Set.unmodifiable(lyricPlatforms),
       unavailableSearchReasons = Map.unmodifiable(unavailableSearchReasons);

  /// **可参与搜索**的平台（D3 硬门槛：必须同时具备可用的 Search 与 Stream 候选）。
  final Set<MusicPlatform> searchablePlatforms;

  /// 可做播放解析的平台。
  final Set<MusicPlatform> resolvablePlatforms;

  /// F5-P-39（P-63）：**按平台身份**可做播放解析的集合（自定义平台用稳定 ID 区分）。
  final Set<PlatformIdentity> resolvableIdentities;

  /// P-63（可用性复核的**唯一判据**）：这条数据所属的平台身份当前能否解析（能否播放）。
  ///
  /// - 内置平台 ⇒ 沿用 [resolvablePlatforms]（既有语义不变）；
  /// - 自定义平台 ⇒ 按 **`(custom, stableId)`** 精确判定（只比枚举会让两个自定义平台互相冒充）；
  /// - 身份无效（缺稳定 ID）或未登记 ⇒ `false`（fail-closed：**只呈现状态**，
  ///   不静默删除数据、不自动改写身份、不触发任何修复动作）。
  /// P-63: 这条曲目当前**能否播放** —— 可用性复核的统一判据（内置语义 + **身份判据**）。
  /// 身份无法解析（自定义平台缺稳定 ID / 未登记 / 未知历史值）⇒ false；
  /// 调用方据此**只呈现状态**，不得删除数据或改写身份。
  bool canPlayTrack(MusicTrack track) =>
      track.availability != TrackAvailability.unavailable &&
      track.availability != TrackAvailability.paid &&
      canResolveIdentity(track.ref.identity);

  bool canResolveIdentity(PlatformIdentity identity) {
    if (!identity.isValid) return false;
    if (!identity.isCustom) return resolvablePlatforms.contains(identity.platform);
    return resolvableIdentities.contains(identity);
  }

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

  /// 能列**新专辑**的平台（`newAlbums` 能力，2026-10-12 新增）。
  final Set<MusicPlatform> newAlbumPlatforms;

  /// 能**按关键词搜专辑**的平台（`searchAlbums` 能力，2026-10-12 新增）。
  final Set<MusicPlatform> searchableAlbumPlatforms;

  /// 能**按关键词搜艺人**的平台（`searchArtists` 能力，2026-10-12 新增）。
  final Set<MusicPlatform> searchableArtistPlatforms;

  /// 能取"艺人 + 热门曲目"的平台（`artist` 能力，2026-10-12 新增）。
  final Set<MusicPlatform> artistPlatforms;

  /// 能取"专辑元数据 + 曲目"的平台（`album` 能力，2026-10-12 新增）。
  final Set<MusicPlatform> albumPlatforms;

  /// 能列**艺人专辑**的平台（`artistAlbums` 能力，2026-10-12 新增）。
  final Set<MusicPlatform> artistAlbumPlatforms;

  /// 能列**艺人单曲**的平台（`artistSongs` 能力，2026-10-12 新增）。
  final Set<MusicPlatform> artistSongPlatforms;

  /// 新歌**真的点得动**的平台：必须同时具备新歌与播放解析能力。
  ///
  /// 理由与搜索的 Stream 硬门槛（D3）一致：列表里放一批点不响的曲目，比不显示更糟。
  /// 曲目的 `availability` 在映射层拿不到可靠取值，所以只能在平台粒度上把这道门关住。
  Set<MusicPlatform> get playableNewSongPlatforms => {
    for (final platform in newSongPlatforms)
      if (resolvablePlatforms.contains(platform)) platform,
  };

  /// 能列新专辑**且专辑打得开**的平台（与 [openableArtistAlbumPlatforms] 同一条判据 ✓）。
  Set<MusicPlatform> get openableNewAlbumPlatforms => {
    for (final platform in newAlbumPlatforms)
      if (albumPlatforms.contains(platform)) platform,
  };

  /// 搜索页「专辑」分区**打得开**的平台：既要能搜专辑，又要能打开专辑详情 ✓
  ///（搜出来点不开，比不显示更糟 ✗）。
  Set<MusicPlatform> get openableSearchAlbumPlatforms => {
    for (final platform in searchableAlbumPlatforms)
      if (albumPlatforms.contains(platform)) platform,
  };

  /// 搜索结果里「艺人」行**打得开**的平台：既要能搜艺人，又要能打开艺人页 ✓
  ///（搜出来点不开，比不显示更糟 ✗）。
  Set<MusicPlatform> get openableSearchArtistPlatforms => {
    for (final platform in searchableArtistPlatforms)
      if (artistPlatforms.contains(platform)) platform,
  };

  /// 能取艺人详情**且热门曲目点得响**的平台。
  ///
  /// 与 [playableNewSongPlatforms] 同一条理由：列表里的曲目点不动，比不显示更糟 ⇒
  /// 艺人页只对"能播"的平台出现。
  Set<MusicPlatform> get playableArtistPlatforms => {
    for (final platform in artistPlatforms)
      if (resolvablePlatforms.contains(platform)) platform,
  };

  /// 能取专辑详情**且曲目点得响**的平台（同 [playableArtistPlatforms] 的理由 ✓）。
  Set<MusicPlatform> get playableAlbumPlatforms => {
    for (final platform in albumPlatforms)
      if (resolvablePlatforms.contains(platform)) platform,
  };

  /// 艺人页「专辑」区块**真的能打开**的平台：既要能列专辑，又要能打开专辑详情 ✓。
  ///
  /// 与 [openableChartPlatforms] 同一条理由：列出来却打不开，比不显示更糟 ✗。
  Set<MusicPlatform> get openableArtistAlbumPlatforms => {
    for (final platform in artistAlbumPlatforms)
      if (albumPlatforms.contains(platform)) platform,
  };

  /// 艺人页「单曲」区块**点得响**的平台：既要能列单曲，又要能播放解析 ✓
  ///（与 [playableNewSongPlatforms] 同一条理由 ✓）。
  Set<MusicPlatform> get playableArtistSongPlatforms => {
    for (final platform in artistSongPlatforms)
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
    Map<PlatformIdentity, MusicSearchPage> perPlatformIdentity = const {},
    Map<PlatformIdentity, OnlineMusicException> failuresByIdentity = const {},
  }) : perPlatform = Map.unmodifiable(perPlatform),
       failures = Map.unmodifiable(failures),
       perPlatformIdentity = Map.unmodifiable(perPlatformIdentity),
       failuresByIdentity = Map.unmodifiable(failuresByIdentity);

  /// F5-P-39（P2）：按**平台身份**索引的成功结果 —— 自定义平台必须读这一份。
  /// perPlatform 以 MusicPlatform 为键 ⇒ 所有自定义平台共用一个键；聚合时若同一键被
  /// **不同身份**写入，旧 map 会**移除**该键（绝不静默覆盖），改由本 map 承载。
  final Map<PlatformIdentity, MusicSearchPage> perPlatformIdentity;

  /// F5-P-39（P2）：按**平台身份**索引的失败信息（语义同 [perPlatformIdentity]）。
  final Map<PlatformIdentity, OnlineMusicException> failuresByIdentity;

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

  /// **艺人详情**（`artist`，2026-10-12 新增）：艺人标量信息 + **热门曲目**。
  ///
  /// 为什么与"新歌"分开：它是**按实体 ID 取单条**（艺人 id 由调用方给出），
  /// 而新歌是"服务端决定给什么"✓。热门曲目**不另开能力**：一次请求就能拿到
  /// （D2：一个能力不做多请求）✓。
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist detail is not supported');

  /// **专辑详情**（`album`，2026-10-12 新增）：专辑元数据 + **曲目**。
  ///
  /// 与"歌单详情"形状相同但语义不同：专辑有发行时间/曲目数/专辑艺人，且真实服务是另一个接口。
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album detail is not supported');

  /// **按关键词搜索艺人**（`searchArtists`，2026-10-12 新增）：搜索结果里的「艺人」那一段 ✓。
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist search is not supported');

  /// **按关键词搜索专辑**（`searchAlbums`，2026-10-12 新增）：搜索页结果分区里的「专辑」✓。
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album search is not supported');

  /// **新专辑**（`newAlbums`，2026-10-12 新增）：平台最近发布的专辑（**输出是专辑摘要** ✓）。
  ///
  /// 与 [fetchNewSongs] 分开：真实服务是另一个接口，输出形状也不同（专辑 vs 曲目 ✓）。
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('New albums are not supported');

  /// **艺人的专辑列表**（`artistAlbums`，2026-10-12 新增）：参考艺人页的「专辑」区块 ✓。
  ///
  /// 返回**专辑摘要**（不带曲目 ✓）；点其中一张再走 [fetchAlbum] 拿曲目 ✓。
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist albums are not supported');

  /// **艺人的单曲列表**（`artistSongs`，2026-10-12 新增）：参考艺人页的「单曲和迷你专辑」区块 ✓。
  ///
  /// 输出就是**曲目**（复用 `MusicTrack` ✓）—— 实测 `/artist/songs` 的曲目就是标准曲目形状 ✓。
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist songs are not supported');

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
