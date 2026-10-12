import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_artist_page.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:sqlite3/sqlite3.dart';

/// **在线艺人页**（2026-10-12 新增）：
/// - 头部是艺人（名字 / 简介），下面是**热门歌曲**；
/// - 三态如实区分：**失败**⇒错误+重试；**空**（该艺人确实没有热门曲目）⇒中性提示、**不给重试**；
/// - 曲目带 `artistIds` 时，详情行**可点**（提示「查看艺人」✓）；没带就保持纯文本 ✓。
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

  Future<void> pumpArtist(
    WidgetTester tester,
    OnlineMusicService service, {
    String? initialName,
  }) => tester.pumpWidget(
    ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
      value: personalController,
      child: Provider<OnlineMusicService>.value(
        value: service,
        child: MaterialApp(
          home: OnlineArtistPage(
            platform: MusicPlatform.netease,
            artistId: '7763',
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

  testWidgets('显示艺人名字/简介与热门曲目；带艺人 id 的行可点（提示「查看艺人」）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'G.E.M.邓紫棋',
        description: '香港女创作歌手',
        hotSongs: [
          MusicTrack(
            ref: const PlatformTrackRef(platform: MusicPlatform.netease, trackId: '1'),
            title: '光年之外',
            artists: ['G.E.M.邓紫棋'],
            artistIds: ['7763'],
          ),
          MusicTrack(
            ref: const PlatformTrackRef(platform: MusicPlatform.netease, trackId: '2'),
            title: '泡沫',
            artists: ['G.E.M.邓紫棋'],
            artistIds: ['7763'],
          ),
        ],
      ),
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('光年之外'));

    expect(find.text('G.E.M.邓紫棋'), findsWidgets);
    expect(find.text('香港女创作歌手'), findsOneWidget);
    expect(find.text('光年之外'), findsOneWidget);
    expect(find.text('泡沫'), findsOneWidget);
    expect(find.text('热门歌曲'), findsOneWidget);
    // 带艺人 id ⇒ 有"查看艺人"入口 ✓（没有 id 时不会出现，见下一条）。
    expect(find.byTooltip('查看艺人'), findsNWidgets(2));
  });

  testWidgets('曲目**没有** artistIds 时，详情行不给可点（不猜 ✓）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'Beyond',
        hotSongs: [
          MusicTrack(
            ref: const PlatformTrackRef(platform: MusicPlatform.netease, trackId: '9'),
            title: '灰色轨迹',
            artists: ['Beyond'],
          ),
        ],
      ),
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('灰色轨迹'));

    expect(find.byTooltip('查看艺人'), findsNothing);
  });

  testWidgets('热门曲目为空 ⇒ 中性提示、**不给重试**（空是合法的）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'Beyond',
        hotSongs: [],
      ),
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('该艺人暂时没有热门曲目。'));

    expect(find.text('该艺人暂时没有热门曲目。'), findsOneWidget);
    expect(find.text('重试'), findsNothing, reason: '空 ≠ 失败：空态不该给重试');
  });

  testWidgets('读取失败 ⇒ 展示可读错误 + 重试（与空态分开）', (tester) async {
    final service = _FakeArtistService.failing(
      const OnlineMusicException(
        kind: OnlineMusicErrorKind.network,
        safeMessage: '网络不可用',
      ),
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('网络不可用'));

    expect(find.text('网络不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('该艺人暂时没有热门曲目。'), findsNothing);
  });

  testWidgets('加载中先用曲目行给的显示名占位（不白屏）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'Beyond',
        hotSongs: [],
      ),
    );

    await pumpArtist(tester, service, initialName: 'Beyond（已知名）');
    // 首帧（还没 settle）就应该能看到已知名。
    expect(find.text('Beyond（已知名）'), findsOneWidget);
  });

  testWidgets('平台支持时显示「专辑」区块（参考顺序：热门歌曲 → 专辑）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'G.E.M.邓紫棋',
        hotSongs: [track('1', '光年之外')],
      ),
      albums: [
        OnlineAlbumSummary(
          platform: MusicPlatform.netease,
          id: '398617121',
          name: '新的心跳',
          trackCount: 10,
          releaseTime: DateTime.utc(2015, 11, 6),
        ),
      ],
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('专辑'));

    // 参考艺人页里「专辑」是**热门歌曲之后**的下一个区块 ✓。
    expect(find.text('热门歌曲'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('新的心跳'), findsOneWidget);
    // 卡片元信息只写**平台声明**的事实：年份 + 曲目数 ✓。
    expect(find.textContaining('2015 年'), findsOneWidget);
    expect(find.textContaining('10 首'), findsOneWidget);
  });

  testWidgets('平台**不支持**艺人专辑列表 ⇒ 整块不显示（不摆空区块骗人）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'Beyond',
        hotSongs: [track('9', '灰色轨迹')],
      ),
      albumsSupported: false,
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('热门歌曲'));

    expect(
      find.text('专辑'),
      findsNothing,
      reason: '不支持却摆一个空区块 ⇒ 会让人以为"这艺人没有专辑"（那是谎 ✗）',
    );
  });

  testWidgets('平台支持时显示「单曲和迷你专辑」区块（参考顺序：… → 专辑 → 单曲）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'G.E.M.邓紫棋',
        hotSongs: [track('1', '光年之外')],
      ),
      songs: [track('2', '唯一'), track('3', '泡沫')],
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('单曲和迷你专辑'));

    expect(find.text('热门歌曲'), findsOneWidget);
    expect(find.text('单曲和迷你专辑'), findsOneWidget);
    expect(find.text('唯一'), findsOneWidget);
    expect(find.text('泡沫'), findsOneWidget);
  });

  testWidgets('平台**不支持**艺人单曲列表 ⇒ 整块不显示（不摆空区块骗人）', (tester) async {
    final service = _FakeArtistService(
      OnlineArtist(
        platform: MusicPlatform.netease,
        id: '7763',
        name: 'Beyond',
        hotSongs: [track('9', '灰色轨迹')],
      ),
      songsSupported: false,
    );

    await pumpArtist(tester, service);
    await settle(tester, find.text('热门歌曲'));

    expect(
      find.text('单曲和迷你专辑'),
      findsNothing,
      reason: '不支持却摆空区块 ⇒ 会让人以为"这艺人没有单曲"（那是谎 ✗）',
    );
  });
}

