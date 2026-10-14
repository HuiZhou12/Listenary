import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/page/online_playlist_detail_page.dart';
import 'package:pure_music/page/online_playlists_page.dart';
import 'package:pure_music/page/personal_playlist_detail_page.dart';
import 'package:pure_music/page/playlists_page.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late OnlinePlaylistController controller;
  late PersonalOnlinePlaylistController personalController;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    controller = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: _FakeOnlineMusicService(),
    );
    personalController = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
  });

  tearDown(() {
    controller.dispose();
    personalController.dispose();
    database.dispose();
  });

  testWidgets('empty subscription view exposes the add action', (tester) async {
    await _pump(
      tester,
      controller,
      personalController,
      const OnlinePlaylistsPage(),
    );

    await tester.tap(find.byTooltip('添加在线歌单'));
    await tester.pump();
    expect(find.text('网易云歌单 ID'), findsOneWidget);
  });

  testWidgets('多平台时可选择来源平台，并把手选的 (平台, ID) 交给控制器', (tester) async {
    final service = _FakeOnlineMusicService(
      playlistPlatforms: const {MusicPlatform.netease, MusicPlatform.qq},
    );
    final multiController = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: service,
    );
    addTearDown(multiController.dispose);

    await _pump(
      tester,
      multiController,
      personalController,
      const OnlinePlaylistsPage(),
      service: service,
    );
    await tester.tap(find.byTooltip('添加在线歌单'));
    await tester.pumpAndSettle();

    // 两个平台都能提供歌单详情 ⇒ 出现来源选择，默认是列表里的第一个（网易云）。
    expect(find.byType(SegmentedButton<MusicPlatform>), findsOneWidget);
    expect(find.text('网易云歌单 ID'), findsOneWidget);

    await tester.tap(find.text('QQ音乐'));
    await tester.pumpAndSettle();
    expect(find.text('QQ音乐歌单 ID'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '7729596131');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 来源身份不能丢：控制器拿到的是**用户选的平台**，不是硬编码的网易云。
    expect(service.requestedPlaylists, hasLength(1));
    expect(service.requestedPlaylists.single.platform, MusicPlatform.qq);
    expect(service.requestedPlaylists.single.id, '7729596131');
  });

  testWidgets('单平台时不摆来源选择控件，且校验平台自己的 ID 形状', (tester) async {
    final service = _FakeOnlineMusicService();
    final singleController = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: service,
    );
    addTearDown(singleController.dispose);

    await _pump(
      tester,
      singleController,
      personalController,
      const OnlinePlaylistsPage(),
      service: service,
    );
    await tester.tap(find.byTooltip('添加在线歌单'));
    await tester.pumpAndSettle();

    expect(find.byType(SegmentedButton<MusicPlatform>), findsNothing);
    expect(find.text('网易云歌单 ID'), findsOneWidget);

    // 网易云的 ID 是数字：填字母时内联报错且不发请求。
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.text('网易云歌单 ID 是数字'), findsOneWidget);
    expect(service.requestedPlaylists, isEmpty);
  });

  testWidgets('subscription list shows safe metadata and read-only actions', (
    tester,
  ) async {
    repository.replaceSubscriptionSnapshot(_playlist());

    await _pump(
      tester,
      controller,
      personalController,
      const OnlinePlaylistsPage(),
    );

    expect(find.byTooltip('添加在线歌单'), findsOneWidget);
    expect(find.byTooltip('编辑'), findsNothing);
  });

  testWidgets(
    'detail page renders cover, creator and playback actions without errors',
    (tester) async {
      final saved = repository.replaceSubscriptionSnapshot(_playlist());
      expect(repository.readSubscriptionSnapshot(saved.localId), isNotNull);
      await controller.loadSubscriptions();

      await _pump(
        tester,
        controller,
        personalController,
        OnlinePlaylistDetailPage(localId: saved.localId),
      );
      await _pumpUntilFound(tester, find.text('Remote Playlist'));

      expect(tester.takeException(), isNull);
      expect(find.text('Remote Playlist'), findsOneWidget);
      expect(find.textContaining('只读订阅'), findsOneWidget);
      expect(find.text('播放全部'), findsOneWidget);
      // 加载态之后头部刷新是带文字的按钮（不是 tooltip）。
      expect(find.text('刷新'), findsOneWidget);
      // 添加按钮悬浮时显示。
      final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await hover.moveTo(tester.getCenter(find.text('Remote Track')));
      await tester.pump();
      expect(find.byTooltip('添加到歌单'), findsOneWidget);
      await hover.removePointer();
      expect(find.byTooltip('编辑'), findsNothing);
    },
  );

  testWidgets('★ 歌单详情**一律不显示行首序号**（含名次集合，2026-10-12 用户裁定 ✓）', (
    tester,
  ) async {
    final saved = repository.replaceSubscriptionSnapshot(_playlist());
    await controller.loadSubscriptions();

    // 单例偏好会被这一条改动 ⇒ 用后还原（避免污染其它测试）。
    addTearDown(() => AppPreference.instance.rankedSubscriptions = []);

    // ① 普通歌单：不显示（一直都是）。
    AppPreference.instance.rankedSubscriptions = [];
    await _pump(
      tester,
      controller,
      personalController,
      OnlinePlaylistDetailPage(localId: saved.localId),
    );
    await _pumpUntilFound(tester, find.text('Remote Track'));
    expect(find.text('1'), findsNothing, reason: '普通歌单不该有行首序号');

    // ② **标成名次集合也不显示** ✓ —— 用户裁定："榜单歌单里每首歌的序号去掉" ✓
    //（一整列 1、2、3 只会让列表显得吵 ✗；序号能力仍留在行组件里 ✓）。
    AppPreference.instance.markRankedSubscription(saved.localId);
    await _pump(
      tester,
      controller,
      personalController,
      OnlinePlaylistDetailPage(localId: saved.localId),
    );
    await _pumpUntilFound(tester, find.text('Remote Track'));
    expect(
      find.text('1'),
      findsNothing,
      reason: '名次集合也不再显示行首序号（用户裁定 ✓）',
    );
  });

  testWidgets('★ 订阅歌单详情里点「添加到歌单」→ 曲目真的进自建歌单', (tester) async {
    final saved = repository.replaceSubscriptionSnapshot(_playlist());
    await controller.loadSubscriptions();
    final targetId = repository.createPersonalPlaylist('目标歌单');

    await _pump(
      tester,
      controller,
      personalController,
      OnlinePlaylistDetailPage(localId: saved.localId),
    );
    await _pumpUntilFound(tester, find.text('Remote Track'));

    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    await hover.moveTo(tester.getCenter(find.text('Remote Track')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加到歌单'));
    await tester.pumpAndSettle();

    expect(find.text('收藏到歌单'), findsOneWidget);
    await tester.tap(find.text('目标歌单'));
    await tester.pumpAndSettle();

    // 只断言"弹窗出现"不够：回调没接上时用户看到的过程一模一样。
    // 断言**用户点的那一行**（按标题）真的进了目标歌单，而不是记一个魔法 id。
    final added = repository.readPersonalPlaylist(targetId)!.tracks;
    expect(added.map((item) => item.title), contains('Remote Track'));
    expect(added, hasLength(1));
    // 本 harness 没接应用根部的全局 key，因此不断言 Toast（见 R12 报告 §3）。
    expect(tester.takeException(), isNull);
    await hover.removePointer();
  });

  testWidgets('★ 已加载页上的「刷新」要真的去平台重新拉（不是只重读本地快照）', (tester) async {
    final service = _FakeOnlineMusicService();
    final localController = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: service,
    );
    addTearDown(localController.dispose);

    final saved = repository.replaceSubscriptionSnapshot(_playlist());
    await localController.loadSubscriptions();

    await _pump(
      tester,
      localController,
      personalController,
      OnlinePlaylistDetailPage(localId: saved.localId),
    );
    await _pumpUntilFound(tester, find.text('Remote Track'));
    expect(find.text('平台上新增的歌'), findsNothing);

    // 平台那边多了一首（用户去平台网页上加了歌，回来点刷新）。
    service.playlistBuilder = () => RemotePlaylist(
      platform: MusicPlatform.netease,
      id: '500',
      name: 'Remote Playlist',
      creator: 'Remote Creator',
      trackCount: 2,
      tracks: [
        ..._playlist().tracks,
        MusicTrack(
          ref: const PlatformTrackRef(
            platform: MusicPlatform.netease,
            trackId: '200',
          ),
          title: '平台上新增的歌',
          artists: const ['Remote Artist'],
          album: 'Remote Album',
        ),
      ],
    );

    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();

    // 只断言"按钮点了没报错"是不够的：**刷新必须把平台的新内容带回来**。
    expect(
      find.text('平台上新增的歌'),
      findsOneWidget,
      reason: '「刷新」必须真的去平台重新拉，否则它对用户就是个空按钮',
    );
  });

  testWidgets('unified playlist entry opens the online detail page', (
    tester,
  ) async {
    repository.replaceSubscriptionSnapshot(_playlist());
    await controller.loadSubscriptions();
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: app_paths.PLAYLISTS_PAGE,
      routes: [
        GoRoute(
          path: app_paths.PLAYLISTS_PAGE,
          builder: (context, state) => const PlaylistsPage(),
        ),
        GoRoute(
          path: app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
          builder: (context, state) =>
              OnlinePlaylistDetailPage(localId: state.extra! as int),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<OnlinePlaylistController>.value(
        value: controller,
        child: ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
          value: personalController,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('Remote Playlist'));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Remote Playlist'));
    await _pumpUntilFound(tester, find.textContaining('只读订阅'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(OnlinePlaylistDetailPage), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('personal playlist appears and opens its editable detail', (
    tester,
  ) async {
    final id = repository.createPersonalPlaylist('私人歌单');
    // 两首：排序控件按 hasEnoughItemsToSort（>1）显示，单曲歌单本就不显示排序。
    repository.addTrackToPersonalPlaylist(id, _track('200'));
    repository.addTrackToPersonalPlaylist(id, _track('201'));
    // 自建在线歌单允许**混平台**（D11）：第三首来自 QQ，UI 必须写明来源（I1）。
    repository.addTrackToPersonalPlaylist(
      id,
      _track('q1', platform: MusicPlatform.qq),
    );

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      initialLocation: app_paths.PLAYLISTS_PAGE,
      routes: [
        GoRoute(
          path: app_paths.PLAYLISTS_PAGE,
          builder: (context, state) => const PlaylistsPage(),
        ),
        GoRoute(
          path: app_paths.PERSONAL_PLAYLIST_DETAIL_PAGE,
          builder: (context, state) =>
              PersonalPlaylistDetailPage(localId: state.extra! as int),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<OnlinePlaylistController>.value(
        value: controller,
        child: ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
          value: personalController,
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await _pumpUntilFound(tester, find.text('私人歌单'));
    expect(tester.takeException(), isNull);
    expect(find.text('3首乐曲 · 我的在线歌单'), findsOneWidget);

    await tester.tap(find.text('私人歌单'));
    await _pumpUntilFound(tester, find.text('3 首歌曲 · 我的在线歌单'));
    expect(find.byType(PersonalPlaylistDetailPage), findsOneWidget);
    // 混平台歌单：每一行都带自己的来源标签（网易云 ×2 + QQ音乐 ×1）。
    expect(
      find.descendant(
        of: find.byType(PersonalPlaylistDetailPage),
        matching: find.text('网易云'),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: find.byType(PersonalPlaylistDetailPage),
        matching: find.text('QQ音乐'),
      ),
      findsOneWidget,
    );
    // 详情页只保留一个标题（去掉 PageScaffold 双标题）。
    expect(
      find.descendant(
        of: find.byType(PersonalPlaylistDetailPage),
        matching: find.text('私人歌单'),
      ),
      findsOneWidget,
    );
    // 默认排序为「添加时间」（BUG-5）；排序控件按既有规则（>1 首）显示。
    expect(
      find.descendant(
        of: find.byType(PersonalPlaylistDetailPage),
        matching: find.text('添加时间'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail header remains valid at compact width', (tester) async {
    final saved = repository.replaceSubscriptionSnapshot(_playlist());
    await controller.loadSubscriptions();
    tester.view.physicalSize = const Size(420, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(
      tester,
      controller,
      personalController,
      OnlinePlaylistDetailPage(localId: saved.localId),
    );
    await _pumpUntilFound(tester, find.text('Remote Playlist'));

    expect(find.text('Remote Playlist'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  OnlinePlaylistController controller,
  PersonalOnlinePlaylistController personalController,
  Widget child, {
  OnlineMusicService? service,
}) {
  final page = MaterialApp(home: Scaffold(body: child));
  return tester.pumpWidget(
    ChangeNotifierProvider<OnlinePlaylistController>.value(
      value: controller,
      child: ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: personalController,
        child: service == null
            ? page
            : Provider<OnlineMusicService>.value(value: service, child: page),
      ),
    ),
  );
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data)
      .whereType<String>()
      .toList(growable: false);
  throw TestFailure(
    'Timed out waiting for ${finder.describeMatch(Plurality.one)}; '
    'visible text: $visibleText',
  );
}

final class _FakeOnlineMusicService implements OnlineMusicService {
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
  _FakeOnlineMusicService({
    Set<MusicPlatform> playlistPlatforms = const {MusicPlatform.netease},
  }) : capabilities = OnlineMusicCapabilities(
         searchablePlatforms: const [],
         resolvablePlatforms: const [],
         playlistPlatforms: playlistPlatforms,
       );

  @override
  final OnlineMusicCapabilities capabilities;

  /// 记录真实发出去的 `(platform, playlistId)`：用来证明 UI 把来源身份传对了（I1）。
  final requestedPlaylists = <({MusicPlatform platform, String id})>[];

  /// 平台那边返回的歌单内容。测试可以中途换掉它，用来模拟
  /// **"平台上新增了曲目"** —— 这是"刷新到底有没有去平台重新拉"的唯一判别方式。
  RemotePlaylist Function() playlistBuilder = _playlist;

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
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requestedPlaylists.add((platform: platform, id: playlistId));
    return playlistBuilder();
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
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(perPlatform: const {}, failures: const {});

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

final _playlistCoverUri = Uri.parse('https://cover.invalid/playlist.jpg');

MusicTrack _track(
  String id, {
  MusicPlatform platform = MusicPlatform.netease,
}) => MusicTrack(
  ref: PlatformTrackRef(platform: platform, trackId: id),
  title: 'Personal Track',
  artists: const ['Personal Artist'],
);

RemotePlaylist _playlist() => RemotePlaylist(
  platform: MusicPlatform.netease,
  id: '500',
  name: 'Remote Playlist',
  coverUri: _playlistCoverUri,
  creator: 'Remote Creator',
  trackCount: 1,
  tracks: [
    MusicTrack(
      ref: const PlatformTrackRef(
        platform: MusicPlatform.netease,
        trackId: '100',
      ),
      title: 'Remote Track',
      artists: const ['Remote Artist'],
      album: 'Remote Album',
    ),
  ],
);
