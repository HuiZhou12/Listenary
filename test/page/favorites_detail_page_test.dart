import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/favorites_detail_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 在线收藏页。
///
/// 这个页面此前**没有任何页面级测试**，而 R2 改了它的行构造（并修掉了"收藏态被硬编码"
/// 的老问题）。这里把该页真正对外承诺的几件事钉住：跨平台逐行标源、
/// **爱心反映真实收藏态**、取消收藏后行消失、以及统一行带来的操作。
void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late PersonalOnlinePlaylistController controller;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    controller = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  MusicTrack track(String id, MusicPlatform platform) => MusicTrack(
    ref: PlatformTrackRef(platform: platform, trackId: id),
    title: '曲目 $id',
    artists: const ['甲'],
    album: '专辑一',
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: controller,
        child: MaterialApp(
          // Toast（`showTextOnSnackBar`）是**经应用根部的全局 key** 渲染的
          // （`scaffoldMessengerKey` + `routerKey.currentState.overlay`）。
          // 不把它们接进来，页面级测试就永远看不到任何提示 —— 那不是产品没提示，是测试看不见。
          navigatorKey: routerKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          home: const FavoritesDetailPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有收藏时给出空状态', (tester) async {
    await pumpPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('还没有收藏'), findsOneWidget);
    expect(find.byType(OnlineTrackRow), findsNothing);
  });

  testWidgets('★ 读取失败 ⇒ 说清原因并给重试（不再谎称"还没有收藏"）', (tester) async {
    // 让底层库真的不可读：关掉库之后 `readFavorites` 会抛。
    // ⚠️ 用**独立**的库与控制器，免得影响本文件其它用例的 setUp/tearDown 组合。
    final brokenDatabase = sqlite3.openInMemory();
    initializeAppDatabase(brokenDatabase);
    final brokenRepository = OnlineLibraryRepository(brokenDatabase);
    final brokenController = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(brokenRepository),
    );
    addTearDown(brokenController.dispose);
    brokenDatabase.dispose();

    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: brokenController,
        child: MaterialApp(
          navigatorKey: routerKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          home: const FavoritesDetailPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 失败必须**与空态分得开**，而且必须能就地重试（F7 / 2026-10-17）。
    expect(find.text('收藏读取失败'), findsOneWidget);
    expect(find.text('无法读取收藏'), findsOneWidget);
    expect(find.text('还没有收藏'), findsNothing, reason: '读不到 ≠ 没有收藏，不能这么说');
    expect(find.text('重试'), findsOneWidget, reason: '失败态必须能就地重试');
    expect(find.byTooltip('刷新'), findsOneWidget);
  });

  testWidgets('★ 收藏是跨平台的：逐行标注各自来源', (tester) async {
    repository.toggleFavorite(track('n1', MusicPlatform.netease));
    repository.toggleFavorite(track('q1', MusicPlatform.qq));

    await pumpPage(tester);

    final rows = tester
        .widgetList<OnlineTrackRow>(find.byType(OnlineTrackRow))
        .toList(growable: false);
    expect(rows, hasLength(2));
    // 来源取自**曲目自己的 ref**（I1）——跨平台收藏不会混成同一个来源。
    expect(
      rows.map((row) => row.sourceLabel).toSet(),
      {'网易云', 'QQ音乐'},
    );
  });

  testWidgets('★ 爱心反映真实收藏态，而不是硬编码', (tester) async {
    final favorite = track('n1', MusicPlatform.netease);
    repository.toggleFavorite(favorite);

    await pumpPage(tester);

    final row = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
    expect(
      row.favorite,
      isTrue,
      reason: '收藏页里的曲目当然处于已收藏态（从前靠硬编码 true，现在来自控制器）',
    );

    // 悬停应显示"取消收藏"而不是"收藏"。
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.moveTo(tester.getCenter(find.byType(OnlineTrackRow)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    expect(find.byTooltip('收藏'), findsNothing);
    await hover.removePointer();
  });

  testWidgets('★ 取消收藏后该行消失（页面监听控制器并刷新快照）', (tester) async {
    final favorite = track('n1', MusicPlatform.netease);
    repository.toggleFavorite(favorite);
    await pumpPage(tester);
    expect(find.byType(OnlineTrackRow), findsOneWidget);

    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.moveTo(tester.getCenter(find.byType(OnlineTrackRow)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消收藏'));
    await tester.pumpAndSettle();
    await hover.removePointer();

    expect(controller.isFavorite(favorite.ref), isFalse);
    expect(find.byType(OnlineTrackRow), findsNothing);
    expect(find.text('还没有收藏'), findsOneWidget);
  });

  testWidgets('曲目行提供「添加到歌单」（R2 统一化后的结果）', (tester) async {
    repository.toggleFavorite(track('n1', MusicPlatform.netease));
    await pumpPage(tester);

    expect(find.byTooltip('添加到歌单'), findsNothing);

    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.moveTo(tester.getCenter(find.byType(OnlineTrackRow)));
    await tester.pumpAndSettle();

    expect(find.byTooltip('添加到歌单'), findsOneWidget);
    await hover.removePointer();
  });

  testWidgets('★ 点「添加到歌单」→ 选歌单 → 真的落库并提示（这条用户路径此前没测过）', (
    tester,
  ) async {
    final favorite = track('n1', MusicPlatform.netease);
    repository.toggleFavorite(favorite);
    final playlistId = repository.createPersonalPlaylist('我的歌单');
    await pumpPage(tester);

    // 悬停出现操作，再点进去。
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    await hover.moveTo(tester.getCenter(find.byType(OnlineTrackRow)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加到歌单'));
    await tester.pumpAndSettle();

    // 弹窗列出可选歌单（这里只走到"弹窗真的出现"是不够的，下面要断言真的加进去了）。
    expect(find.text('收藏到歌单'), findsOneWidget);
    expect(find.text('我的歌单'), findsOneWidget);

    await tester.tap(find.text('我的歌单'));
    await tester.pumpAndSettle();

    expect(
      repository
          .readPersonalPlaylist(playlistId)!
          .tracks
          .map((item) => item.ref.trackId),
      contains('n1'),
      reason: '点了就必须要真的进歌单，不能只弹一个窗',
    );
    expect(find.text('已添加到歌单'), findsOneWidget);
    await hover.removePointer();

    // Toast 自带 2 秒自动消失的 Timer：必须让它跑完，否则测试框架会以
    // "A Timer is still pending even after the widget tree was disposed" 报错。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  // ------------------------------------------------------------------ 页内功能

  List<String> rowTitles(WidgetTester tester) => tester
      .widgetList<OnlineTrackRow>(find.byType(OnlineTrackRow))
      .map((row) => row.track.title)
      .toList(growable: false);

  testWidgets('搜索按标题/艺人/专辑过滤，清空后恢复', (tester) async {
    for (final title in ['Gamma', 'Alpha', 'Beta']) {
      repository.toggleFavorite(
        MusicTrack(
          ref: PlatformTrackRef(
            platform: MusicPlatform.netease,
            trackId: title,
          ),
          title: title,
          artists: const ['甲'],
          album: '专辑一',
        ),
      );
    }
    await pumpPage(tester);
    expect(rowTitles(tester), hasLength(3));

    await tester.enterText(find.byType(TextField).first, 'Beta');
    await tester.pumpAndSettle();
    expect(rowTitles(tester), ['Beta']);

    // 按艺人也能搜到。
    await tester.enterText(find.byType(TextField).first, '甲');
    await tester.pumpAndSettle();
    expect(rowTitles(tester), hasLength(3));

    // 大小写不敏感。
    await tester.enterText(find.byType(TextField).first, 'gamma');
    await tester.pumpAndSettle();
    expect(rowTitles(tester), ['Gamma']);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(rowTitles(tester), hasLength(3));
  });

  testWidgets('搜索无匹配时列表为空（不是回到全部）', (tester) async {
    repository.toggleFavorite(track('n1', MusicPlatform.netease));
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField).first, '不存在的关键词');
    await tester.pumpAndSettle();

    expect(find.byType(OnlineTrackRow), findsNothing);
  });

  testWidgets('★ 切换排序方法真的改变行的顺序', (tester) async {
    // 加入顺序：Gamma → Alpha → Beta（默认按「添加时间」⇒ 就是这个顺序）。
    for (final title in ['Gamma', 'Alpha', 'Beta']) {
      repository.toggleFavorite(
        MusicTrack(
          ref: PlatformTrackRef(
            platform: MusicPlatform.netease,
            trackId: title,
          ),
          title: title,
          artists: const ['甲'],
          album: '专辑一',
        ),
      );
    }
    await pumpPage(tester);

    // 默认排序方法（索引 3 = 添加时间）。
    expect(find.text('添加时间'), findsOneWidget);
    expect(rowTitles(tester).first, 'Gamma');

    await tester.tap(find.text('添加时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题'));
    await tester.pumpAndSettle();

    // 按标题升序：Alpha 提到最前。
    expect(rowTitles(tester).first, 'Alpha');
    expect(find.text('标题'), findsOneWidget);
  });

  testWidgets('★ 播放全部：有可播放曲目时可用，全都不可播放时禁用', (tester) async {
    repository.toggleFavorite(track('n1', MusicPlatform.netease));
    await pumpPage(tester);

    var button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('播放全部'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNotNull);

    // 全都是付费曲目 ⇒ 没有可播放项 ⇒ 按钮禁用（而不是点了没反应）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    // 先把那首可播放的收藏取消掉，否则 playable 不为空、这个分支根本走不到。
    // （直接改仓储不会再通知控制器，因此下面只断言**渲染结果**，不读控制器的内存缓存。）
    repository.toggleFavorite(track('n1', MusicPlatform.netease));
    repository.toggleFavorite(
      MusicTrack(
        ref: const PlatformTrackRef(
          platform: MusicPlatform.netease,
          trackId: 'paid',
        ),
        title: '付费曲目',
        artists: const ['甲'],
        availability: TrackAvailability.paid,
      ),
    );
    await pumpPage(tester);

    // 只剩那首付费曲目（可播放的那首已被取消收藏）。
    expect(rowTitles(tester), ['付费曲目']);
    button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('播放全部'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
