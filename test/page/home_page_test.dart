import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/home_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 聚合主页：数据按**已启用平台 + 真实可用能力**生成，来源始终可见，
/// 单平台失败不影响整页（Spec 第三段）。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late OnlineHistoryController history;
  late PersonalOnlinePlaylistController personal;
  late OnlinePlaylistController subscriptions;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    history = OnlineHistoryController(
      repository: SynchronousFuture(repository),
    );
    personal = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
    subscriptions = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: _HomeService(),
    );
  });

  tearDown(() {
    history.dispose();
    personal.dispose();
    subscriptions.dispose();
    database.dispose();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    OnlineMusicService? service,
  }) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: app_paths.HOME_PAGE,
      routes: [
        GoRoute(
          path: app_paths.HOME_PAGE,
          builder: (context, state) => const HomePage(),
        ),
        // 主页里的跳转目标：用轻量占位页，避免拉进整棵设置/统计树。
        for (final path in [
          app_paths.ONLINE_MUSIC_PAGE,
          app_paths.FAVORITES_PAGE,
          app_paths.STATS_PAGE,
          app_paths.SETTINGS_PAGE,
          app_paths.PLAYLISTS_PAGE,
        ])
          GoRoute(
            path: path,
            builder: (context, state) => Scaffold(body: Text('stub:$path')),
          ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<OnlineHistoryController>.value(value: history),
          ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
            value: personal,
          ),
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

  testWidgets('空数据时给出可读的空状态与"未配置"平台说明', (tester) async {
    await pumpHome(tester, service: _HomeService());

    // 五个区块都在。
    for (final title in ['平台状态', '最近播放', '我的收藏', '我的在线歌单', '平台歌单']) {
      expect(find.text(title), findsOneWidget, reason: '$title 区块必须存在');
    }
    expect(find.textContaining('还没有在线播放记录'), findsOneWidget);
    expect(find.textContaining('还没有收藏'), findsOneWidget);
    expect(find.textContaining('还没有自建歌单'), findsOneWidget);
    // 没有任何平台具备歌单列表能力 ⇒ 明确说明"怎么才会有"，而不是假装有内容。
    expect(find.textContaining('当前没有可用的「歌单列表」服务'), findsOneWidget);
    // 三个平台都在状态区列出，且都显示未配置。
    for (final platform in MusicPlatform.values) {
      expect(find.text(musicPlatformLabel(platform)), findsWidgets);
    }
    expect(find.text('未配置'), findsNWidgets(MusicPlatform.values.length));
  });

  testWidgets('平台状态按真实能力显示，并给出不可用原因', (tester) async {
    await pumpHome(
      tester,
      service: _HomeService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [MusicPlatform.netease],
          resolvablePlatforms: const [MusicPlatform.netease],
          lyricPlatforms: const [MusicPlatform.netease],
          unavailableSearchReasons: const {
            MusicPlatform.qq: '缺少播放解析能力，因此不会参与搜索',
          },
        ),
      ),
    );

    expect(find.text('缺少播放解析能力，因此不会参与搜索'), findsOneWidget);
    // 网易云可用：它的"搜索/歌单详情/歌单列表/歌词/播放解析"能力标签都在。
    expect(find.text('搜索'), findsWidgets);
    // QQ/酷狗没有可用候选，酷狗完全没有配置 ⇒ 只有它显示"未配置"；
    // QQ 有服务但被门槛挡下，显示的是**原因**而不是"未配置"。
    expect(find.text('未配置'), findsOneWidget);
  });

  testWidgets('最近播放与收藏逐行标注来源（跨平台）', (tester) async {
    repository.recordPlaybackStarted(_track('n1', MusicPlatform.netease));
    repository.recordPlaybackStarted(_track('q1', MusicPlatform.qq));
    repository.toggleFavorite(_track('q1', MusicPlatform.qq));
    repository.toggleFavorite(_track('n2', MusicPlatform.netease));
    await pumpHome(tester, service: _HomeService());

    // 历史区里两条（netease + qq），收藏区一条 QQ、一条网易云。
    expect(find.byType(OnlineTrackRow), findsNWidgets(4));
    final labels = tester
        .widgetList<OnlineTrackRow>(find.byType(OnlineTrackRow))
        .map((row) => row.sourceLabel)
        .toList(growable: false);
    expect(labels, contains('网易云'));
    expect(labels, contains('QQ音乐'));
    expect(labels.where((label) => label == 'QQ音乐'), hasLength(2));
  });

  testWidgets('平台歌单：按平台分组，单平台失败不影响其它平台', (tester) async {
    await pumpHome(
      tester,
      service: _HomeService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistCollectionPlatforms: const [
            MusicPlatform.netease,
            MusicPlatform.qq,
          ],
        ),
        collections: const {
          MusicPlatform.netease: [
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '1',
              name: '网易云歌单',
              creator: '甲',
            ),
          ],
        },
        // QQ 那次会抛错：验证单平台失败隔离。
        failingCollections: const {MusicPlatform.qq},
      ),
    );

    expect(find.text('网易云歌单'), findsOneWidget);
    expect(find.textContaining('网易云 · 甲'), findsOneWidget);
    // QQ 分组显示自己的错误，不影响网易云的结果。
    expect(find.textContaining('平台歌单读取失败'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
  });

  testWidgets('订阅平台歌单会把 (平台, ID) 交出去', (tester) async {
    final service = _HomeService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.qq],
      ),
      collections: const {
        MusicPlatform.qq: [
          RemotePlaylistSummary(
            platform: MusicPlatform.qq,
            id: '7729596131',
            name: 'QQ 歌单',
          ),
        ],
      },
    );
    final playlistService = _PlaylistRecordingService();
    subscriptions.dispose();
    subscriptions = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: playlistService,
    );

    await pumpHome(tester, service: service);
    await tester.tap(find.text('订阅'));
    await tester.pumpAndSettle();

    expect(playlistService.requestedPlaylists, hasLength(1));
    expect(
      playlistService.requestedPlaylists.single.platform,
      MusicPlatform.qq,
    );
    expect(playlistService.requestedPlaylists.single.id, '7729596131');
  });
}

