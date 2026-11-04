import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 在线曲目行的**统一契约**。
///
/// 这段组装此前在**每个用到它的页面各抄一遍**（R2 逐处清点后收敛；
/// 现在 6 个页面都走这一个组件）。抄写期间出现过**互相不一致**的行为：有的没有"添加到歌单"、
/// 收藏页把 `favorite` 硬编码成 true、搜索页的来源取自搜索分组而不是曲目自己。
/// 现在它们都走这一个组件，因此这些规则要在这里被钉住。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late PersonalOnlinePlaylistController favorites;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    favorites = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
  });

  tearDown(() {
    favorites.dispose();
    database.dispose();
  });

  MusicTrack track(
    String id, {
    MusicPlatform platform = MusicPlatform.qq,
    String album = '专辑一',
    TrackAvailability availability = TrackAvailability.playable,
  }) => MusicTrack(
    ref: PlatformTrackRef(platform: platform, trackId: id),
    title: '曲目 $id',
    artists: const ['甲'],
    album: album,
    availability: availability,
  );

  Future<void> pumpEntry(
    WidgetTester tester, {
    required MusicTrack forTrack,
    VoidCallback? onTap,
    VoidCallback? onRemove,
    bool animateEntrance = true,
    bool? playable,
  }) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: favorites,
        child: MaterialApp(
          home: Scaffold(
            body: OnlineTrackEntry(
              track: forTrack,
              onTap: onTap,
              onRemove: onRemove,
              animateEntrance: animateEntrance,
              playable: playable,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> hover(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(OnlineTrackEntry)));
    await tester.pumpAndSettle();
  }

  testWidgets('★ 来源标记取自曲目自己的 ref（不是外层分组/歌单的字段）', (tester) async {
    await pumpEntry(tester, forTrack: track('t1', platform: MusicPlatform.qq));

    final row = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
    expect(row.sourceLabel, 'QQ音乐');
  });

  testWidgets('副标题 = 艺人 · 专辑；没有专辑时不留分隔符', (tester) async {
    await pumpEntry(tester, forTrack: track('t1'));
    expect(
      tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow)).details,
      '甲 · 专辑一',
    );

    await pumpEntry(tester, forTrack: track('t1', album: ''));
    expect(
      tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow)).details,
      '甲',
    );
  });

  testWidgets('可播放的曲目可点；不可播放/付费的曲目不可点', (tester) async {
    var taps = 0;
    await pumpEntry(tester, forTrack: track('t1'), onTap: () => taps++);
    var row = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
    expect(row.enabled, isTrue);
    expect(row.onTap, isNotNull);
    await tester.tap(find.byType(OnlineTrackRow));
    expect(taps, 1);

    for (final unavailable in [
      TrackAvailability.unavailable,
      TrackAvailability.paid,
    ]) {
      await pumpEntry(
        tester,
        forTrack: track('t1', availability: unavailable),
        onTap: () => taps++,
      );
      row = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
      expect(row.enabled, isFalse, reason: '$unavailable 不应可点');
      expect(row.onTap, isNull);
    }
    expect(taps, 1, reason: '不可播放的曲目不该被点名');
  });

  testWidgets('★ 悬停操作统一包含「添加到歌单」与「收藏」', (tester) async {
    await pumpEntry(tester, forTrack: track('t1'));

    // 未悬停时不出操作（与既有曲目行一致）。
    expect(find.byTooltip('添加到歌单'), findsNothing);

    await hover(tester);

    expect(find.byTooltip('添加到歌单'), findsOneWidget);
    expect(find.byTooltip('收藏'), findsOneWidget);
  });

  testWidgets('不传 onRemove 时没有「从歌单移除」', (tester) async {
    await pumpEntry(tester, forTrack: track('t1'));
    await hover(tester);

    expect(find.byTooltip('从歌单移除'), findsNothing);
  });

  testWidgets('传 onRemove 时提供「从歌单移除」', (tester) async {
    var removed = 0;
    await pumpEntry(
      tester,
      forTrack: track('t1'),
      onRemove: () => removed++,
    );
    await hover(tester);

    expect(find.byTooltip('从歌单移除'), findsOneWidget);
    await tester.tap(find.byTooltip('从歌单移除'));
    expect(removed, 1);
  });

  testWidgets('★ 收藏态来自控制器：已收藏时显示「取消收藏」，点击会切换', (tester) async {
    final forTrack = track('t1');
    await favorites.loadFavorites();
    await favorites.toggleFavorite(forTrack);

    await pumpEntry(tester, forTrack: forTrack);
    final row = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
    expect(row.favorite, isTrue, reason: '已收藏的曲目必须显示为已收藏');

    await hover(tester);
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();

    expect(favorites.isFavorite(forTrack.ref), isFalse);
  });

  testWidgets('animateEntrance: false 时不包进场动画（可重排列表用）', (tester) async {
    await pumpEntry(tester, forTrack: track('t1'), animateEntrance: false);
    expect(find.byType(DirectionalListItemEntrance), findsNothing);

    await pumpEntry(tester, forTrack: track('t1'));
    expect(find.byType(DirectionalListItemEntrance), findsOneWidget);
  });

  // ------------------------------------------------------- 多艺人的艺人入口
  //
  // 用户报告（2026-11-03）：一首歌有多个艺人时，点「查看艺人」不管点第几位，
  // 都进**第一位**的页面 ✗。成因是详情行把整串艺人名做成**一段**、目标写死
  // `artistIds.first` ⇒ 现在每位艺人各是一段、各带自己的 id ✓。

  MusicTrack multiArtistTrack() => MusicTrack(
    ref: const PlatformTrackRef(platform: MusicPlatform.qq, trackId: 'multi-1'),
    title: '合唱曲目',
    artists: const ['甲', '乙', '丙'],
    artistIds: const ['artist-a', 'artist-b', 'artist-c'],
    album: '专辑一',
    albumIds: const ['album-1'],
    availability: TrackAvailability.playable,
  );

  /// 用**真路由**跑：断言的是"点了之后进了哪位艺人的页面"，
  /// 而不是"回调被调用了几次"（后者抓不到"两个名字都绑第一个 id"这个缺陷 ✗）。
  Future<GoRouter> pumpWithRouter(
    WidgetTester tester, {
    required MusicTrack forTrack,
  }) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/entry-host',
      routes: [
        GoRoute(
          path: '/entry-host',
          builder: (context, state) => Scaffold(
            body: OnlineTrackEntry(track: forTrack, onTap: () {}),
          ),
        ),
        GoRoute(
          path: app_paths.ONLINE_ARTIST_PAGE,
          builder: (context, state) {
            final extra =
                state.extra
                    as ({MusicPlatform platform, String artistId, String? name})?;
            return Scaffold(
              body: Text('artist:${extra?.artistId}|${extra?.name}'),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: favorites,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('★ 多艺人：每位艺人各一段（`甲、乙、丙 · 专辑`），不是合成一整段', (tester) async {
    await pumpEntry(tester, forTrack: multiArtistTrack());

    for (final name in ['甲', '乙', '丙']) {
      expect(find.text(name), findsOneWidget, reason: '$name 应当自成一个可点段');
    }
    // 艺人之间是 `、`；艺人→专辑、专辑→来源是 ` · `（与单艺人时的排版一致 ✓）。
    expect(find.text('、'), findsNWidgets(2));
    expect(find.text(' · '), findsNWidgets(2));
    expect(find.text('甲、乙、丙'), findsNothing);
  });

  testWidgets('★ 多艺人：点第二位艺人 ⇒ 进**第二位**的页面（回归：以前一律进第一位）', (
    tester,
  ) async {
    await pumpWithRouter(tester, forTrack: multiArtistTrack());

    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();

    expect(
      find.text('artist:artist-b|乙'),
      findsOneWidget,
      reason: '点「乙」必须带着乙自己的 id 进艺人页（以前写死 artistIds.first ⇒ 进了甲）',
    );
    expect(find.textContaining('artist-a'), findsNothing);
  });

  testWidgets('★ 多艺人：点第三位艺人 ⇒ 进第三位的页面（不是"第一位或第二位"）', (tester) async {
    await pumpWithRouter(tester, forTrack: multiArtistTrack());

    await tester.tap(find.text('丙'));
    await tester.pumpAndSettle();

    expect(find.text('artist:artist-c|丙'), findsOneWidget);
  });

  testWidgets('名字与 id 位数对不上 ⇒ 整段纯文本（不猜是哪位、也不借第一位）', (tester) async {
    final mismatched = MusicTrack(
      ref: const PlatformTrackRef(platform: MusicPlatform.qq, trackId: 'multi-2'),
      title: '信息不全',
      artists: const ['甲', '乙'],
      // 只带一位 id：说不清它属于谁 ⇒ 不许绑到任何一个名字上。
      artistIds: const ['artist-a'],
      availability: TrackAvailability.playable,
    );
    await pumpWithRouter(tester, forTrack: mismatched);

    expect(find.byTooltip('查看艺人'), findsNothing);
    await tester.tap(find.text('甲、乙'));
    await tester.pumpAndSettle();
    expect(find.textContaining('artist:'), findsNothing, reason: '不该跳到任何艺人页');
  });

  testWidgets('没带 id 的那一位保持纯文本，其余位照旧可点（不静默降级整行）', (tester) async {
    final partial = MusicTrack(
      ref: const PlatformTrackRef(platform: MusicPlatform.qq, trackId: 'multi-3'),
      title: '部分带 id',
      artists: const ['甲', '乙'],
      // 位数对齐，但第二位没有 id ⇒ 乙是纯文本、甲仍可点。
      artistIds: const ['artist-a', ''],
      availability: TrackAvailability.playable,
    );
    await pumpWithRouter(tester, forTrack: partial);

    expect(find.byTooltip('查看艺人'), findsOneWidget);
    await tester.tap(find.text('乙'));
    await tester.pumpAndSettle();
    expect(find.textContaining('artist:'), findsNothing);

    await tester.tap(find.text('甲'));
    await tester.pumpAndSettle();
    expect(find.text('artist:artist-a|甲'), findsOneWidget);
  });

  // ----------------------------------------------------------------- F1 判据统一
  //
  // 背景（2026-10-17 用户裁定）：`canPlayTrack`（解析侧身份 **且** 平台未声明
  // paid/unavailable，`unknown` 放行）是**唯一**的可播判据。
  // 此前预览页/专辑页的「播放全部」只问"解析侧能不能解析"、行却另按 availability 判
  // ⇒ 同一页里**行灰掉、按钮却把这首歌算进了队列**。
  // 这两条把"判据本身"与"行能接受页面算好的结论"钉住。

  testWidgets('★ 可播判据 = canPlayTrack：身份与可用状态都要过，unknown 放行', (tester) async {
    final capabilities = OnlineMusicCapabilities(
      searchablePlatforms: const [],
      // 网易云有解析能力；QQ 没有 ⇒ 用来验"解析侧身份"这一维。
      resolvablePlatforms: const [MusicPlatform.netease],
    );
    final resolveable = track('n1', platform: MusicPlatform.netease);
    final notResolveable = track('q1', platform: MusicPlatform.qq);
    final paid = track(
      'n2',
      platform: MusicPlatform.netease,
      availability: TrackAvailability.paid,
    );
    final unknown = track(
      'n3',
      platform: MusicPlatform.netease,
      availability: TrackAvailability.unknown,
    );

    expect(
      OnlineTrackEntry.playableOf(
        track: resolveable,
        providerCapabilities: capabilities,
      ),
      isTrue,
      reason: '有解析能力且平台没声明问题时必须可播 ✓',
    );
    expect(
      OnlineTrackEntry.playableOf(
        track: notResolveable,
        providerCapabilities: capabilities,
      ),
      isFalse,
      reason: '没有任何解析侧能处理这条身份 ⇒ 不可播（这是"播放解析是独立能力"的直接后果）',
    );
    expect(
      OnlineTrackEntry.playableOf(
        track: paid,
        providerCapabilities: capabilities,
      ),
      isFalse,
      reason: '平台明确声明付费 ⇒ 不可播',
    );
    expect(
      OnlineTrackEntry.playableOf(
        track: unknown,
        providerCapabilities: capabilities,
      ),
      isTrue,
      reason: '`unknown` 只是"平台没说" ⇒ **不能**当成不可播 ✓（用户明确要求保留兼容）',
    );

    // 没有注册在线音乐 Provider（组件级测试常见）⇒ 回落分支必须给出**同一套结论**。
    expect(
      OnlineTrackEntry.playableOf(track: resolveable),
      isTrue,
      reason: '回落分支：身份有效 + 可用状态放行 ⇒ 可播',
    );
    expect(
      OnlineTrackEntry.playableOf(track: paid),
      isFalse,
      reason: '回落分支同样要挡住 paid',
    );
    expect(
      OnlineTrackEntry.playableOf(track: unknown),
      isTrue,
      reason: '回落分支同样放行 unknown',
    );
  });

  testWidgets('★ 行接受调用方算好的结论（与「播放全部」共用一份判据）', (tester) async {
    // 调用方（预览页/专辑页）把 `canPlayTrack` 的结论传进来 ⇒ 行必须照它走，
    // 不许再按 availability 自己判一遍 —— 那正是"行与按钮分叉"的来源。
    await pumpEntry(
      tester,
      forTrack: track('t1'),
      playable: false,
      onTap: () {},
    );
    var row = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
    expect(row.enabled, isFalse, reason: '调用方说不可播 ⇒ 行不可点');
    expect(row.onTap, isNull);

    // 反过来：调用方说可播（解析侧握有权限），行就该可点。
    await pumpEntry(
      tester,
      forTrack: track('t1'),
      playable: true,
      onTap: () {},
    );
    row = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
    expect(row.enabled, isTrue);
    expect(row.onTap, isNotNull);
  });
}
