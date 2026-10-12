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

/// **「新发行」页**（2026-10-12 新增 ✓）。
///
/// 依据：参考 Explore 第一个区块的「更多」→ 一个 H1 为「**专辑和单曲**」的落地页 ✓
///（`09-new-releases-albums-full.txt:49` ✓，且**页内没有「加载更多」** ✓）。
/// 我们的落地页与它同类：按平台分组，先「新专辑」再「新歌」✓；专辑行以「专辑 · 年份 · N 首」
/// 自报家门 ✓（与搜索结果**共用同一个组件** ✓）。
void main() {
  testWidgets('「新发行」页：标题是「专辑和单曲」，两个区块都在且各自标出平台', (tester) async {
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
          value: _NewReleasesService(),
          child: const MaterialApp(
            home: Scaffold(body: NewReleasesPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('专辑和单曲'), findsOneWidget);
    expect(find.text('新专辑'), findsOneWidget);
    expect(find.text('新歌'), findsOneWidget);
    // 专辑行：类型前缀 + 平台声明的事实 ✓（与搜索结果同一个组件 ✓）。
    expect(find.text('故里逢春'), findsOneWidget);
    expect(find.textContaining('专辑 · 2020 年 · 2 首'), findsOneWidget);
    // 曲目行：标题 + 来源 ✓。
    expect(find.text('新歌一'), findsOneWidget);
    expect(find.text('网易云'), findsWidgets);
    // 参考页里**没有**「加载更多」✓ ⇒ 我们也不给 ✗。
    expect(find.text('加载更多'), findsNothing);
    expect(find.text('没有更多了'), findsNothing);
  });

  testWidgets('平台都没有相应能力 ⇒ 两个区块都不出现（不摆空区块）', (tester) async {
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
          value: _NewReleasesService(supported: false),
          child: const MaterialApp(
            home: Scaffold(body: NewReleasesPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('专辑和单曲'), findsOneWidget);
    expect(find.text('新专辑'), findsNothing);
    expect(find.text('新歌'), findsNothing);
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
      ref: const PlatformTrackRef(
        platform: MusicPlatform.netease,
        trackId: 'n1',
      ),
      title: '新歌一',
      artists: const ['甲'],
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}
