import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/new_releases_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// **「新专辑」与「新歌」两个落地页**（2026-10-17 从「专辑和单曲」单页拆开 ✓）。
///
/// 拆开的理由有两条，都要钉住：
/// 1. 合在一页时**页标题 + 区块标题**叠在一起（同一个层级出现两次标题）——现在每页只有一层；
/// 2. 探索页两个「查看全部」此前**落到同一页**，点「新歌」先看到「新专辑」——
///    现在一页只放一类内容。
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget page, {
    bool supported = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 1400);
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

    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: favorites,
        child: Provider<OnlineMusicService?>.value(
          value: _NewReleasesService(supported: supported),
          child: MaterialApp(home: Scaffold(body: page)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('★ 新专辑页：只有一层标题，且不含「新歌」内容', (tester) async {
    await pump(tester, const NewAlbumsPage());

    // **标题只出现一次** ✓（拆页前是"页标题 + 区块标题"两遍）。
    expect(find.text('新专辑'), findsOneWidget);
    expect(find.text('新歌'), findsNothing, reason: '新专辑页不该出现另一类内容');
    expect(find.text('专辑和单曲'), findsNothing, reason: '合并页的旧标题已不存在');
    // 内容：专辑行以「专辑 · 年份 · N 首」自报家门（与搜索结果同一个组件）。
    expect(find.text('故里逢春'), findsOneWidget);
    expect(find.textContaining('专辑 · 2020 年 · 2 首'), findsOneWidget);
    // 参考页里**没有**「加载更多」✓。
    expect(find.text('加载更多'), findsNothing);
    expect(find.text('没有更多了'), findsNothing);
  });

  testWidgets('★ 新歌页：只有一层标题，且不含专辑内容', (tester) async {
    await pump(tester, const NewSongsPage());

    expect(find.text('新歌'), findsOneWidget);
    expect(find.text('新专辑'), findsNothing, reason: '新歌页不该出现另一个区块');
    expect(find.text('专辑和单曲'), findsNothing, reason: '合并页的旧标题已不存在');
    expect(find.text('新歌一'), findsOneWidget);
    expect(find.text('网易云'), findsWidgets);
  });

  testWidgets('平台没有相应能力 ⇒ 各自给出中性说明（不摆空区块）', (tester) async {
    await pump(tester, const NewAlbumsPage(), supported: false);
    expect(find.text('新专辑'), findsOneWidget, reason: '标题仍在');
    expect(find.textContaining('当前没有能提供新专辑的平台'), findsOneWidget);
    expect(find.text('故里逢春'), findsNothing);

    await pump(tester, const NewSongsPage(), supported: false);
    expect(find.text('新歌'), findsOneWidget);
    expect(find.textContaining('当前没有能播放新歌的平台'), findsOneWidget);
    expect(find.text('新歌一'), findsNothing);
  });
}

/// 极简假件：只实现本页要用的成员，其余交给 `noSuchMethod`（Dart 允许 ✓）。
final class _NewReleasesService implements OnlineMusicService {
  _NewReleasesService({this.supported = true});

  final bool supported;

  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [MusicPlatform.netease],
    resolvablePlatforms: supported ? const [MusicPlatform.netease] : const [],
    albumPlatforms: supported ? const [MusicPlatform.netease] : const [],
    newAlbumPlatforms: supported ? const [MusicPlatform.netease] : const [],
    newSongPlatforms: supported ? const [MusicPlatform.netease] : const [],
  );

  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
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
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    MusicTrack(
      ref: const PlatformTrackRef(platform: MusicPlatform.netease, trackId: 'n1'),
      title: '新歌一',
      artists: const ['甲'],
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}
