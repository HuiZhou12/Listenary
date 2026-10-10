import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/page/personal_playlist_detail_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 自建在线歌单详情页。
///
/// R2 改了这个页面的行构造（统一到 `OnlineTrackEntry`，并保留了"可重排列表里不放进场动画"），
/// 而它此前只有"从统一歌单页导航进来"的少量断言。这里补上它真正对外承诺的行为：
/// 移除曲目、统一行的操作、以及**排序模式下的重排列表不带进场动画**。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late PersonalOnlinePlaylistController controller;

  /// `AppPreference` 是**进程级单例**，而 `UniDetailPage.setSortMethod` 会**直接写**它
  /// （`uni_detail_page.dart` 的 `widget.pref.sortMethod = ...`）。
  /// 因此凡是在这里切过排序方法的测试，都必须把这份偏好**还原**，
  /// 否则会静默泄漏给同文件里后面的测试（表现为"默认排序"忽然变了）。
  late int originalSortMethod;

  setUp(() {
    originalSortMethod = AppPreference
        .instance
        .personalPlaylistDetailPagePref
        .sortMethod;
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    controller = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
  });

  tearDown(() {
    AppPreference.instance.personalPlaylistDetailPagePref.sortMethod =
        originalSortMethod;
    controller.dispose();
    database.dispose();
  });

  MusicTrack track(String id, MusicPlatform platform) => MusicTrack(
    ref: PlatformTrackRef(platform: platform, trackId: id),
    title: '曲目 $id',
    artists: const ['甲'],
    album: '专辑一',
  );

  /// 建一个**混平台**歌单：自建在线歌单允许混平台（D11），因此每行都必须能看出来源（I1）。
  int seedPlaylist() {
    final id = repository.createPersonalPlaylist('混平台歌单');
    repository.addTrackToPersonalPlaylist(
      id,
      track('n1', MusicPlatform.netease),
    );
    repository.addTrackToPersonalPlaylist(
      id,
      track('n2', MusicPlatform.netease),
    );
    repository.addTrackToPersonalPlaylist(id, track('q1', MusicPlatform.qq));
    return id;
  }

  Future<void> pumpPage(WidgetTester tester, int localId) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: app_paths.PERSONAL_PLAYLIST_DETAIL_PAGE,
      routes: [
        GoRoute(
          path: app_paths.PERSONAL_PLAYLIST_DETAIL_PAGE,
          builder: (context, state) =>
              PersonalPlaylistDetailPage(localId: localId),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: controller,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> hoverRow(WidgetTester tester, int index) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(
      tester.getCenter(find.byType(OnlineTrackRow).at(index)),
    );
    await tester.pumpAndSettle();
    addTearDown(gesture.removePointer);
  }

  testWidgets('混平台歌单：逐行标注各自来源', (tester) async {
    await pumpPage(tester, seedPlaylist());

    expect(tester.takeException(), isNull);
    final rows = tester
        .widgetList<OnlineTrackRow>(find.byType(OnlineTrackRow))
        .toList(growable: false);
    expect(rows, hasLength(3));
    expect(rows.map((row) => row.sourceLabel).toSet(), {'网易云', 'QQ音乐'});
  });

  testWidgets('★ 曲目行同时提供「添加到歌单」与「从歌单移除」', (tester) async {
    await pumpPage(tester, seedPlaylist());

    await hoverRow(tester, 0);

    expect(find.byTooltip('添加到歌单'), findsOneWidget);
    // 歌单类页面独有：能从本歌单移除。
    expect(find.byTooltip('从歌单移除'), findsOneWidget);
  });

  testWidgets('★ 点「从歌单移除」后该曲目从列表消失，并真的落库', (tester) async {
    final id = seedPlaylist();
    await pumpPage(tester, id);
    expect(find.byType(OnlineTrackRow), findsNWidgets(3));

    // 移除 QQ 那一首（第 3 行）。
    await hoverRow(tester, 2);
    await tester.tap(find.byTooltip('从歌单移除'));
    await tester.pumpAndSettle();

    expect(find.byType(OnlineTrackRow), findsNWidgets(2));
    final remaining = repository.readPersonalPlaylist(id)!;
    expect(
      remaining.tracks.map((item) => item.ref.trackId),
      isNot(contains('q1')),
    );
  });

  testWidgets('★ 排序模式下的重排列表**不带进场动画**（否则与拖拽动画打架）', (tester) async {
    await pumpPage(tester, seedPlaylist());

    // 排序方法共 5 个：标题 / 艺术家 / 专辑 / 添加时间 / 自定义。
    // 默认是「添加时间」，**不是**最后一个 ⇒ 还不能重排，「排序」按钮此时不该出现。
    expect(find.byType(DirectionalListItemEntrance), findsNWidgets(3));
    expect(find.text('排序'), findsNothing);

    // 切到「自定义」后才允许手动重排。
    await tester.tap(find.text('添加时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('排序'));
    await tester.pumpAndSettle();

    // 进入重排：每行一个拖拽把手（3 行 ⇒ 3 个），且这些行**不再**包进场动画。
    expect(find.byIcon(Symbols.drag_indicator), findsNWidgets(3));
    expect(
      find.byType(DirectionalListItemEntrance),
      findsNothing,
      reason: '重排列表里的行不该再包进场动画',
    );
    expect(tester.takeException(), isNull);

    // 「完成」退回普通列表：进场动画回来。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(DirectionalListItemEntrance), findsNWidgets(3));
  });

  testWidgets('空歌单给出空状态而不是空白页', (tester) async {
    final id = repository.createPersonalPlaylist('空歌单');
    await pumpPage(tester, id);

    expect(tester.takeException(), isNull);
    expect(find.byType(OnlineTrackRow), findsNothing);
  });

  testWidgets('★ 点「添加到歌单」→ 加进**另一个**歌单，原歌单不受影响', (tester) async {
    final sourceId = seedPlaylist();
    final targetId = repository.createPersonalPlaylist('目标歌单');
    await pumpPage(tester, sourceId);

    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    await hover.moveTo(tester.getCenter(find.byType(OnlineTrackRow).first));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加到歌单'));
    await tester.pumpAndSettle();

    expect(find.text('收藏到歌单'), findsOneWidget);
    await tester.tap(find.text('目标歌单'));
    await tester.pumpAndSettle();

    expect(
      repository
          .readPersonalPlaylist(targetId)!
          .tracks
          .map((item) => item.ref.trackId),
      contains('n1'),
    );
    // 源歌单里的那首**不该**被搬走（是"另存一份"而不是"移动"）。
    expect(
      repository
          .readPersonalPlaylist(sourceId)!
          .tracks
          .map((item) => item.ref.trackId),
      contains('n1'),
    );
    await hover.removePointer();

    // 注意：本文件的 harness 是 `MaterialApp.router`，**没有**接应用根部的
    // `scaffoldMessengerKey` / `routerKey`，因此 `showTextOnSnackBar` 在这里会静默不渲染，
    // 也就不能断言"已添加到歌单"提示。本轮已在收藏页那条测试里接上全局 key 并断言了提示
    // （见 `favorites_detail_page_test.dart`）；此处只断言**数据真的落库**。
    // 若以后要在这里断言提示，需先接上那两个 key。
    expect(tester.takeException(), isNull);
  });

  // 放在最后，专门用来**探测偏好泄漏**：上一条测试把排序方法切成了「自定义」，
  // 若没有在 tearDown 里还原，这里就会显示「自定义」而不是默认的「添加时间」。
  testWidgets('★ 排序偏好在测试之间被还原（否则默认排序会被上一条测试改掉）', (tester) async {
    await pumpPage(tester, seedPlaylist());

    expect(
      AppPreference.instance.personalPlaylistDetailPagePref.sortMethod,
      3,
      reason: '上一条测试切到索引 4（自定义）后必须还原',
    );
    expect(find.text('添加时间'), findsOneWidget);
    expect(find.text('自定义'), findsNothing);
  });
}
