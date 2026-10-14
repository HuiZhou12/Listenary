import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/chart_list_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 榜单全量页：网格渲染全部榜单，**只列"点得开"的平台**（缺歌单详情能力的平台会被
/// 排除，否则点进去只会失败）；单平台失败不影响其它平台；订阅必须把 `(platform, id)`
/// 原样交出去。网格的 `mainAxisExtent` 必须与卡片声明高度一致，否则会裁切/溢出。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late OnlinePlaylistController subscriptions;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    subscriptions = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: _ChartService(),
    );
  });

  tearDown(() {
    subscriptions.dispose();
    database.dispose();
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    OnlineMusicService? service,
    Size surface = const Size(1000, 1400),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: app_paths.EXPLORE_CHART_LIST_PAGE,
      routes: [
        GoRoute(
          path: app_paths.EXPLORE_CHART_LIST_PAGE,
          builder: (context, state) => const ChartListPage(),
        ),
        GoRoute(
          path: app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
          builder: (context, state) => const Scaffold(
            body: Text('stub:${app_paths.ONLINE_PLAYLIST_DETAIL_PAGE}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<OnlinePlaylistController>.value(
            value: subscriptions,
          ),
          if (service != null)
            Provider<OnlineMusicService>.value(value: service),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有可打开的榜单时说明原因，而不是空白页', (tester) async {
    await pumpPage(tester, service: _ChartService());

    expect(find.text('暂无可打开的榜单'), findsOneWidget);
    expect(find.textContaining('只列榜、取不到曲目的平台会被排除'), findsOneWidget);
  });

  testWidgets('★ 这是"查看全部"的落地页：不会用预览条数把榜单截掉', (tester) async {
    // 30 个榜单 —— 比任何"预览尺寸"都多。若页面用预览条数去要数据，这里就会只显示一部分。
    await pumpPage(
      tester,
      service: _ChartService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistPlatforms: const [MusicPlatform.netease],
          chartPlatforms: const [MusicPlatform.netease],
        ),
        charts: {
          MusicPlatform.netease: [
            for (var index = 0; index < 30; index++)
              RemotePlaylistSummary(
                platform: MusicPlatform.netease,
                id: '$index',
                name: '榜单$index',
              ),
          ],
        },
      ),
    );

    expect(find.text('30 个榜单'), findsOneWidget);
    expect(find.byType(RemoteMediaCard), findsNWidgets(30));
    // 榜单接口不可分页（网易云忽略 offset）⇒ 不该出现"加载更多"。
    expect(find.text('加载更多'), findsNothing);
  });

  testWidgets('网格渲染全部榜单，并显示更新节奏', (tester) async {
    await pumpPage(
      tester,
      service: _ChartService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistPlatforms: const [MusicPlatform.netease],
          chartPlatforms: const [MusicPlatform.netease],
        ),
        charts: const {
          MusicPlatform.netease: [
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '19723756',
              name: '飙升榜',
              trackCount: 98,
              updateFrequency: '刚刚更新',
            ),
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '3778678',
              name: '热歌榜',
              trackCount: 200,
              updateFrequency: '每天更新',
            ),
          ],
        },
      ),
    );

    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.text('热歌榜'), findsOneWidget);
    expect(find.text('榜单 · 刚刚更新 · 98 首'), findsOneWidget);
    // 只列出"点得开"的平台。
    expect(find.text('QQ音乐'), findsNothing);
  });

  testWidgets('网格的单元格高度与卡片声明高度一致（不裁切、不溢出）', (tester) async {
    await pumpPage(
      tester,
      surface: const Size(420, 1200),
      service: _ChartService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistPlatforms: const [MusicPlatform.netease],
          chartPlatforms: const [MusicPlatform.netease],
        ),
        charts: const {
          MusicPlatform.netease: [
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '1',
              name: '一个名字很长的榜单标题用来挤压网格布局',
              trackCount: 1261,
              updateFrequency: '每周四更新',
            ),
          ],
        },
      ),
    );

    expect(tester.takeException(), isNull);
    final card = tester.widget<RemoteMediaCard>(find.byType(RemoteMediaCard));
    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      RemoteMediaCard.extentFor(width: card.width, hasFooter: true),
    );
  });

  testWidgets('单平台失败隔离：其它平台照常显示', (tester) async {
    await pumpPage(
      tester,
      service: _ChartService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistPlatforms: const [MusicPlatform.netease, MusicPlatform.kugou],
          chartPlatforms: const [MusicPlatform.netease, MusicPlatform.kugou],
        ),
        charts: const {
          MusicPlatform.netease: [
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '1',
              name: '飙升榜',
            ),
          ],
        },
        failingCharts: const {MusicPlatform.kugou},
      ),
    );

    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.textContaining('酷狗音乐 榜单读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('订阅榜单会把 (平台, ID) 交出去，成功后进入歌单详情', (tester) async {
    final playlistService = _RecordingPlaylistService();
    subscriptions.dispose();
    subscriptions = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: playlistService,
    );

    await pumpPage(
      tester,
      service: _ChartService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistPlatforms: const [MusicPlatform.netease],
          chartPlatforms: const [MusicPlatform.netease],
        ),
        charts: const {
          MusicPlatform.netease: [
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '19723756',
              name: '飙升榜',
            ),
          ],
        },
      ),
    );

    await tester.tap(find.text('订阅'));
    await tester.pumpAndSettle();

    // 榜单在榜单型平台上就是歌单 ⇒ 订阅后走的是同一条歌单详情链路。
    expect(playlistService.requestedPlaylists, hasLength(1));
    expect(
      playlistService.requestedPlaylists.single.platform,
      MusicPlatform.netease,
    );
    expect(playlistService.requestedPlaylists.single.id, '19723756');
    expect(
      find.text('stub:${app_paths.ONLINE_PLAYLIST_DETAIL_PAGE}'),
      findsOneWidget,
    );
  });
}

