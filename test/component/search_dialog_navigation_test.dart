import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_album_row.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/artist_hot_songs_page.dart';
import 'package:pure_music/page/online_album_page.dart';
import 'package:pure_music/page/online_artist_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

/// **路由级**集成测试（Spec §10.1 V1 / V2）。
///
/// 这里不用替身页，而是把**真实的路由树形状**（`StatefulShellRoute` +
/// `/explore` 下的三个子路由）与**真实的页面**装配起来，因为要验的两件事
/// 都只在真路由 + 真 navigator 下才成立：
///
/// - **V1**：弹窗（root navigator）里点在线专辑行触发 `context.push`
///   ⇒ 新页必须在弹窗**之上**可见可点。曾经的失败形态是"新页渲染出来了，
///   但被 dialog 遮罩压住、点击被吞掉" —— 只断言"页面存在"抓不到。
/// - **V2**：`ARTIST_HOT_SONGS_PAGE` 这类**绝对路径常量** push 到**嵌套相对**路由，
///   以及 `extra == null` 时的回落，都依赖 go_router 对嵌套路由的解析。
///
/// 子路由的注册形状**刻意与 `lib/entry.dart` 保持一致**（路径段、`pageBuilder`、
/// `extra` 的 record 形状）。它可以被看作 `entry.dart` 那段路由的一张快照。
///
/// ⚠️ **本文件里的路由树是 `lib/entry.dart` 的手抄快照，不是共享工厂**：
/// `entry.dart` 的路由（路径段、`extra` 形状、`pageBuilder`、回落目标）一旦改动，
/// 必须同步更新本文件 —— 否则这里会继续测一份过时的路由形状，绿得毫无意义。
void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });
  testWidgets('V1: 从弹窗里点在线专辑行 ⇒ 弹窗消失、专辑页出现在最上层', (tester) async {
    final router = await _pumpApp(tester);

    await _openSearchAndFindAlbum(tester);

    // 点这一行**才**会 push（`OnlineAlbumRow` 的默认行为）。
    // ⚠️ 必须定位到**行**，不能用 `find.text('故里逢春')`：输入框里也是这个词，
    // `.first` 会点到输入框上，push 根本不会发生（测试却可能因别的原因"通过"）。
    await tester.tap(find.byType(OnlineAlbumRow));
    await tester.pumpAndSettle();

    // 弹窗必须自己退出：否则它挂在 root navigator 上，会盖住 push 出来的页。
    expect(find.byType(SearchDialog), findsNothing);
    expect(find.byType(OnlineAlbumPage), findsOneWidget);
    expect(router.state.uri.toString(), app_paths.ONLINE_ALBUM_PAGE);

    // 不只是"渲染出来了"：新页必须真的**可点** —— 若弹窗的遮罩还留着，
    // 这里会因为被遮罩拦截而落空（这正是 V1 探针抓到的失败形态）。
    expect(find.byType(OnlineAlbumPage).hitTestable(), findsOneWidget);
  });

  testWidgets('V1: 关闭弹窗不会误 pop 底下的页面', (tester) async {
    final router = await _pumpApp(tester);

    // 先正常打开、再点遮罩关掉弹窗（不点任何行）。
    await _openSearchAndFindAlbum(tester);
    await tester.tapAt(const Offset(4, 4)); // 遮罩外
    await tester.pumpAndSettle();

    expect(find.byType(SearchDialog), findsNothing);
    // 底层仍在 `/explore`（没有被"关弹窗"顺手 pop 掉壳里的页）。
    expect(router.state.uri.toString(), app_paths.EXPLORE_PAGE);
    expect(find.text(_exploreStubLabel), findsOneWidget);
  });

  testWidgets('V2: 绝对路径 push 到嵌套子路由 /explore/artist/hot-songs', (tester) async {
    final router = await _pumpApp(tester);
    final context = tester.element(find.text(_exploreStubLabel));

    // 该常量是**绝对路径**，而路由是**嵌套相对**段 —— 这正是 V2 要验的解析。
    context.push(
      app_paths.ARTIST_HOT_SONGS_PAGE,
      extra: (artist: _artist()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ArtistHotSongsPage), findsOneWidget);
    expect(router.state.uri.toString(), app_paths.ARTIST_HOT_SONGS_PAGE);
  });

  testWidgets('V2: hot-songs 的 extra == null ⇒ 回落探索页（不是空白/报错）', (tester) async {
    final router = await _pumpApp(tester);
    final context = tester.element(find.text(_exploreStubLabel));

    context.push(app_paths.ARTIST_HOT_SONGS_PAGE);
    await tester.pumpAndSettle();

    // 回落目标是 `ExplorePage`（与 `playlists` 的既有同类回落一致）。
    expect(tester.takeException(), isNull);
    expect(find.byType(ArtistHotSongsPage), findsNothing);
    expect(router.state.uri.toString(), app_paths.ARTIST_HOT_SONGS_PAGE);
    // **必须断言真的看到了回落页**：只断言"没有崩、没有 ArtistHotSongsPage"
    // 的话，落到一张空白页也会照常通过 —— 那正是这条用例要防的事。
    expect(find.text(_exploreFallbackLabel), findsOneWidget);
  });

  testWidgets('V2: 绝对路径 push 到 /explore/artist 也能命中', (tester) async {
    final router = await _pumpApp(tester);
    final context = tester.element(find.text(_exploreStubLabel));

    context.push(
      app_paths.ONLINE_ARTIST_PAGE,
      extra: (platform: MusicPlatform.netease, artistId: 'ar1', name: '阿YueYue'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OnlineArtistPage), findsOneWidget);
    expect(router.state.uri.toString(), app_paths.ONLINE_ARTIST_PAGE);
  });
}

