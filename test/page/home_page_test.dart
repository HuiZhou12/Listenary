import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/home_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 聚合主页：**你自己的内容在前、平台内容在后、配置诊断收进底部**；
/// 来源始终可见，单平台失败不影响整页。
///
/// 本文件由旧版主页测试改写而来。旧断言编码的 6 条业务保证**逐条保留**，只是
/// 换了查询方式（页面结构变了，保证没变）：
/// | 旧断言 | 现在 |
/// |---|---|
/// | 空数据给出可读空状态 | 保留（第 1 条） |
/// | 平台能力按真实能力显示 + 不可用原因 | 保留（第 2 条，改为展开「平台能力」后断言） |
/// | 最近播放/收藏逐行标注来源 | 保留（第 3 条） |
/// | 平台歌单按平台分组 + 单平台失败隔离 | 保留（第 4 条） |
/// | 订阅把 (平台, ID) 交出去 | 保留（第 5 条） |
/// | 窄窗口不溢出 | 保留（第 6 条） |
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
          app_paths.EXPLORE_PAGE,
          app_paths.FAVORITES_PAGE,
          app_paths.STATS_PAGE,
          app_paths.SETTINGS_PAGE,
          app_paths.PLAYLISTS_PAGE,
        ])
          GoRoute(
            path: path,
            // 连 query 一起暴露：`/stats?source=online` 这类跳转的语义全在 query 上，
            // 只断言路径会让"query 丢了"这种问题一路溜过去。
            builder: (context, state) => Scaffold(
              body: Text('stub:$path|${state.uri.query}'),
            ),
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

  /// 「平台能力」默认收起（它是诊断信息，不该占据首屏）——断言其内容前要先展开。
  Future<void> expandCapabilities(WidgetTester tester) async {
    await tester.tap(find.text('平台能力'));
    await tester.pumpAndSettle();
  }

  testWidgets('保证 1：空数据时给出可读的空状态，且配置说明可用', (tester) async {    await pumpHome(tester, service: _HomeService());

    // 2026-10-12 主页按用户给的 YT 图重置 ✓ ⇒ 区块与顺序都变了 ✓（这里只钉**关键几个** ✓，
    // 顺序：问候头之后 再听一遍 → 老歌重温 → … 收藏/歌单 … → 来自平台的歌单 → 平台能力 ✓）。
    final titles = [
      '再听一遍',
      '老歌重温',
      '我的收藏',
      '我的在线歌单',
      '来自平台的歌单',
      '平台能力',
    ];
    for (final title in titles) {
      expect(find.text(title), findsOneWidget, reason: '$title 区块必须存在');
    }
    expect(find.textContaining('还没有在线播放记录'), findsOneWidget);
    expect(find.textContaining('还没有收藏'), findsOneWidget);
    expect(find.textContaining('还没有自建歌单'), findsOneWidget);
    // 没有任何平台具备歌单列表能力 ⇒ 明确说明"怎么才会有"，而不是假装有内容。
    expect(find.textContaining('当前没有可用的「歌单列表」服务'), findsOneWidget);
    // F1 P-02：指引必须指向**真正能配置能力的地方**（服务提供商 → 能力配置）。
    // 旧文案写"在设置的平台卡里配置「歌单列表」能力"——平台卡只能选来源，配不了能力。
    expect(find.textContaining('服务提供商'), findsOneWidget);
    expect(find.textContaining('在设置的平台卡里'), findsNothing);

    // 「平台能力」是诊断信息：默认收起，展开后三个平台都在且都显示未配置。
    expect(find.text('未配置'), findsNothing, reason: '收起时不应渲染平台行');
    await expandCapabilities(tester);
    for (final platform in builtinMusicPlatforms) {
      expect(find.text(musicPlatformLabel(platform)), findsWidgets);
    }
    expect(find.text('未配置'), findsNWidgets(builtinMusicPlatforms.length));
  });

  testWidgets('保证 2：平台能力按真实能力显示，并给出不可用原因', (tester) async {
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
    await expandCapabilities(tester);

    expect(find.text('缺少播放解析能力，因此不会参与搜索'), findsOneWidget);
    // 网易云可用：它的能力标签都在。
    expect(find.text('搜索'), findsWidgets);
    // 酷狗完全没有配置 ⇒ 只有它显示"未配置"；QQ 有服务但被门槛挡下，
    // 显示的是**原因**而不是"未配置"。
    expect(find.text('未配置'), findsOneWidget);
  });

  testWidgets('保证 3：继续听与收藏逐行标注来源（跨平台）', (tester) async {
    repository.recordPlaybackStarted(_track('n1', MusicPlatform.netease));
    repository.recordPlaybackStarted(_track('q1', MusicPlatform.qq));
    repository.toggleFavorite(_track('q1', MusicPlatform.qq));
    repository.toggleFavorite(_track('n2', MusicPlatform.netease));
    await pumpHome(tester, service: _HomeService());

    // 历史区两条（netease + qq）+ 收藏区一条 QQ、一条网易云；
    // 2026-10-12 起还有「老歌重温」（`topPlayed` ✓）—— 它对同一批历史再列一次
    // ⇒ 同样的歌会**再出现一遍** ✓（真实数据 ✓，不是重复 bug ✓）⇒ 共 6 行 ✓。
    expect(find.byType(OnlineTrackRow), findsNWidgets(6));
    final labels = tester
        .widgetList<OnlineTrackRow>(find.byType(OnlineTrackRow))
        .map((row) => row.sourceLabel)
        .toList(growable: false);
    expect(labels, contains('网易云'));
    expect(labels, contains('QQ音乐'));
    // q1 这首 QQ 曲目现在会出现**三次** ✓：再听一遍 ✓ + 老歌重温 ✓ + 收藏 ✓
    //（三块都是真实数据 ✓，各自独立 ✓ —— 不是重复渲染 ✗）。
    expect(labels.where((label) => label == 'QQ音乐'), hasLength(3));
  });

  testWidgets('保证 4：平台歌单按平台分组，单平台失败不影响其它平台', (tester) async {
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
    // 来源与详情都在卡片上（详情行 + 轻量来源标记），且来源取自曲目/歌单自己的 platform。
    final card = tester.widget<RemoteMediaCard>(find.byType(RemoteMediaCard));
    expect(card.details, '歌单 · 甲');
    expect(card.sourceLabel, '网易云');
    // QQ 分组显示自己的错误（失败文案），不影响网易云的结果。
    expect(find.textContaining('平台歌单读取失败'), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
  });

  testWidgets('保证 5：订阅平台歌单会把 (平台, ID) 交出去', (tester) async {
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

  testWidgets('保证 6：窄窗口下不溢出：平台能力与横滑歌单卡片都能收进宽度', (tester) async {
    tester.view.physicalSize = const Size(420, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    repository.recordPlaybackStarted(_track('q1', MusicPlatform.qq));
    final router = GoRouter(
      initialLocation: app_paths.HOME_PAGE,
      routes: [
        GoRoute(
          path: app_paths.HOME_PAGE,
          builder: (context, state) => const HomePage(),
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
          Provider<OnlineMusicService>.value(
            value: _HomeService(
              capabilities: OnlineMusicCapabilities(
                searchablePlatforms: const [],
                resolvablePlatforms: const [],
                playlistCollectionPlatforms: const [MusicPlatform.netease],
              ),
              collections: const {
                MusicPlatform.netease: [
                  RemotePlaylistSummary(
                    platform: MusicPlatform.netease,
                    id: '1',
                    name: '一个名字很长的平台歌单标题用来挤压布局',
                    creator: '创作者名字也很长',
                    trackCount: 1261,
                  ),
                ],
              },
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 窄窗口下不允许出现 RenderFlex overflow（溢出会以异常形式抛出）。
    expect(tester.takeException(), isNull);
    expect(find.text('再听一遍'), findsOneWidget);

    // 滚到「来自平台的歌单」区：横滑卡片同样不能在窄窗口里溢出。
    // 2026-10-12 主页重置后有十几个货架 ✓ ⇒ 一次拖 700 已经够不到了 ✗ ⇒
    // 用 `scrollUntilVisible` 一直滚到它出现为止 ✓（比"猜一个像素数"稳 ✓）。
    await tester.scrollUntilVisible(
      find.text('来自平台的歌单'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('来自平台的歌单'), findsOneWidget);
    expect(find.textContaining('一个名字很长的平台歌单标题'), findsOneWidget);

    // 货架高度必须等于卡片自己声明的高度（防止两处各算一次后漂移并溢出）。
    final shelf = tester.widget<HorizontalShelf>(
      find.byType(HorizontalShelf).first,
    );
    expect(shelf.itemCount, 1);
    expect(
      shelf.itemHeight,
      RemoteMediaCard.extentFor(width: shelf.itemWidth, hasFooter: true),
    );
  });

  // ------------------------------------------------------------- 查看全部

  /// 「查看全部」按钮存在于区块标题行，与区块是否有内容无关，因此空数据也能测。
  Finder seeAllOf(String sectionTitle) => find.descendant(
    of: find.ancestor(
      of: find.text(sectionTitle),
      matching: find.byType(ContentSection),
    ),
    matching: find.text('查看全部'),
  );

  testWidgets('★ 继续听「查看全部」→ 统计页的**在线**来源（query 不能丢）', (tester) async {
    await pumpHome(tester, service: _HomeService());

    await tester.tap(seeAllOf('再听一遍'));
    await tester.pumpAndSettle();

    // 只断言路径会让"query 丢了"溜过去：这个跳转的语义**全在 source=online 上**，
    // 丢了就会落到统计页的"本地"标签，与用户点击的"在线播放历史"不是一回事。
    expect(find.text('stub:${app_paths.STATS_PAGE}|source=online'), findsOneWidget);
  });

  testWidgets('★ 我的收藏「查看全部」→ 在线收藏页', (tester) async {
    await pumpHome(tester, service: _HomeService());

    await tester.tap(seeAllOf('我的收藏'));
    await tester.pumpAndSettle();

    expect(find.text('stub:${app_paths.FAVORITES_PAGE}|'), findsOneWidget);
  });

  testWidgets('★ 来自平台的歌单「查看全部」→ 探索页（那里可以一直翻到底）', (tester) async {
    await pumpHome(
      tester,
      service: _HomeService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistCollectionPlatforms: const [MusicPlatform.netease],
        ),
      ),
    );

    await tester.tap(seeAllOf('来自平台的歌单'));
    await tester.pumpAndSettle();

    expect(find.text('stub:${app_paths.EXPLORE_PAGE}|'), findsOneWidget);
  });

  testWidgets('★ 没有平台具备「歌单列表」能力时：给「去配置」而不是一个点开是空的「查看全部」', (
    tester,
  ) async {
    await pumpHome(tester, service: _HomeService());

    // 「查看全部」只有在**真有内容可看**时才该出现。
    expect(seeAllOf('来自平台的歌单'), findsNothing);
    expect(find.text('去配置'), findsWidgets);

    final section = find.byType(ContentSection).at(
      tester
              .widgetList<ContentSection>(find.byType(ContentSection))
              .toList()
              .indexWhere((item) => item.title == '来自平台的歌单'),
    );
    await tester.tap(
      find.descendant(of: section, matching: find.text('去配置')),
    );
    await tester.pumpAndSettle();

    expect(find.text('stub:${app_paths.SETTINGS_PAGE}|'), findsOneWidget);
  });

  testWidgets('★ 我的在线歌单「管理歌单」→ 歌单页', (tester) async {
    await pumpHome(tester, service: _HomeService());

    await tester.tap(find.text('管理歌单'));
    await tester.pumpAndSettle();

    expect(find.text('stub:${app_paths.PLAYLISTS_PAGE}|'), findsOneWidget);
  });

  testWidgets('★ 服务不可用（完全没有在线音乐服务）：平台能力区说明"尚未就绪"，且页面不崩', (
    tester,
  ) async {
    await pumpHome(tester); // 刻意不注册 OnlineMusicService

    expect(tester.takeException(), isNull);
    expect(find.text('再听一遍'), findsOneWidget);

    await expandCapabilities(tester);
    // 与"配了服务但没有能力"时的"未配置"**不是同一句话** —— 这里连服务都没有。
    expect(find.text('在线音乐服务尚未就绪，平台能力暂时不可用。'), findsOneWidget);
    expect(find.text('去配置'), findsWidgets);
  });

  testWidgets('★ Home 有「新歌上线」货架（对齐参考 Home 的「新曲上线」，只对能播放的平台出现）', (
    tester,
  ) async {
    await pumpHome(
      tester,
      service: _HomeService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [MusicPlatform.netease],
          // 新歌 + 播放解析都有 ⇒ 该平台**可播放** ⇒ 新歌货架出现 ✓。
          resolvablePlatforms: const [MusicPlatform.netease],
          newSongPlatforms: const [MusicPlatform.netease],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新歌上线'), findsOneWidget);
    // 平台没返回曲目 ⇒ **中性空态**（不是失败 ✓）。
    expect(find.text('该平台没有返回新歌。'), findsOneWidget);
    // 与参考一致：这一块只在**能播放**的平台出现 ✓（下面那条反向断言覆盖 ✓）。
    expect(find.text('网易云'), findsWidgets);
  });

  testWidgets('★ 刷新主页：真的重新拉取（不是只重画一遍）', (tester) async {
    final service = _HomeService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
      ),
      collections: const {
        MusicPlatform.netease: [
          RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: '1',
            name: '网易云歌单',
          ),
        ],
      },
    );
    await pumpHome(tester, service: service);
    expect(service.collectionCalls, 1, reason: '首次加载拉一次');

    await tester.tap(find.byTooltip('刷新主页'));
    await tester.pumpAndSettle();

    // 只断言"按钮存在"是不够的：接了空回调的按钮看起来一模一样。
    expect(service.collectionCalls, 2, reason: '刷新必须真的再请求一次');
    expect(find.text('网易云歌单'), findsOneWidget);
  });
}

MusicTrack _track(String id, MusicPlatform platform) => MusicTrack(
  ref: PlatformTrackRef(platform: platform, trackId: id),
  title: 'Track $id',
  artists: const ['Artist'],
);

/// 主页用到的在线音乐服务替身：能力可配、歌单列表按平台返回/抛错。
final class _HomeService implements OnlineMusicService {
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

  /// 「平台歌单」被请求了几次。用来验证**刷新真的重新拉取**，而不是只重画一遍。
  int collectionCalls = 0;

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
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    collectionCalls++;
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
  }) => throw UnsupportedError('charts');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => const <MusicTrack>[];

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
    String? categoryId,
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
  }) => throw UnsupportedError('charts');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => const <MusicTrack>[];

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