MusicTrack _track(String id, MusicPlatform platform) => MusicTrack(
  ref: PlatformTrackRef(platform: platform, trackId: id),
  title: 'Track $id',
  artists: const ['Artist'],
);

/// 主页用到的在线音乐服务替身：能力可配、歌单列表按平台返回/抛错。
final class _HomeService implements OnlineMusicService {
  _HomeService({
    OnlineMusicCapabilities? capabilities,
    this.collections = const {},
    this.failingCollections = const {},
  }) : capabilities =
           capabilities ??
           OnlineMusicCapabilities(
             searchablePlatforms: const [],
             resolvablePlatforms: const [],
           );

  @override
  final OnlineMusicCapabilities capabilities;

  final Map<MusicPlatform, List<RemotePlaylistSummary>> collections;

  /// 这些平台的歌单列表会抛错（用来验证单平台失败隔离）。
  final Set<MusicPlatform> failingCollections;

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(perPlatform: const {}, failures: const {});

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    if (failingCollections.contains(platform)) {
      throw OnlineMusicException(
        kind: OnlineMusicErrorKind.unavailable,
        safeMessage: '${musicPlatformLabel(platform)} 平台歌单读取失败',
      );
    }
    return collections[platform] ?? const [];
  }

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => MusicSearchPage(platform: platform, items: const []);

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('resolve');

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('playlist');

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

/// 只记录订阅请求的服务替身（证明主页把 `(platform, id)` 传对了）。
final class _PlaylistRecordingService implements OnlineMusicService {
  final requestedPlaylists = <({MusicPlatform platform, String id})>[];

  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
    playlistPlatforms: const [MusicPlatform.qq],
  );

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(perPlatform: const {}, failures: const {});

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
      name: 'QQ 歌单',
      trackCount: 1,
      tracks: [_track('q1', platform)],
    );
  }

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

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
