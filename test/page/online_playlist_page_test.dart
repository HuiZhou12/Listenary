import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_playlist_detail_page.dart';
import 'package:pure_music/page/online_playlists_page.dart';
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
      repository: Future.value(repository),
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
    'detail page renders the stored track snapshot without edit tools',
    (tester) async {
      final saved = repository.replaceSubscriptionSnapshot(_playlist());

      await _pump(
        tester,
        controller,
        OnlinePlaylistDetailPage(localId: saved.localId),
      );
      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(find.byTooltip('编辑'), findsNothing);
    },
  );
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
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  void dispose() {}
}

RemotePlaylist _playlist() => RemotePlaylist(
  platform: MusicPlatform.netease,
  id: '500',
  name: 'Remote Playlist',
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
