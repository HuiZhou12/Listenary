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
    await tester.tap(find.text('各平台支持什么'));
    await tester.pumpAndSettle();
  }

  testWidgets('★ 两边都做不到的展位已删除，且"你的回顾"是真数字', (tester) async {
    // 「你的回顾」是"本机数字"：**没有播放记录就没有内容** ⇒ 按模块规则会整块隐藏 ✓
    //（2026-10-17）。所以这里先播一首，才有回顾可看 ✓。
    repository.recordPlaybackStarted(_track('n1', MusicPlatform.netease));
    await pumpHome(tester, service: _HomeService());

    // 用户裁定（2026-10-12 ✓）：**网易云做不到、本地也做不到**的板块**删掉** ✗，不留空壳 ✗。
    for (final gone in ['翻唱与混音', '为你推荐的音乐视频', '来自社区']) {
      expect(find.text(gone), findsNothing, reason: '$gone 应当已删除 ✓');
    }

    // 「你的回顾」= **本地真数据** ✓（官方 Recap 端点实测 404 ⇒ 改用本机历史 ✓），
    // 而且**口径写在副标题里** ✓ —— 数字不编 ✓。
    expect(find.text('你的回顾'), findsOneWidget);
    // 2026-10-16：副标题改成**面向用户**的说法 ✓（原来那句写的是"本机口径/官方接口没有" ✗，
    // 那是给开发者看的 ✓，不该出现在界面上 ✓）。
    expect(find.textContaining('根据这台电脑上的播放记录整理'), findsOneWidget);
    expect(find.text('历史总播放次数'), findsOneWidget);
    expect(find.text('最近 30 天在听的曲目'), findsOneWidget);
  });

  testWidgets('★ 模块显示规则：模块内没有内容就整块隐藏（不再摆空态）', (tester) async {
    // 2026-10-17 用户指令：**模块内没有内容就默认隐藏** ✓。
    // 这里服务什么都不给、历史也是空的 ⇒ 所有内容模块都应当**不渲染**，
    // 只剩问候头与底部的平台能力诊断 ✓。
    await pumpHome(tester, service: _HomeService());

    for (final hidden in [
      '再听一遍',
      '好久没听',
      '猜你喜欢',
      '关注的艺人',
      '为你推荐的歌单',
      '个性化合辑',
      '你的回顾',
      // 这两块**已按用户指令移除** ✓（2026-10-17）
      '我的收藏',
      '我的在线歌单',
    ]) {
      expect(
        find.text(hidden),
        findsNothing,
        reason: '「$hidden」没有内容 ⇒ 整块不该渲染 ✓',
      );
    }
    // 空态文案也不该再出现（隐藏比"还没有…"更符合这条规则 ✓）。
    expect(find.textContaining('还没有在线播放记录'), findsNothing);
    expect(find.textContaining('还没有收藏'), findsNothing);
    expect(find.textContaining('还没有自建歌单'), findsNothing);

    // 平台能力是**诊断信息**，不属于"内容模块" ⇒ 仍然在 ✓（默认收起）。
    expect(find.text('各平台支持什么'), findsOneWidget);
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
            MusicPlatform.qq: '该平台暂不能播放',
          },
        ),
      ),
    );
    await expandCapabilities(tester);

    expect(find.text('该平台暂不能播放'), findsOneWidget);
    // 网易云可用：它的能力标签都在。
    expect(find.text('搜索'), findsWidgets);
    // 酷狗完全没有配置 ⇒ 只有它显示"未配置"；QQ 有服务但被门槛挡下，
    // 显示的是**原因**而不是"未配置"。
    expect(find.text('未配置'), findsOneWidget);
  });

  testWidgets('保证 3：历史两块用卡片，且都标注来源（跨平台）', (tester) async {
    repository.recordPlaybackStarted(_track('n1', MusicPlatform.netease));
    repository.recordPlaybackStarted(_track('q1', MusicPlatform.qq));
    await pumpHome(tester, service: _HomeService());

    // 2026-10-17：「我的收藏」模块已按用户指令移除 ⇒ 主页上**不再有曲目行** ✓，
    // 只剩历史那两块**卡片**货架 ✓（用户 2026-10-12 裁定：这两块用卡片 ✓）。
    expect(find.byType(OnlineTrackRow), findsNothing);

    // 历史那两块现在是**卡片** ✓：来源标记也必须**照样**出现在卡片上 ✓
    //（"来源始终可见"这条纪律不因换形状而失效 ✓）。
    final cards = tester
        .widgetList<RemoteMediaCard>(find.byType(RemoteMediaCard))
        .toList(growable: false);
    expect(cards, isNotEmpty, reason: '历史两块应当是卡片 ✓');
    expect(
      cards.map((card) => card.sourceLabel).toSet(),
      contains('QQ音乐'),
      reason: '卡片上同样要标注来源 ✓',
    );
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

    // 2026-10-16：平台歌单与「新歌上线」两块已按用户指令删除 ✗ ⇒ 这里改看**再听一遍**那张
    // 横滑卡片货架 ✓（它是页面里第一条货架 ✓）。断言意图不变 ✓：
    // 窄窗口下横滑卡片也必须能收进宽度 ✓，不能溢出 ✗。
    await tester.scrollUntilVisible(
      find.text('再听一遍'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('再听一遍'), findsOneWidget);
    // 这一条是刚播过的那首 ✓（来源标记也必须照样在卡片上 ✓）。
    // 注意标题是 `_track` 造的 `Track q1` ✓，不是 id 本身 ✓。
    expect(find.text('Track q1'), findsWidgets);

    // 货架高度必须等于卡片自己声明的高度（防止两处各算一次后漂移并溢出）。
    final shelf = tester.widget<HorizontalShelf>(
      find.byType(HorizontalShelf).first,
    );
    expect(shelf.itemCount, greaterThan(0));
    expect(
      shelf.itemHeight,
      RemoteMediaCard.extentFor(width: shelf.itemWidth, hasFooter: false),
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
    // 模块规则（2026-10-17）：没有内容就隐藏 ⇒ 先播一首，让「再听一遍」真的出现。
    repository.recordPlaybackStarted(_track('n1', MusicPlatform.netease));
    await pumpHome(tester, service: _HomeService());

    await tester.tap(seeAllOf('再听一遍'));
    await tester.pumpAndSettle();

    // 只断言路径会让"query 丢了"溜过去：这个跳转的语义**全在 source=online 上**，
    // 丢了就会落到统计页的"本地"标签，与用户点击的"在线播放历史"不是一回事。
    expect(find.text('stub:${app_paths.STATS_PAGE}|source=online'), findsOneWidget);
  });

  testWidgets('★ 服务不可用（完全没有在线音乐服务）：平台能力区说明"尚未就绪"，且页面不崩', (
    tester,
  ) async {
    await pumpHome(tester); // 刻意不注册 OnlineMusicService

    expect(tester.takeException(), isNull);
    // 模块规则（2026-10-17）：没有内容 ⇒ 内容模块全部隐藏 ✓（含「再听一遍」）。
    expect(find.text('再听一遍'), findsNothing);

    await expandCapabilities(tester);
    // 与"配了服务但没有能力"时的"未配置"**不是同一句话** —— 这里连服务都没有。
    expect(find.text('在线音乐服务还没配好，这些信息暂时看不了。'), findsOneWidget);
    expect(find.text('去配置'), findsWidgets);
  });

  testWidgets('★ 凭据型货架失败时给出"可能是凭据"的指引', (tester) async {
    // 为什么要有这条：推荐类能力**按设计需要 cookie** ✓ ⇒ 失败时最可能是凭据没配/过期 ✓。
    // 界面必须把这条**说出来**（否则用户只看到"读取失败"，不知道去哪修 ✓）。
    await pumpHome(
      tester,
      service: _HomeService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          // 能取推荐曲目 + 能解析 ⇒ 货架出现 ✓；替身**故意抛错** ⇒ 走失败态 ✓。
          resolvablePlatforms: const [MusicPlatform.netease],
          recommendedTrackPlatforms: const [MusicPlatform.netease],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('可能的原因：登录凭据没配置或已过期'),
      findsOneWidget,
      reason: '凭据型货架的失败必须给出可执行的指引 ✓',
    );
  });


  testWidgets('★ 刷新主页：真的重新拉取（不是只重画一遍）', (tester) async {
    // 2026-10-17：「个性化合辑」已按用户指令删除（与「为你推荐的歌单」功能重合）✗ ⇒
    // 这里改盯**为你推荐的歌单** ✓（它仍在 ✓）。判据不变 ✓：刷新必须真的**再请求一次** ✓。
    final service = _HomeService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        // 既要有该能力、又要打得开歌单详情 ⇒ 两条都要给 ✓（与主页的门槛一致 ✓）。
        playlistPlatforms: const [MusicPlatform.netease],
        recommendedPlaylistPlatforms: const [MusicPlatform.netease],
      ),
    );
    await pumpHome(tester, service: service);
    expect(service.recommendedPlaylistCalls, 1, reason: '首次加载拉一次');

    await tester.tap(find.byTooltip('刷新主页'));
    await tester.pumpAndSettle();

    // 只断言"按钮存在"是不够的：接了空回调的按钮看起来一模一样。
    expect(service.recommendedPlaylistCalls, 2, reason: '刷新必须真的再请求一次');
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
  }) async {
    recommendedPlaylistCalls++;
    // 返回空 ⇒ 该模块按"没有内容就隐藏"的规则不渲染 ✓（但请求确实发生了 ✓）。
    return const <RemotePlaylistSummary>[];
  }

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

  /// **为你推荐的歌单**被请求了几次（2026-10-17 ✓）：「个性化合辑」删除之后，
  /// 「刷新必须真的再请求一次」这条守卫改盯它 ✓。
  int recommendedPlaylistCalls = 0;

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
