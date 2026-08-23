import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
  });

  tearDown(() {
    database.dispose();
  });

  test('upserts and reads safe track metadata with ordered artists', () {
    final updatedAt = DateTime.utc(2026, 8, 17, 10);
    repository.upsertTrack(
      _track(
        id: ' 100 ',
        title: ' Track ',
        artists: const [' First ', 'Second'],
      ),
      lastQuality: ' lossless ',
      updatedAt: updatedAt,
    );

    final stored = repository.findTrack(_ref('100'))!;
    expect(stored.title, 'Track');
    expect(stored.artists, ['First', 'Second']);
    expect(stored.album, 'Album');
    expect(stored.coverUri, Uri.https('example.test', '/cover.jpg'));
    expect(stored.duration, const Duration(minutes: 3));
    expect(stored.availability, TrackAvailability.playable);
    expect(
      database
          .select('SELECT last_quality FROM online_tracks')
          .single['last_quality'],
      'lossless',
    );
  });

  test('partial metadata does not erase richer stored values', () {
    repository.upsertTrack(_track(id: '100'));
    repository.upsertTrack(
      MusicTrack(ref: _ref('100'), title: 'Renamed', artists: const []),
    );

    final stored = repository.findTrack(_ref('100'))!;
    expect(stored.title, 'Renamed');
    expect(stored.artists, ['Artist']);
    expect(stored.album, 'Album');
    expect(stored.coverUri, Uri.https('example.test', '/cover.jpg'));
    expect(stored.duration, const Duration(minutes: 3));
    expect(stored.availability, TrackAvailability.playable);
  });

  test('rejects invalid track identity, title, duration and cover URI', () {
    expect(() => repository.upsertTrack(_track(id: ' ')), throwsArgumentError);
    expect(
      () => repository.upsertTrack(_track(id: '1', title: ' ')),
      throwsArgumentError,
    );
    expect(
      () => repository.upsertTrack(
        _track(id: '1', duration: const Duration(seconds: -1)),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsertTrack(
        _track(id: '1', coverUri: Uri.file('cover.jpg')),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsertTrack(
        _track(
          id: '1',
          coverUri: Uri.parse('https://example.test/cover.jpg?apiKey=secret'),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => repository.upsertTrack(
        _track(id: '1'),
        lastQuality: 'https://example.test/stream',
      ),
      throwsArgumentError,
    );
    expect(database.select('SELECT * FROM online_tracks'), isEmpty);
  });

  test('records recent history without resetting play count', () {
    final firstTime = DateTime.utc(2026, 8, 17, 10);
    final secondTime = DateTime.utc(2026, 8, 17, 11);
    repository.recordPlaybackStarted(
      _track(id: '100'),
      lastQuality: 'lossless',
      playedAt: firstTime,
    );
    expect(repository.incrementPlayCount(_ref('100')), isTrue);

    repository.recordPlaybackStarted(
      _track(id: '200', title: 'Second'),
      playedAt: secondTime,
    );
    repository.recordPlaybackStarted(
      _track(id: '100'),
      playedAt: secondTime.add(const Duration(minutes: 1)),
    );

    final recent = repository.recentHistory();
    expect(recent.map((entry) => entry.track.ref.trackId), ['100', '200']);
    expect(recent.first.playCount, 1);
    expect(recent.first.lastQuality, 'lossless');
    expect(repository.topPlayed().first.track.ref.trackId, '100');
    expect(repository.incrementPlayCount(_ref('missing')), isFalse);
  });

  test('trims old history and removes unreferenced track metadata', () {
    repository.recordPlaybackStarted(
      _track(id: '100'),
      playedAt: DateTime.utc(2026, 8, 17, 10),
      historyLimit: 2,
    );
    repository.recordPlaybackStarted(
      _track(id: '200'),
      playedAt: DateTime.utc(2026, 8, 17, 11),
      historyLimit: 2,
    );
    repository.recordPlaybackStarted(
      _track(id: '300'),
      playedAt: DateTime.utc(2026, 8, 17, 12),
      historyLimit: 2,
    );

    expect(defaultOnlineHistoryLimit, 1000);
    expect(repository.recentHistory().map((entry) => entry.track.ref.trackId), [
      '300',
      '200',
    ]);
    expect(repository.findTrack(_ref('100')), isNull);
  });

  test('retains metadata referenced by a playlist when history is cleared', () {
    repository.recordPlaybackStarted(
      _track(id: '100'),
      playedAt: DateTime.utc(2026, 8, 17, 10),
    );
    database.execute(
      'INSERT INTO online_playlists('
      'kind, name, created_at, updated_at) '
      "VALUES('personal', 'Saved', '2026-08-17T10:00:00.000Z', "
      "'2026-08-17T10:00:00.000Z')",
    );
    database.execute(
      'INSERT INTO online_playlist_items('
      'playlist_id, platform, track_id, sort_order, added_at) '
      "VALUES(?, 'netease', '100', 0, '2026-08-17T10:00:00.000Z')",
      [database.lastInsertRowId],
    );
    repository.recordPlaybackStarted(
      _track(id: '200'),
      playedAt: DateTime.utc(2026, 8, 17, 11),
    );

    repository.clearHistory();

    expect(repository.recentHistory(), isEmpty);
    expect(repository.findTrack(_ref('100')), isNotNull);
    expect(repository.findTrack(_ref('200')), isNull);
  });

  test('creates, deduplicates and reads an ordered subscription snapshot', () {
    final refreshedAt = DateTime.utc(2026, 8, 18, 10);
    final first = repository.replaceSubscriptionSnapshot(
      _playlist(),
      refreshedAt: refreshedAt,
    );
    final second = repository.replaceSubscriptionSnapshot(
      _playlist(name: 'Renamed'),
      refreshedAt: refreshedAt.add(const Duration(minutes: 1)),
    );

    expect(first.localId, second.localId);
    expect(repository.listSubscriptions(), hasLength(1));
    final stored = repository.readSubscriptionSnapshot(first.localId)!;
    expect(stored.playlist.name, 'Renamed');
    expect(stored.playlist.tracks.map((track) => track.ref.trackId), [
      '100',
      '200',
    ]);
    expect(stored.lastRefreshedAt, refreshedAt.add(const Duration(minutes: 1)));
    expect(
      repository
          .findSubscription(
            platform: MusicPlatform.netease,
            remotePlaylistId: '500',
          )!
          .localId,
      first.localId,
    );
  });

  test('rolls back invalid replacement and keeps the previous snapshot', () {
    final original = repository.replaceSubscriptionSnapshot(_playlist());
    expect(
      () => repository.replaceSubscriptionSnapshot(_playlist(trackCount: 1)),
      throwsArgumentError,
    );

    final stored = repository.readSubscriptionSnapshot(original.localId)!;
    expect(stored.playlist.name, 'Remote Playlist');
    expect(stored.playlist.tracks, hasLength(2));
  });

  test('deletes a subscription without retaining unreferenced metadata', () {
    repository.replaceSubscriptionSnapshot(_playlist());

    expect(
      repository.deleteSubscription(
        platform: MusicPlatform.netease,
        remotePlaylistId: '500',
      ),
      isTrue,
    );
    expect(repository.listSubscriptions(), isEmpty);
    expect(repository.findTrack(_ref('100')), isNull);
    expect(
      repository.deleteSubscription(
        platform: MusicPlatform.netease,
        remotePlaylistId: '500',
      ),
      isFalse,
    );
  });

  group('personal online playlists', () {
    test('creates, renames and lists personal playlists with unique names', () {
      final idA = repository.createPersonalPlaylist('  我的歌单 ');
      final idB = repository.createPersonalPlaylist('另一个');

      expect(idA, greaterThan(0));
      expect(repository.listPersonalPlaylists().map((p) => p.name), [
        '另一个',
        '我的歌单',
      ]);
      expect(repository.listPersonalPlaylists().first.tracks, isEmpty);

      // 大小写不敏感重名冲突。
      expect(
        () => repository.createPersonalPlaylist('我的歌单'),
        throwsArgumentError,
      );
      expect(
        () => repository.createPersonalPlaylist('  我的歌单  '),
        throwsArgumentError,
      );
      expect(
        () => repository.createPersonalPlaylist('   '),
        throwsArgumentError,
      );

      expect(repository.renamePersonalPlaylist(idA, '重命名后'), isTrue);
      expect(repository.readPersonalPlaylist(idA)!.name, '重命名后');
      // 与自身冲突视为重名冲突。
      expect(repository.renamePersonalPlaylist(idB, '重命名后'), isFalse);
    });

    test('adds tracks idempotently in order and reads them back', () {
      final id = repository.createPersonalPlaylist('歌单');

      expect(
        repository.addTrackToPersonalPlaylist(id, _track(id: '1')),
        isTrue,
      );
      expect(
        repository.addTrackToPersonalPlaylist(id, _track(id: '2')),
        isTrue,
      );
      // 幂等重复添加不重复、不重排。
      expect(
        repository.addTrackToPersonalPlaylist(id, _track(id: '1')),
        isTrue,
      );
      // 歌单不存在时添加失败。
      expect(
        repository.addTrackToPersonalPlaylist(99999, _track(id: '3')),
        isFalse,
      );

      final playlist = repository.readPersonalPlaylist(id)!;
      expect(playlist.name, '歌单');
      expect(playlist.tracks.map((t) => t.ref.trackId), ['1', '2']);
    });

    test('removes tracks and cleans unreferenced metadata', () {
      final id = repository.createPersonalPlaylist('歌单');
      repository.addTrackToPersonalPlaylist(id, _track(id: '1'));
      repository.addTrackToPersonalPlaylist(id, _track(id: '2'));

      expect(repository.removeTrackFromPersonalPlaylist(id, _ref('1')), isTrue);
      expect(
        repository.readPersonalPlaylist(id)!.tracks.single.ref.trackId,
        '2',
      );
      // 已移除曲目若无引用则被清理。
      expect(repository.findTrack(_ref('1')), isNull);
      expect(
        repository.removeTrackFromPersonalPlaylist(id, _ref('1')),
        isFalse,
      );
    });

    test('reorders only when the ordered set matches the current items', () {
      final id = repository.createPersonalPlaylist('歌单');
      repository.addTrackToPersonalPlaylist(id, _track(id: '1'));
      repository.addTrackToPersonalPlaylist(id, _track(id: '2'));
      repository.addTrackToPersonalPlaylist(id, _track(id: '3'));

      expect(
        repository.reorderPersonalPlaylist(id, [
          _ref('3'),
          _ref('1'),
          _ref('2'),
        ]),
        isTrue,
      );
      expect(
        repository.readPersonalPlaylist(id)!.tracks.map((t) => t.ref.trackId),
        ['3', '1', '2'],
      );
      // 集合不匹配时不写入。
      expect(repository.reorderPersonalPlaylist(id, [_ref('1')]), isFalse);
      expect(
        repository.readPersonalPlaylist(id)!.tracks.map((t) => t.ref.trackId),
        ['3', '1', '2'],
      );
    });

    test('deletes personal playlists and keeps unrelated data', () {
      final id = repository.createPersonalPlaylist('歌单');
      repository.addTrackToPersonalPlaylist(id, _track(id: '1'));

      expect(repository.deletePersonalPlaylist(id), isTrue);
      expect(repository.readPersonalPlaylist(id), isNull);
      expect(repository.deletePersonalPlaylist(id), isFalse);
      expect(repository.findTrack(_ref('1')), isNull);
    });
  });

  group('favorites playlist', () {
    test(
      'favorites is created on demand and excluded from the personal list',
      () {
        expect(repository.listPersonalPlaylists(), isEmpty);

        final id = repository.ensureFavoritesPlaylist();

        expect(id, greaterThan(0));
        expect(repository.readFavorites(), isNotNull);
        expect(repository.readFavorites()!.name, personalFavoritesPlaylistName);
        expect(repository.listPersonalPlaylists(), isEmpty);
      },
    );

    test('cannot create, rename or delete the favorites playlist', () {
      final id = repository.ensureFavoritesPlaylist();

      expect(
        () => repository.createPersonalPlaylist('我的收藏'),
        throwsArgumentError,
      );
      expect(
        () => repository.renamePersonalPlaylist(id, '改名'),
        throwsArgumentError,
      );
      expect(() => repository.deletePersonalPlaylist(id), throwsArgumentError);
      expect(repository.readFavorites(), isNotNull);
    });

    test('toggleFavorite adds and removes without appearing in the list', () {
      repository.toggleFavorite(_track(id: '1'));

      expect(repository.isFavorite(_ref('1')), isTrue);
      expect(repository.listPersonalPlaylists(), isEmpty);

      repository.toggleFavorite(_track(id: '1'));

      expect(repository.isFavorite(_ref('1')), isFalse);
      expect(repository.readFavorites()!.tracks, isEmpty);
    });
  });
}

PlatformTrackRef _ref(String id) =>
    PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

MusicTrack _track({
  required String id,
  String title = 'Track',
  List<String> artists = const ['Artist'],
  String album = 'Album',
  Uri? coverUri,
  Duration duration = const Duration(minutes: 3),
}) => MusicTrack(
  ref: _ref(id),
  title: title,
  artists: artists,
  album: album,
  coverUri: coverUri ?? Uri.https('example.test', '/cover.jpg'),
  duration: duration,
  availability: TrackAvailability.playable,
);

RemotePlaylist _playlist({
  String name = 'Remote Playlist',
  int trackCount = 2,
}) => RemotePlaylist(
  platform: MusicPlatform.netease,
  id: '500',
  name: name,
  creator: 'Remote Creator',
  trackCount: trackCount,
  tracks: [
    _track(id: '100', title: 'First'),
    _track(id: '200', title: 'Second'),
  ],
);