/// 探索页占位与 hot-songs 回落占位的文案（写常量是为了能被 `const` 引用）。
const _exploreStubLabel = 'stub:${app_paths.EXPLORE_PAGE}';
const _exploreFallbackLabel = 'fallback:${app_paths.EXPLORE_PAGE}';

OnlineArtist _artist() => OnlineArtist(  platform: MusicPlatform.netease,
  id: 'ar1',
  name: '阿YueYue',
  hotSongs: [_track()],
);

MusicTrack _track() => MusicTrack(
  ref: const PlatformTrackRef(platform: MusicPlatform.netease, trackId: 't1'),
  title: '热歌',
  artists: const ['阿YueYue'],
);

/// 装配"真路由形状 + 真页面 + 真弹窗"。
Future<GoRouter> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final database = sqlite3.openInMemory();
  initializeAppDatabase(database);
  final favorites = PersonalOnlinePlaylistController(
    repository: SynchronousFuture(OnlineLibraryRepository(database)),
  );
  addTearDown(favorites.dispose);
  addTearDown(database.dispose);

  final router = GoRouter(
    initialLocation: app_paths.EXPLORE_PAGE,
    routes: [
      StatefulShellRoute(
        builder: (context, state, shell) => Scaffold(body: shell),
        navigatorContainerBuilder: (context, shell, children) =>
            IndexedStack(index: shell.currentIndex, children: children),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: app_paths.EXPLORE_PAGE,
                // 探索页本身在这个测试里是占位（我们不验它的内容，只验路由与弹窗），
                // 但它必须**在壳里**，这样 push 走的是壳的 navigator —— 正是 V1 的现场。
                builder: (context, state) => Scaffold(
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(_exploreStubLabel),
                        Builder(
                          builder: (inner) => ElevatedButton(
                            onPressed: () => showApplicationSearch(
                              inner,
                              initialSource: SearchSource.online,
                            ),
                            child: const Text('打开在线搜索'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                routes: [
                  // ⚠️ 以下三段与 `lib/entry.dart` 的注册形状保持一致。
                  GoRoute(
                    path: 'album',
                    pageBuilder: (context, state) {
                      final extra =
                          state.extra
                              as ({
                                MusicPlatform platform,
                                String albumId,
                                String? name,
                              })?;
                      return MaterialPage(
                        key: state.pageKey,
                        child: OnlineAlbumPage(
                          platform: extra?.platform ?? MusicPlatform.netease,
                          albumId: extra?.albumId ?? '',
                          initialName: extra?.name,
                        ),
                      );
                    },
                  ),
                  GoRoute(
                    path: 'artist',
                    pageBuilder: (context, state) {
                      final extra =
                          state.extra
                              as ({
                                MusicPlatform platform,
                                String artistId,
                                String? name,
                              })?;
                      return MaterialPage(
                        key: state.pageKey,
                        child: OnlineArtistPage(
                          platform: extra?.platform ?? MusicPlatform.netease,
                          artistId: extra?.artistId ?? '',
                          initialName: extra?.name,
                        ),
                      );
                    },
                    routes: [
                      GoRoute(
                        path: 'hot-songs',
                        pageBuilder: (context, state) {
                          final extra =
                              state.extra as ({OnlineArtist artist})?;
                          if (extra == null) {
                            return MaterialPage(
                              key: state.pageKey,
                              child: const Scaffold(
                                body: Text(_exploreFallbackLabel),
                              ),
                            );
                          }
                          return MaterialPage(
                            key: state.pageKey,
                            child: ArtistHotSongsPage(artist: extra.artist),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
          value: favorites,
        ),
        Provider<OnlineMusicService>.value(value: _AlbumSearchService()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// 打开弹窗 → 切到在线 → 提交 → 等专辑行出现。
Future<void> _openSearchAndFindAlbum(WidgetTester tester) async {
  await tester.tap(find.text('打开在线搜索'));
  await tester.pumpAndSettle();
  expect(find.byType(SearchDialog), findsOneWidget);

  await tester.enterText(find.byType(TextField), '故里逢春');
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();

  expect(find.text('故里逢春'), findsWidgets);
}

/// 只实现"搜曲目 + 搜专辑 + 打开专辑页"所需能力的假服务。
final class _AlbumSearchService implements OnlineMusicService {
  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [MusicPlatform.netease],
    resolvablePlatforms: const [],
    // 专辑要**打得开**才会显示专辑行（`openableSearchAlbumPlatforms`）。
    albumPlatforms: const [MusicPlatform.netease],
    searchableAlbumPlatforms: const [MusicPlatform.netease],
  );

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(
    perPlatform: {
      MusicPlatform.netease: MusicSearchPage(
        platform: MusicPlatform.netease,
        items: [_track()],
        offset: 0,
        limit: limit,
        total: 1,
      ),
    },
    failures: const {},
  );

  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    OnlineAlbumSummary(
      platform: MusicPlatform.netease,
      id: 'a1',
      name: '故里逢春',
      trackCount: 2,
      releaseTime: DateTime.utc(2020, 7, 29),
    ),
  ];

  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) async => OnlineAlbum(
    platform: platform,
    id: albumId,
    name: '故里逢春',
    tracks: [_track()],
  );

  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) async => _artist();

  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [_track()];

  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}

final class _FakeHotKeyManager extends HotKeyManagerPlatform {
  @override
  Stream<Map<Object?, Object?>> get onKeyEventReceiver => const Stream.empty();

  @override
  Future<void> register(HotKey hotKey) async {}

  @override
  Future<void> unregister(HotKey hotKey) async {}

  @override
  Future<void> unregisterAll() async {}
}