/// 一行测试曲目（带艺人 id ⇒ 详情行的艺人段可点 ✓）。
MusicTrack track(String id, String title) => MusicTrack(
  ref: const PlatformTrackRef(platform: MusicPlatform.netease, trackId: '1'),
  title: title,
  artists: const ['G.E.M.邓紫棋'],
  artistIds: const ['7763'],
  albumIds: const ['398617121'],
);

/// 极简假件：只实现页面用到的成员，其余交给 `noSuchMethod`（Dart 允许 ✓）。
final class _FakeArtistService implements OnlineMusicService {
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
  _FakeArtistService(
    this.artist, {
    this.albums = const [],
    this.songs = const [],
    this.albumsSupported = true,
    this.songsSupported = true,
  }) : failure = null;

  _FakeArtistService.failing(this.failure)
    : artist = null,
      albums = const [],
      songs = const [],
      albumsSupported = true,
      songsSupported = true;

  final OnlineArtist? artist;
  final List<OnlineAlbumSummary> albums;
  final List<MusicTrack> songs;

  /// `false` ⇒ 能力集合里**不声明**该能力 ⇒ 页面应**整块不显示** ✓。
  final bool albumsSupported;
  final bool songsSupported;
  final Object? failure;

  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [MusicPlatform.netease],
    albumPlatforms: albumsSupported ? const [MusicPlatform.netease] : const [],
    artistAlbumPlatforms: albumsSupported
        ? const [MusicPlatform.netease]
        : const [],
    artistSongPlatforms: songsSupported
        ? const [MusicPlatform.netease]
        : const [],
  );

  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => songs;

  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => albums;

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
  }) async {
    if (failure != null) throw failure!;
    return artist!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}
