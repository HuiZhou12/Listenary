import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late _FakeOnlineMusicService service;
  late OnlinePlaylistController controller;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    service = _FakeOnlineMusicService();
    controller = OnlinePlaylistController(
      repository: Future.value(repository),
      service: service,
    );
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  test('adds a playlist and returns a provider-neutral playback selection', () async {
    service.nextPlaylist = _playlist();

    final saved = await controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '500',
    );
    final selection = await controller.playbackSelection(
      localId: saved!.localId,
      selectedRef: _ref('200'),
    );

    expect(controller.snapshot.status, OnlinePlaylistLoadStatus.ready);
    expect(controller.snapshot.subscriptions, hasLength(1));
    expect(selection!.selectedIndex, 1);
    expect(selection.tracks.map((track) => track.ref.trackId), ['100', '200']);
  });

  test('keeps the previous snapshot when refresh fails', () async {
    service.nextPlaylist = _playlist();
    final saved = await controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '500',
    );
    service.error = const OnlineMusicException(
      kind: OnlineMusicErrorKind.network,
      safeMessage: '网络不可用',
    );

    final refreshed = await controller.refresh(saved!.localId);

    expect(refreshed, isNull);
    expect(controller.snapshot.status, OnlinePlaylistLoadStatus.failed);
    expect(controller.snapshot.subscriptions.single.playlist.name, 'Remote');
    expect(repository.readSubscriptionSnapshot(saved.localId), isNotNull);
  });

  test('ignores a stale request after a newer refresh starts', () async {
    final first = Completer<RemotePlaylist>();
    service.pending.add(first);
    final firstRequest = controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '500',
    );
    await Future<void>.delayed(Duration.zero);

    service.nextPlaylist = _playlist(name: 'Second');
    final secondRequest = controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '500',
    );
    final second = await secondRequest;
    first.complete(_playlist(name: 'First'));
    final ignored = await firstRequest;

    expect(second!.playlist.name, 'Second');
    expect(ignored, isNull);
    expect(controller.snapshot.subscriptions.single.playlist.name, 'Second');
  });
}

final class _FakeOnlineMusicService implements OnlineMusicService {
  final pending = <Completer<RemotePlaylist>>[];
  RemotePlaylist? nextPlaylist;
  Object? error;

  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: [],
    resolvablePlatforms: [MusicPlatform.netease],
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
  }) async {
    if (pending.isNotEmpty) return pending.removeAt(0).future;
    final failure = error;
    if (failure != null) throw failure;
    return nextPlaylist!;
  }

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

PlatformTrackRef _ref(String id) => PlatformTrackRef(
  platform: MusicPlatform.netease,
  trackId: id,
);

MusicTrack _track(String id, String title) => MusicTrack(
  ref: _ref(id),
  title: title,
  artists: const ['Artist'],
);

RemotePlaylist _playlist({String name = 'Remote'}) => RemotePlaylist(
  platform: MusicPlatform.netease,
  id: '500',
  name: name,
  trackCount: 2,
  tracks: [_track('100', 'First'), _track('200', 'Second')],
);
