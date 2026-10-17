import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
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