/// 榜单页用到的服务替身：能力可配、榜单按平台返回/抛错。
final class _ChartService implements OnlineMusicService {
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

  @override
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('New albums are not implemented here');
  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist songs are not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist albums are not implemented here');
  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album detail is not implemented here');
  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist detail is not implemented here');
  _ChartService({
    OnlineMusicCapabilities? capabilities,
    this.charts = const {},
    this.failingCharts = const {},
  }) : capabilities =
           capabilities ??
           OnlineMusicCapabilities(
             searchablePlatforms: const [],
             resolvablePlatforms: const [],
           );

  @override
  final OnlineMusicCapabilities capabilities;

  final Map<MusicPlatform, List<RemotePlaylistSummary>> charts;
  final Set<MusicPlatform> failingCharts;

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('categories');

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    if (failingCharts.contains(platform)) {
      throw OnlineMusicException(
        kind: OnlineMusicErrorKind.unavailable,
        safeMessage: '${musicPlatformLabel(platform)} 榜单读取失败',
      );
    }
    // 替身像真实服务那样**认 limit**：这样"页面有没有用预览条数去要数据"才测得出。
    return (charts[platform] ?? const <RemotePlaylistSummary>[])
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(perPlatform: const {}, failures: const {});

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => MusicSearchPage(platform: platform, items: const []);

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('playlist');

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('resolve');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('new songs');

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('lyrics');

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
  }) => PlatformQualitySelection(
    requestValue: preference,
    displayLabel: preference,
    internalLevel: preference,
  );

  @override
  void dispose() {}
}

/// 只记录订阅请求的服务替身（证明榜单页把 `(platform, id)` 传对了）。
final class _RecordingPlaylistService implements OnlineMusicService {
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

  @override
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('New albums are not implemented here');
  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist songs are not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist albums are not implemented here');
  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album detail is not implemented here');
  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist detail is not implemented here');
  final requestedPlaylists = <({MusicPlatform platform, String id})>[];

  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
    playlistPlatforms: const [MusicPlatform.netease],
  );

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requestedPlaylists.add((platform: platform, id: playlistId));
    return RemotePlaylist(
      platform: platform,
      id: playlistId,
      name: '飙升榜',
      trackCount: 1,
      tracks: [
        MusicTrack(
          ref: PlatformTrackRef(platform: platform, trackId: 'n1'),
          title: 'Track n1',
          artists: const ['Artist'],
        ),
      ],
    );
  }

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('categories');

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(perPlatform: const {}, failures: const {});

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('search');

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('resolve');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('new songs');

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('lyrics');

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
  }) => PlatformQualitySelection(
    requestValue: preference,
    displayLabel: preference,
    internalLevel: preference,
  );

  @override
  void dispose() {}
}
