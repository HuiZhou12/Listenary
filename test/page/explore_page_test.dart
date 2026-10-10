import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/explore_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 探索页：**按能力分区、不按平台分区**；不支持该能力的平台不出现（而不是渲染成空）；
/// 单平台失败不影响其它平台；订阅必须把 `(platform, id)` 原样交出去。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late OnlinePlaylistController subscriptions;
  late PersonalOnlinePlaylistController personal;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    subscriptions = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: _ExploreService(),
    );
    // 曲目行会读收藏状态（OnlineTrackEntry），因此测试也要提供它。
    personal = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
  });

  tearDown(() {
    subscriptions.dispose();
    personal.dispose();
    database.dispose();
  });

  Future<void> pumpExplore(
    WidgetTester tester, {
    OnlineMusicService? service,
    Size surface = const Size(1200, 2000),
    int? collectionLimit,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: app_paths.EXPLORE_PAGE,
      routes: [
        GoRoute(
          path: app_paths.EXPLORE_PAGE,
          builder: (context, state) =>
              ExplorePage(collectionLimit: collectionLimit ?? 24),
        ),
        for (final path in [
          app_paths.ONLINE_MUSIC_PAGE,
          app_paths.SETTINGS_PAGE,
          app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
          app_paths.EXPLORE_CHART_LIST_PAGE,
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
          ChangeNotifierProvider<OnlinePlaylistController>.value(
            value: subscriptions,
          ),
          ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
            value: personal,
          ),
          if (service != null)
            Provider<OnlineMusicService>.value(value: service),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有任何平台支持歌单列表时，说明怎么才会有，而不是假装有内容', (tester) async {
    await pumpExplore(tester, service: _ExploreService());

    expect(find.text('探索'), findsOneWidget);
    expect(find.text('平台歌单'), findsOneWidget);
    expect(find.textContaining('当前没有可用的「歌单列表」服务'), findsOneWidget);
    // F1 P-02：指引指向真正能配置能力的地方（服务提供商 → 能力配置），不是平台卡。
    expect(find.textContaining('服务提供商'), findsOneWidget);
    expect(find.textContaining('在设置的平台卡里'), findsNothing);
    // 平台能力是诊断信息：默认收起。
    expect(find.text('平台能力'), findsOneWidget);
    expect(find.text('未配置'), findsNothing);

    await tester.tap(find.text('平台能力'));
    await tester.pumpAndSettle();
    expect(find.text('未配置'), findsNWidgets(builtinMusicPlatforms.length));
  });

  testWidgets('能力驱动：只列出具备该能力的平台', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          // 只有网易云具备「歌单列表」能力 ⇒ 酷狗/QQ 不出现分区。
          playlistCollectionPlatforms: const [MusicPlatform.netease],
        ),
        collections: const {
          MusicPlatform.netease: [
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '1',
              name: '网易云歌单',
              creator: '甲',
              trackCount: 20,
            ),
          ],
        },
      ),
    );

    expect(find.text('网易云歌单'), findsOneWidget);
    final card = tester.widget<RemoteMediaCard>(find.byType(RemoteMediaCard));
    expect(card.sourceLabel, '网易云');
    expect(card.details, '甲 · 20 首');
    // QQ 与酷狗没有该能力 ⇒ 既不出现分区，也不出现"空"文案。
    expect(find.text('该平台没有返回歌单。'), findsNothing);
    expect(find.text('QQ音乐'), findsNothing);
  });

  testWidgets('单平台失败不影响其它平台，且失败与空文案不同', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
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
            ),
          ],
        },
        failingCollections: const {MusicPlatform.qq},
      ),
    );

    // 网易云照常显示。
    expect(find.text('网易云歌单'), findsOneWidget);
    // QQ 显示的是**失败**文案，而不是"该平台没有返回歌单"。
    expect(find.textContaining('平台歌单读取失败'), findsOneWidget);
    expect(find.text('该平台没有返回歌单。'), findsNothing);
    // 失败分区有重试入口。
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('订阅平台歌单会把 (平台, ID) 交出去', (tester) async {
    final playlistService = _RecordingPlaylistService();
    subscriptions.dispose();
    subscriptions = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: playlistService,
    );

    await pumpExplore(
      tester,
      service: _ExploreService(
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
      ),
    );

    await tester.tap(find.text('订阅'));
    await tester.pumpAndSettle();

    expect(playlistService.requestedPlaylists, hasLength(1));
    expect(
      playlistService.requestedPlaylists.single.platform,
      MusicPlatform.qq,
    );
    expect(playlistService.requestedPlaylists.single.id, '7729596131');
  });

  testWidgets('窄窗口不溢出，且货架高度等于卡片声明高度', (tester) async {
    await pumpExplore(
      tester,
      surface: const Size(420, 900),
      service: _ExploreService(
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
    );

    expect(tester.takeException(), isNull);
    final shelf = tester.widget<HorizontalShelf>(
      find.byType(HorizontalShelf).first,
    );
    expect(
      shelf.itemHeight,
      RemoteMediaCard.extentFor(width: shelf.itemWidth, hasFooter: true),
    );
    expect(shelf.itemWidth, 124, reason: '窄窗口用更小的卡片宽度');
  });

  // ------------------------------------------------------------------ 榜单

  testWidgets('榜单货架：对"点得开"的平台出现，并显示更新节奏', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          // 榜单 + 歌单详情都有 ⇒ 榜单点得开。
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
          ],
        },
      ),
    );

    expect(find.text('榜单'), findsOneWidget);
    expect(find.text('飙升榜'), findsOneWidget);
    // 更新节奏是榜单区别于普通歌单的信息，必须在卡片上出现。
    expect(find.text('刚刚更新 · 98 首'), findsOneWidget);
    expect(find.text('查看全部'), findsOneWidget);
  });

  testWidgets('只列榜、取不到歌单详情的平台：整块榜单不出现（防死链）', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          // 只有榜单、没有歌单详情 ⇒ 点开必然失败，因此整块不出现。
          chartPlatforms: const [MusicPlatform.qq],
        ),
        charts: const {
          MusicPlatform.qq: [
            RemotePlaylistSummary(
              platform: MusicPlatform.qq,
              id: '4',
              name: '巅峰榜',
            ),
          ],
        },
      ),
    );

    expect(find.text('榜单'), findsNothing);
    expect(find.text('巅峰榜'), findsNothing);
  });

  testWidgets('榜单：单平台失败隔离，且失败与空文案不同', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistPlatforms: const [MusicPlatform.netease, MusicPlatform.qq],
          chartPlatforms: const [MusicPlatform.netease, MusicPlatform.qq],
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
        failingCharts: const {MusicPlatform.qq},
      ),
    );

    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.textContaining('QQ音乐 榜单读取失败'), findsOneWidget);
    // 失败 ≠ 空：不允许同时显示"没有返回榜单"。
    expect(find.text('该平台没有返回榜单。'), findsNothing);
  });

  testWidgets('榜单货架超出预览条数时注明总数，且「查看全部」可跳转', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistPlatforms: const [MusicPlatform.netease],
          chartPlatforms: const [MusicPlatform.netease],
        ),
        charts: {
          MusicPlatform.netease: [
            for (var index = 0; index < 20; index++)
              RemotePlaylistSummary(
                platform: MusicPlatform.netease,
                id: '$index',
                name: '榜单$index',
              ),
          ],
        },
      ),
    );

    // 货架只露前 12 条，但注明真实总数（真实服务一次返回全部时不能假装分页）。
    expect(find.text('网易云 · 20 个榜单'), findsOneWidget);
    // 横滑货架是懒构建的：只断言**首项**存在，不断言第 12 项（它在视口外，本就不该被构建）。
    expect(find.text('榜单0'), findsOneWidget);

    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(
      find.text('stub:${app_paths.EXPLORE_CHART_LIST_PAGE}'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------- 歌单分类

  testWidgets('分类 chip 墙：对"能按分类取歌单"的平台出现，并显示分类与数量', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          // 分类索引 + 歌单列表都有 ⇒ 分类浏览真的可用。
          playlistCollectionPlatforms: const [MusicPlatform.netease],
          playlistCategoryPlatforms: const [MusicPlatform.netease],
        ),
        categories: const {
          MusicPlatform.netease: [
            RemotePlaylistCategory(
              platform: MusicPlatform.netease,
              id: '华语',
              name: '华语',
              count: 1945,
            ),
            RemotePlaylistCategory(
              platform: MusicPlatform.netease,
              id: '摇滚',
              name: '摇滚',
            ),
          ],
        },
      ),
    );

    expect(find.text('歌单分类'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('华语 · 1945'), findsOneWidget);
    // 没有数量的分类只显示名字，不编造数字。
    expect(find.text('摇滚'), findsOneWidget);
  });

  testWidgets('点分类 chip 只请求该分类，并筛选该平台的歌单货架', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
        playlistCategoryPlatforms: const [MusicPlatform.netease],
      ),
      collections: const {
        MusicPlatform.netease: [
          RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: '1',
            name: '全部歌单',
          ),
        ],
      },
      categories: const {
        MusicPlatform.netease: [
          RemotePlaylistCategory(
            platform: MusicPlatform.netease,
            id: '华语',
            name: '华语',
          ),
        ],
      },
      categoryCollections: const {
        '华语': [
          RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: '9',
            name: '华语歌单',
          ),
        ],
      },
    );
    await pumpExplore(tester, service: service);

    // 初次加载只请求"全部"（categoryId == null）。
    expect(service.collectionCalls, hasLength(1));
    expect(service.collectionCalls.single.categoryId, isNull);
    expect(find.text('全部歌单'), findsOneWidget);

    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();

    // 第二次请求带上该分类，且货架换成分类下的歌单。
    expect(service.collectionCalls, hasLength(2));
    expect(service.collectionCalls.last.categoryId, '华语');
    expect(find.text('华语歌单'), findsOneWidget);
    expect(find.text('全部歌单'), findsNothing);
    // 小标题写明筛选状态，否则用户不知道这排被筛过。
    expect(find.text('网易云 · 华语'), findsOneWidget);
  });

  testWidgets('再点同一个分类 = 取消筛选，回到"全部"', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
        playlistCategoryPlatforms: const [MusicPlatform.netease],
      ),
      collections: const {
        MusicPlatform.netease: [
          RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: '1',
            name: '全部歌单',
          ),
        ],
      },
      categories: const {
        MusicPlatform.netease: [
          RemotePlaylistCategory(
            platform: MusicPlatform.netease,
            id: '华语',
            name: '华语',
          ),
        ],
      },
      categoryCollections: const {'华语': []},
    );
    await pumpExplore(tester, service: service);

    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    expect(find.text('全部歌单'), findsNothing);

    // 取消筛选：恢复"全部"，且**不会重复请求**已经取过的"全部"。
    await tester.tap(find.text('取消筛选'));
    await tester.pumpAndSettle();
    expect(find.text('全部歌单'), findsOneWidget);
    expect(service.collectionCalls, hasLength(2));
  });

  testWidgets('只支持分类、不支持歌单列表的平台：整块 chip 墙不出现（防点不动的 chip）', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          // 只有分类索引 ⇒ chip 点不动，整块不出现。
          playlistCategoryPlatforms: const [MusicPlatform.qq],
        ),
        categories: const {
          MusicPlatform.qq: [
            RemotePlaylistCategory(
              platform: MusicPlatform.qq,
              id: '1',
              name: '流行',
            ),
          ],
        },
      ),
    );

    expect(find.text('歌单分类'), findsNothing);
    expect(find.text('流行'), findsNothing);
  });

  testWidgets('分类读取失败：显示失败并可重试，不影响平台歌单', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistCollectionPlatforms: const [MusicPlatform.netease],
          playlistCategoryPlatforms: const [MusicPlatform.netease],
        ),
        collections: const {
          MusicPlatform.netease: [
            RemotePlaylistSummary(
              platform: MusicPlatform.netease,
              id: '1',
              name: '全部歌单',
            ),
          ],
        },
        failingCategories: const {MusicPlatform.netease},
      ),
    );

    // 分类失败显示为**失败**（不是"没有分类"），且平台歌单照常显示。
    expect(find.textContaining('网易云 分类读取失败'), findsOneWidget);
    expect(find.text('该平台没有返回歌单分类。'), findsNothing);
    expect(find.text('全部歌单'), findsOneWidget);
  });

  // ------------------------------------------------------------------ 新歌

  testWidgets('新歌：只对能播放的平台出现，行上标注来源且可点', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          // 新歌 + 播放解析都有 ⇒ 可播放。
          resolvablePlatforms: const [MusicPlatform.netease],
          newSongPlatforms: const [MusicPlatform.netease],
        ),
        newSongs: {
          MusicPlatform.netease: [
            MusicTrack(
              ref: const PlatformTrackRef(
                platform: MusicPlatform.netease,
                trackId: 'n1',
              ),
              title: '新歌一',
              artists: ['甲'],
              album: '专辑一',
            ),
            MusicTrack(
              ref: const PlatformTrackRef(
                platform: MusicPlatform.netease,
                trackId: 'n2',
              ),
              title: '新歌二',
              artists: ['乙'],
            ),
          ],
        },
      ),
    );

    expect(find.text('新歌'), findsOneWidget);
    expect(find.text('新歌一'), findsOneWidget);
    expect(find.text('新歌二'), findsOneWidget);

    final rows = tester
        .widgetList<OnlineTrackRow>(find.byType(OnlineTrackRow))
        .toList(growable: false);
    expect(rows, hasLength(2));
    // 来源身份：每一行都标出所属平台。
    expect(rows.map((row) => row.sourceLabel), everyElement('网易云'));
    // 副标题 = 艺人 · 专辑（沿用既有组装）。
    expect(rows.first.details, '甲 · 专辑一');
    // 可播放 ⇒ 挂上了起播回调（起播链路本身由 online_search_launcher 的测试覆盖）。
    expect(rows.every((row) => row.onTap != null), isTrue);
  });

  testWidgets('新歌：只有新歌、没有播放解析的平台整块不出现（点不响比不显示更糟）', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          // 只有新歌、不能播放 ⇒ 整块不出现。
          resolvablePlatforms: const [],
          newSongPlatforms: const [MusicPlatform.qq],
        ),
        newSongs: {
          MusicPlatform.qq: [
            MusicTrack(
              ref: const PlatformTrackRef(platform: MusicPlatform.qq, trackId: 'q1'),
              title: 'QQ 新歌',
              artists: ['丙'],
            ),
          ],
        },
      ),
    );

    expect(find.text('新歌'), findsNothing);
    expect(find.text('QQ 新歌'), findsNothing);
  });

  testWidgets('新歌：单平台失败隔离，且失败与空文案不同', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [MusicPlatform.netease, MusicPlatform.qq],
          newSongPlatforms: const [MusicPlatform.netease, MusicPlatform.qq],
        ),
        newSongs: {
          MusicPlatform.netease: [
            MusicTrack(
              ref: const PlatformTrackRef(
                platform: MusicPlatform.netease,
                trackId: 'n1',
              ),
              title: '网易云新歌',
              artists: ['甲'],
            ),
          ],
        },
        failingNewSongs: const {MusicPlatform.qq},
      ),
    );

    expect(find.text('网易云新歌'), findsOneWidget);
    expect(find.textContaining('QQ音乐 新歌读取失败'), findsOneWidget);
    // 失败 ≠ 空：不允许同时显示"没有返回新歌"。
    expect(find.text('该平台没有返回新歌。'), findsNothing);
    // 失败有重试入口。
    expect(find.text('重试'), findsWidgets);
  });

  // ------------------------------------------------------------------ 收口

  /// 同时开启**全部**发现类能力：四个区块（榜单 / 新歌 / 分类 / 平台歌单）都出现。
  /// 既有测试每轮只开一种能力，因此"四个区块同时在场"这件事此前没有被验证过。
  _ExploreService allCapabilitiesService() => _ExploreService(
    capabilities: OnlineMusicCapabilities(
      // 搜索门槛也要满足，否则这个 service 不构成"全能力"的替身。
      searchablePlatforms: const [MusicPlatform.netease],
      resolvablePlatforms: const [MusicPlatform.netease],
      playlistPlatforms: const [MusicPlatform.netease],
      playlistCollectionPlatforms: const [MusicPlatform.netease],
      playlistCategoryPlatforms: const [MusicPlatform.netease],
      chartPlatforms: const [MusicPlatform.netease],
      newSongPlatforms: const [MusicPlatform.netease],
    ),
    collections: const {
      MusicPlatform.netease: [
        RemotePlaylistSummary(
          platform: MusicPlatform.netease,
          id: 'p1',
          name: '平台歌单一',
          creator: '甲',
          trackCount: 12,
        ),
      ],
    },
    charts: const {
      MusicPlatform.netease: [
        RemotePlaylistSummary(
          platform: MusicPlatform.netease,
          id: '19723756',
          name: '飙升榜',
          trackCount: 98,
          updateFrequency: '刚刚更新',
        ),
      ],
    },
    categories: const {
      MusicPlatform.netease: [
        // 故意放超长分类名：chip 墙要在窄窗口里换行而不是溢出。
        RemotePlaylistCategory(
          platform: MusicPlatform.netease,
          id: '一个非常非常长的分类名字用来挤压chip墙的布局',
          name: '一个非常非常长的分类名字用来挤压chip墙的布局',
          count: 12345,
        ),
        RemotePlaylistCategory(
          platform: MusicPlatform.netease,
          id: '华语',
          name: '华语',
        ),
      ],
    },
    newSongs: {
      MusicPlatform.netease: [
        MusicTrack(
          ref: const PlatformTrackRef(
            platform: MusicPlatform.netease,
            trackId: 'n1',
          ),
          title: '一个非常非常长的新歌标题用来挤压行布局看看会不会溢出',
          artists: const ['一个同样很长的艺人名字'],
          album: '一张同样很长的专辑名字',
        ),
      ],
    },
  );

  testWidgets('全能力开启：四个发现区块同时出现', (tester) async {
    await pumpExplore(tester, service: allCapabilitiesService());

    for (final title in ['榜单', '新歌', '歌单分类', '平台歌单']) {
      expect(find.text(title), findsOneWidget, reason: '$title 区块必须出现');
    }
    expect(find.text('平台能力'), findsOneWidget);
  });

  testWidgets('★ 全能力 + 窄窗口：四个区块都不溢出（含超长分类名与超长标题）', (tester) async {
    await pumpExplore(
      tester,
      surface: const Size(420, 900),
      service: allCapabilitiesService(),
    );

    expect(tester.takeException(), isNull);

    // 逐段滚到底：横滑货架、chip 墙、曲目行都必须能收进 420 宽。
    for (var step = 0; step < 5; step++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: '第 ${step + 1} 次滚动后出现溢出',
      );
    }
  });

  // ------------------------------------------------------------------ 分页

  /// 造 N 个平台歌单。
  List<RemotePlaylistSummary> playlists(int count) => [
    for (var index = 0; index < count; index++)
      RemotePlaylistSummary(
        platform: MusicPlatform.netease,
        id: 'p$index',
        name: '歌单$index',
      ),
  ];

  testWidgets('★ 取满一页时给「加载更多」，点它按 offset 追加而不是替换', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
      ),
      collections: {MusicPlatform.netease: playlists(5)},
    );
    // 每页 2 条 ⇒ 第一页取满 ⇒ 应该还有更多。
    await pumpExplore(tester, service: service, collectionLimit: 2);

    expect(service.collectionCalls.single.offset, 0);
    expect(find.text('歌单0'), findsOneWidget);
    expect(find.text('歌单2'), findsNothing);
    expect(find.text('加载更多'), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    // 第二次请求从**已加载条数**开始，而不是又从 0 开始。
    expect(service.collectionCalls, hasLength(2));
    expect(service.collectionCalls.last.offset, 2);
    // 追加：原来的还在，新的一页接在后面。
    expect(find.text('歌单0'), findsOneWidget);
    expect(find.text('歌单2'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget, reason: '第二页也取满了');

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    expect(service.collectionCalls.last.offset, 4);
    // 第三页只有 1 条（不满）⇒ 没有更多了。
    expect(find.text('加载更多'), findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('★ 一页没取满时直接说「没有更多了」，不给假的加载更多', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistCollectionPlatforms: const [MusicPlatform.netease],
        ),
        collections: {MusicPlatform.netease: playlists(1)},
      ),
      collectionLimit: 2,
    );

    expect(find.text('加载更多'), findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('一张都没有时不渲染分页区（空态已经说明了一切）', (tester) async {
    await pumpExplore(
      tester,
      service: _ExploreService(
        capabilities: OnlineMusicCapabilities(
          searchablePlatforms: const [],
          resolvablePlatforms: const [],
          playlistCollectionPlatforms: const [MusicPlatform.netease],
        ),
      ),
      collectionLimit: 2,
    );

    expect(find.text('该平台没有返回歌单。'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(find.text('没有更多了'), findsNothing);
  });

  testWidgets('★ 「加载更多」失败时：已加载的内容**不被盖掉**，错误显示在分页区', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
      ),
      collections: {MusicPlatform.netease: playlists(2)},
      // 传一个**可变**集合：下面要让它翻页时才失败（首屏必须是成功的）。
      failingCollections: <MusicPlatform>{},
    );
    await pumpExplore(tester, service: service, collectionLimit: 2);
    expect(find.text('歌单0'), findsOneWidget);

    service.failingCollections.add(MusicPlatform.netease);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    // 关键：已经看到的歌单还在（不能因为翻页失败把列表整个换成错误页）。
    expect(find.text('歌单0'), findsOneWidget);
    expect(find.textContaining('平台歌单读取失败'), findsOneWidget);
    expect(find.text('重试'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('★ 配了忽略 offset 的接口时：不出现重复项，且收敛为「没有更多了」', (tester) async {
    // 分页路径是**用户在设置里填的**；填了一个忽略 offset 的接口（例如 `/personalized`）
    // 就会每次都返回同一批。没有去重的话：看到重复条目 + 按钮永远点得动。
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
      ),
      collections: {MusicPlatform.netease: playlists(2)},
      ignoreOffset: true,
    );
    await pumpExplore(tester, service: service, collectionLimit: 2);

    expect(find.byType(RemoteMediaCard), findsNWidgets(2));
    expect(find.text('加载更多'), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    // 仍然只有两个（没有把同一批再追加一遍）。
    expect(find.byType(RemoteMediaCard), findsNWidgets(2));
    // 一条新的都没有 ⇒ 不再假装还有更多。
    expect(find.text('加载更多'), findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------------ 刷新

  testWidgets('★ 刷新：回到第一页，并重新从 offset=0 拉取（分页状态被重置）', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
      ),
      collections: {MusicPlatform.netease: playlists(5)},
    );
    await pumpExplore(tester, service: service, collectionLimit: 2);

    // 先翻一页：offset=2，第 3 条出现。
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(service.collectionCalls.last.offset, 2);
    expect(find.text('歌单2'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();

    // 刷新是"重新开始"，不是"再追加一页"：offset 回到 0，多出来的页消失。
    expect(service.collectionCalls.last.offset, 0);
    expect(find.text('歌单2'), findsNothing);
    expect(find.text('歌单0'), findsOneWidget);
    // 第一页又取满了 ⇒ 还能继续翻。
    expect(find.text('加载更多'), findsOneWidget);
  });

  testWidgets('★ 刷新：保留当前分类筛选，并按该分类重新拉取', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
        playlistCategoryPlatforms: const [MusicPlatform.netease],
      ),
      collections: const {
        MusicPlatform.netease: [
          RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: '1',
            name: '全部歌单',
          ),
        ],
      },
      categories: const {
        MusicPlatform.netease: [
          RemotePlaylistCategory(
            platform: MusicPlatform.netease,
            id: '华语',
            name: '华语',
          ),
        ],
      },
      categoryCollections: const {
        '华语': [
          RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: '9',
            name: '华语歌单',
          ),
        ],
      },
    );
    await pumpExplore(tester, service: service);

    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    expect(service.collectionCalls.last.categoryId, '华语');

    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();

    // 刷新不该把用户选的筛选悄悄丢掉。
    expect(service.collectionCalls.last.categoryId, '华语');
    expect(find.text('华语歌单'), findsOneWidget);
    expect(find.text('网易云 · 华语'), findsOneWidget);
  });

  testWidgets('★ 刷新能从失败中恢复（失败提示不再挂着）', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
      ),
      collections: {MusicPlatform.netease: playlists(1)},
      failingCollections: <MusicPlatform>{MusicPlatform.netease},
    );
    await pumpExplore(tester, service: service, collectionLimit: 2);

    expect(find.textContaining('平台歌单读取失败'), findsOneWidget);

    // 服务恢复后刷新：内容出现，失败提示消失。
    service.failingCollections.remove(MusicPlatform.netease);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('平台歌单读取失败'), findsNothing);
    expect(find.text('歌单0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------------ 服务不可用

  testWidgets('★ 服务不可用（完全没有在线音乐服务）：说明就绪条件，且不假装有内容', (tester) async {
    // 验收标准把"**服务不可用**"与"空""部分平台失败"并列为必须区分的状态。
    // 前几种都有测试，唯独"压根没有服务"这一种此前没人跑到过 —— 它走的是
    // `context.read<OnlineMusicService?>()` 拿到 null 的那条路（页面里确实都用了可空读法）。
    await pumpExplore(tester); // 刻意不注册 OnlineMusicService

    expect(tester.takeException(), isNull);
    expect(find.text('探索'), findsOneWidget);
    // 与"有服务但没配能力"共用同一句说明；关键是**不能假装有内容**。
    expect(find.textContaining('没有可用的「歌单列表」服务'), findsOneWidget);
    expect(find.byType(RemoteMediaCard), findsNothing);

    // 平台能力是诊断信息：展开后要明确说"服务尚未就绪"，而不是显示一片空白。
    await tester.tap(find.text('平台能力'));
    await tester.pumpAndSettle();
    expect(find.text('在线音乐服务尚未就绪，平台能力暂时不可用。'), findsOneWidget);
  });

  // ------------------------------------------------------------------ 订阅失败

  testWidgets('★ 订阅失败（配置指向打不开的 id）：给错误提示，且**不跳转**', (tester) async {
    // 为什么值得单独测：**配置是自由的** —— 用户可以给某个平台配「歌单列表」，
    // 而它的 id 其实打不开（实测 QQ 的榜单 topId 就不能当歌单 id 用）。
    // 派生规则是**平台粒度**的，挡不住这种"平台没问题、但这条 id 不行"的情况。
    // 真正的安全网是：**订阅失败要给明确提示，并且不要跳到空详情页**。
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
        playlistPlatforms: const [MusicPlatform.netease],
      ),
      collections: {
        MusicPlatform.netease: [
          const RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: 'unopenable',
            name: '打不开的歌单',
          ),
        ],
      },
      playlistFailure: const OnlineMusicException(
        kind: OnlineMusicErrorKind.unavailable,
        safeMessage: '测试用：该歌单打不开',
      ),
    );

    // 这条测试要断言 Toast，因此**必须接上应用根部的两个全局 key**
    // （否则 `showTextOnSnackBar` 静默不渲染，"有提示"永远测不出来）。
    //
    // 另外：`_subscribe` 读的是**当前树里的** `OnlinePlaylistController`，
    // 所以要给它一个**用上面那个失败服务**构造的控制器 —— 用共享的那个等于没测失败路径。
    final failingSubscriptions = OnlinePlaylistController(
      repository: Future.value(repository),
      service: service,
    );
    addTearDown(failingSubscriptions.dispose);

    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      // GoRouter 自己带 navigatorKey —— 把**应用根部那个全局 key** 交给它，
      // 这样 `showTextOnSnackBar` 里的 `routerKey.currentState?.overlay` 才有值
      // （`MaterialApp.router` 没有 `navigatorKey` 参数，那会与 router 冲突）。
      navigatorKey: routerKey,
      initialLocation: app_paths.EXPLORE_PAGE,
      routes: [
        GoRoute(
          path: app_paths.EXPLORE_PAGE,
          builder: (context, state) => const ExplorePage(collectionLimit: 24),
        ),
        for (final path in [
          app_paths.ONLINE_MUSIC_PAGE,
          app_paths.SETTINGS_PAGE,
          app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
          app_paths.EXPLORE_CHART_LIST_PAGE,
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
          ChangeNotifierProvider<OnlinePlaylistController>.value(
            value: failingSubscriptions,
          ),
          ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
            value: personal,
          ),
          Provider<OnlineMusicService>.value(value: service),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: scaffoldMessengerKey,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('打不开的歌单'), findsOneWidget);

    await tester.tap(find.text('订阅'));
    await tester.pumpAndSettle();

    // 关键一：**不许跳进一个空详情页**（那才是死路）。
    expect(
      find.text('stub:${app_paths.ONLINE_PLAYLIST_DETAIL_PAGE}'),
      findsNothing,
      reason: '订阅失败不能跳转，否则用户会落在一个打不开的详情页上',
    );
    // 关键二：留在探索页，并且**必须给提示**（不能"点了没反应"）。
    expect(find.text('打不开的歌单'), findsOneWidget);
    // 断言**具体那条错误文案**（不能用 '打不开' 这种子串 —— 卡片名里也有这三个字，
    // 那样断的是卡片而不是提示）。
    expect(find.text('测试用：该歌单打不开'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Toast 的自动消失 Timer 要跑完（否则框架报 pending timer）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('★ 订阅成功则**会**跳进详情页（上一条"不跳转"的正向对照）', (tester) async {
    final service = _ExploreService(
      capabilities: OnlineMusicCapabilities(
        searchablePlatforms: const [],
        resolvablePlatforms: const [],
        playlistCollectionPlatforms: const [MusicPlatform.netease],
        playlistPlatforms: const [MusicPlatform.netease],
      ),
      collections: {
        MusicPlatform.netease: [
          const RemotePlaylistSummary(
            platform: MusicPlatform.netease,
            id: '601',
            name: '能打开的歌单',
          ),
        ],
      },
    );
    final okSubscriptions = OnlinePlaylistController(
      repository: Future.value(repository),
      service: service,
    );
    addTearDown(okSubscriptions.dispose);

    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: app_paths.EXPLORE_PAGE,
      routes: [
        GoRoute(
          path: app_paths.EXPLORE_PAGE,
          builder: (context, state) => const ExplorePage(collectionLimit: 24),
        ),
        for (final path in [
          app_paths.ONLINE_MUSIC_PAGE,
          app_paths.SETTINGS_PAGE,
          app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
          app_paths.EXPLORE_CHART_LIST_PAGE,
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
          ChangeNotifierProvider<OnlinePlaylistController>.value(
            value: okSubscriptions,
          ),
          ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
            value: personal,
          ),
          Provider<OnlineMusicService>.value(value: service),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: scaffoldMessengerKey,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('能打开的歌单'), findsOneWidget);

    await tester.tap(find.text('订阅'));
    await tester.pumpAndSettle();

    // 正向：成功订阅**确实**会进详情页 —— 这才让上一条的"不跳转"有意义。
    expect(
      find.text('stub:${app_paths.ONLINE_PLAYLIST_DETAIL_PAGE}'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  // ------------------------------------------------------------------ 工具条跳转

  testWidgets('★ 工具条「搜索在线音乐」→ 在线搜索页', (tester) async {
    await pumpExplore(tester, service: allCapabilitiesService());

    await tester.tap(find.byTooltip('搜索在线音乐'));
    await tester.pumpAndSettle();

    // 与主页那几个「查看全部」同类的**跳转契约**：路径常量写错一个字，
    // 用户点了没反应或落到别处，而且**不会报任何错**。
    expect(find.text('stub:${app_paths.ONLINE_MUSIC_PAGE}'), findsOneWidget);
  });
}

/// 探索页用到的服务替身：能力可配、歌单列表按平台返回/抛错。
final class _ExploreService implements OnlineMusicService {
  _ExploreService({
    OnlineMusicCapabilities? capabilities,
    this.collections = const {},
    this.failingCollections = const {},
    this.charts = const {},
    this.failingCharts = const {},
    this.newSongs = const {},
    this.failingNewSongs = const {},
    this.ignoreOffset = false,
    this.playlistFailure,
    this.categories = const {},
    this.failingCategories = const {},
    this.categoryCollections = const {},
  }) : capabilities =
           capabilities ??
           OnlineMusicCapabilities(
             searchablePlatforms: const [],
             resolvablePlatforms: const [],
           );

  @override
  final OnlineMusicCapabilities capabilities;

  final Map<MusicPlatform, List<RemotePlaylistSummary>> collections;
  final Set<MusicPlatform> failingCollections;
  final Map<MusicPlatform, List<RemotePlaylistSummary>> charts;
  final Set<MusicPlatform> failingCharts;
  final Map<MusicPlatform, List<RemotePlaylistCategory>> categories;
  final Set<MusicPlatform> failingCategories;
  final Map<MusicPlatform, List<MusicTrack>> newSongs;
  final Set<MusicPlatform> failingNewSongs;

  /// 模拟"**用户配了一个忽略 offset 的接口**"（分页路径由用户配置，未必真支持翻页）。
  final bool ignoreOffset;

  /// 设了就让 `fetchPlaylist`（= 点「订阅」时真正要打开的详情）失败。
  /// 用来测"配置指向打不开的 id"时的安全网。
  final Object? playlistFailure;

  /// 按分类返回的歌单（键是分类 id）。用来证明"选了分类就只请求该分类"。
  final Map<String, List<RemotePlaylistSummary>> categoryCollections;

  /// 记录每次歌单列表请求带的分类（null = 全部）与 offset（分页从哪开始）。
  final List<({MusicPlatform platform, String? categoryId, int offset})>
  collectionCalls = [];

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    if (failingCategories.contains(platform)) {
      throw OnlineMusicException(
        kind: OnlineMusicErrorKind.unavailable,
        safeMessage: '${musicPlatformLabel(platform)} 分类读取失败',
      );
    }
    return categories[platform] ?? const [];
  }

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
    return charts[platform] ?? const [];
  }

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    collectionCalls.add((
      platform: platform,
      categoryId: categoryId,
      offset: offset,
    ));
    if (failingCollections.contains(platform)) {
      throw OnlineMusicException(
        kind: OnlineMusicErrorKind.unavailable,
        safeMessage: '${musicPlatformLabel(platform)} 平台歌单读取失败',
      );
    }
    final source = categoryId != null
        ? (categoryCollections[categoryId] ?? const <RemotePlaylistSummary>[])
        : (collections[platform] ?? const <RemotePlaylistSummary>[]);
    // 真实服务确实是 limit/offset 分页（网易云 `/top/playlist` 实测 offset 有效），
    // 替身也照做，否则"加载更多"的测试等于没测。
    // `ignoreOffset` 用来模拟"**用户配了一个忽略 offset 的接口**"（例如 `/personalized`）。
    final effectiveOffset = ignoreOffset ? 0 : offset;
    return source.skip(effectiveOffset).take(limit).toList(growable: false);
  }

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
  }) async {
    final failure = playlistFailure;
    if (failure != null) throw failure;
    // 默认**成功**：这样"订阅成功 → 进详情页"才有一条正向对照，
    // 否则"订阅失败不跳转"那条否定断言可能只是因为"这个 harness 里压根不会跳"。
    return RemotePlaylist(
      platform: platform,
      id: playlistId,
      name: '订阅的歌单',
      trackCount: 0,
      tracks: const [],
    );
  }

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
  }) async {
    if (failingNewSongs.contains(platform)) {
      throw OnlineMusicException(
        kind: OnlineMusicErrorKind.unavailable,
        safeMessage: '${musicPlatformLabel(platform)} 新歌读取失败',
      );
    }
    return newSongs[platform] ?? const [];
  }

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

/// 只记录订阅请求的服务替身（证明探索页把 `(platform, id)` 传对了）。
final class _RecordingPlaylistService implements OnlineMusicService {
  final requestedPlaylists = <({MusicPlatform platform, String id})>[];

  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
    playlistPlatforms: const [MusicPlatform.qq],
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
      name: 'QQ 歌单',
      trackCount: 1,
      tracks: [
        MusicTrack(
          ref: PlatformTrackRef(platform: platform, trackId: 'q1'),
          title: 'Track q1',
          artists: const ['Artist'],
        ),
      ],
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
