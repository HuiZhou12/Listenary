import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/online_playlist_detail_page.dart';
import 'package:pure_music/page/online_playlists_page.dart';
import 'package:pure_music/page/playlists_page.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late OnlinePlaylistController controller;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    controller = OnlinePlaylistController(
      repository: SynchronousFuture(repository),
      service: _FakeOnlineMusicService(),
    );
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  testWidgets('empty subscription view exposes the add action', (tester) async {
    await _pump(tester, controller, const OnlinePlaylistsPage());

    await tester.tap(find.byTooltip('添加在线歌单'));
    await tester.pump();
    expect(find.text('网易歌单 ID'), findsOneWidget);
  });

  testWidgets('subscription list shows safe metadata and read-only actions', (
    tester,
  ) async {
    repository.replaceSubscriptionSnapshot(_playlist());

    await _pump(tester, controller, const OnlinePlaylistsPage());

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
        OnlinePlaylistDetailPage(localId: saved.localId),
      );
      await _pumpUntilFound(tester, find.byType(RemoteMediaCover));

      expect(tester.takeException(), isNull);
      expect(find.text('Remote Playlist'), findsOneWidget);
      expect(find.text('Remote Creator'), findsOneWidget);
      expect(find.text('1 首歌曲 · 只读订阅'), findsOneWidget);
      expect(find.text('播放全部'), findsOneWidget);
      expect(find.byTooltip('随机播放'), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(find.byTooltip('编辑'), findsNothing);
      final cover = tester
          .widgetList<RemoteMediaCover>(find.byType(RemoteMediaCover))
          .singleWhere((widget) => widget.coverUri == _playlistCoverUri);
      expect(cover.coverUri, _playlistCoverUri);
    },
  );

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
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _pumpUntilFound(tester, find.text('Remote Playlist'));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Remote Playlist'));
    await _pumpUntilFound(tester, find.text('Remote Creator'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(OnlinePlaylistDetailPage), findsOneWidget);
    expect(find.text('Remote Creator'), findsOneWidget);
    expect(find.text('播放全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail header remains valid at compact width', (tester) async {
    final saved = repository.replaceSubscriptionSnapshot(_playlist());
    await controller.loadSubscriptions();
    await tester.binding.setSurfaceSize(const Size(420, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pump(
      tester,
      controller,
      OnlinePlaylistDetailPage(localId: saved.localId),
    );
    await _pumpUntilFound(tester, find.byType(RemoteMediaCover));

    expect(find.text('Remote Playlist'), findsOneWidget);
    expect(find.byTooltip('随机播放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  OnlinePlaylistController controller,
  Widget child,
) {
  return tester.pumpWidget(
    ChangeNotifierProvider<OnlinePlaylistController>.value(
      value: controller,
      child: MaterialApp(home: Scaffold(body: child)),
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
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: [],
    resolvablePlatforms: [],
    playlistPlatforms: [MusicPlatform.netease],
  );

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
  }) async => _playlist();

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('lyrics');

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  void dispose() {}
}

final _playlistCoverUri = Uri.parse('https://cover.invalid/playlist.jpg');

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
