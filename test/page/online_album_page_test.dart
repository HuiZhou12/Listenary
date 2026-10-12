import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_album_page.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:sqlite3/sqlite3.dart';

/// **在线专辑页**（2026-10-12 新增）：
/// - 头部是专辑（封面/名字/专辑艺人）；
/// - 曲目**列出序号**（专辑是有序集合 ✓，与参考产品一致）；
/// - 三态如实区分：**失败**⇒错误+重试；**空**⇒中性提示、**不给重试**；
/// - 平台标注的曲目数**只在与实际条数不一致**时说（不把两个数混成一个 ✓）。
void main() {
  late Database database;
  late PersonalOnlinePlaylistController personalController;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    personalController = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(OnlineLibraryRepository(database)),
    );
  });
  tearDown(() {
    personalController.dispose();
    database.dispose();
  });

  Future<void> pumpAlbum(
    WidgetTester tester,
    OnlineMusicService service, {
    String? initialName,
  }) => tester.pumpWidget(
    ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
      value: personalController,
      child: Provider<OnlineMusicService>.value(
        value: service,
        child: MaterialApp(
          home: OnlineAlbumPage(
            platform: MusicPlatform.netease,
            albumId: '93113910',
            initialName: initialName,
          ),
        ),
      ),
    ),
  );

  Future<void> settle(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('等不到 ${finder.describeMatch(Plurality.one)}');
  }

  MusicTrack track(String id, String title) => MusicTrack(
    ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
    title: title,
    artists: const ['阿YueYue'],
    artistIds: const ['12227865'],
    albumIds: const ['93113910'],
  );

  testWidgets('显示专辑名/专辑艺人，曲目**带行首序号**', (tester) async {
    final service = _FakeAlbumService(
      OnlineAlbum(
        platform: MusicPlatform.netease,
        id: '93113910',
        name: '故里逢春',
        artist: '阿YueYue',
        artistId: '12227865',
        trackCount: 2,
        releaseTime: DateTime.utc(2020, 7, 29),
        tracks: [track('1', '故里逢春'), track('2', '第二首')],
      ),
    );

    await pumpAlbum(tester, service);
    await settle(tester, find.text('故里逢春'));

    expect(find.text('故里逢春'), findsWidgets);
    expect(find.text('阿YueYue'), findsWidgets);
    expect(find.text('曲目'), findsOneWidget);
    // 专辑曲目是**有序集合** ⇒ 序号必须真的渲染出来 ✓（1、2）。
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    // 平台标注数 == 实际条数 ⇒ **不出现**那句差异提示 ✓。
    expect(find.textContaining('平台标注这张专辑有'), findsNothing);
    // 发行时间只显示**年份** ✓（不写具体日期：毫秒时间戳按 UTC 判定，日期可能差一天 ✓）。
    expect(find.textContaining('2020 年'), findsOneWidget);
    expect(find.textContaining('2020-07-29'), findsNothing);
    // 有专辑艺人 id ⇒ 艺人名可点（参考产品的专辑页里艺人名就是链接 ✓）；
    // 曲目行里的艺人段同样可点 ⇒ 一共 1（头部）+ 2（两行）= 3 个入口 ✓。
    expect(find.byTooltip('查看艺人'), findsNWidgets(3));
  });

  testWidgets('平台标注曲目数 ≠ 实际条数 ⇒ 如实说出来（以实际为准）', (tester) async {
    final service = _FakeAlbumService(
      OnlineAlbum(
        platform: MusicPlatform.netease,
        id: '93113910',
        name: '故里逢春',
        trackCount: 12,
        tracks: [track('1', '故里逢春')],
      ),
    );

    await pumpAlbum(tester, service);
    await settle(tester, find.textContaining('平台标注这张专辑有'));

    expect(find.textContaining('平台标注这张专辑有 12 首'), findsOneWidget);
    expect(find.textContaining('实际取到 1 首'), findsOneWidget);
  });

  testWidgets('曲目为空 ⇒ 中性提示、**不给重试**（空是合法的）', (tester) async {
    final service = _FakeAlbumService(
      OnlineAlbum(
        platform: MusicPlatform.netease,
        id: '93113910',
        name: '空专辑',
        tracks: const [],
      ),
    );

    await pumpAlbum(tester, service);
    await settle(tester, find.text('这张专辑暂时没有曲目。'));

    expect(find.text('这张专辑暂时没有曲目。'), findsOneWidget);
    expect(find.text('重试'), findsNothing, reason: '空 ≠ 失败：空态不该给重试');
  });

  testWidgets('读取失败 ⇒ 展示可读错误 + 重试', (tester) async {
    final service = _FakeAlbumService.failing(
      const OnlineMusicException(
        kind: OnlineMusicErrorKind.network,
        safeMessage: '网络不可用',
      ),
    );

    await pumpAlbum(tester, service);
    await settle(tester, find.text('网络不可用'));

    expect(find.text('网络不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('加载中先用曲目行给的专辑名占位（不白屏）', (tester) async {
    final service = _FakeAlbumService(
      OnlineAlbum(
        platform: MusicPlatform.netease,
        id: '93113910',
        name: '故里逢春',
        tracks: const [],
      ),
    );

    await pumpAlbum(tester, service, initialName: '故里逢春（已知名）');
    expect(find.text('故里逢春（已知名）'), findsOneWidget);
  });
}

/// 极简假件：只实现页面用到的成员，其余交给 `noSuchMethod`（Dart 允许 ✓）。
final class _FakeAlbumService implements OnlineMusicService {
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
  _FakeAlbumService(this.album) : failure = null;
  _FakeAlbumService.failing(this.failure) : album = null;

  final OnlineAlbum? album;
  final Object? failure;

  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
  );

  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    if (failure != null) throw failure!;
    return album!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}
