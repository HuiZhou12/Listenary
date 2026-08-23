import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late PersonalOnlinePlaylistController controller;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    controller = PersonalOnlinePlaylistController(
      repository: Future.value(repository),
    );
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  test('loads personal playlists into a ready snapshot', () async {
    repository.createPersonalPlaylist('歌单 A');

    await controller.load();

    expect(controller.snapshot.status, PersonalOnlinePlaylistStatus.ready);
    expect(controller.snapshot.playlists, hasLength(1));
    expect(controller.snapshot.playlists.single.name, '歌单 A');
  });

  test('create, rename and delete keep the list snapshot in sync', () async {
    final id = await controller.create('我的歌单');
    expect(id, isNotNull);
    expect(controller.snapshot.playlists.single.name, '我的歌单');

    expect(await controller.rename(id!, '改名'), isTrue);
    expect(controller.snapshot.playlists.single.name, '改名');

    // 与已有名称冲突返回 false 且不改变列表。
    final other = repository.createPersonalPlaylist('另一个');
    expect(await controller.rename(other, '改名'), isFalse);

    expect(await controller.delete(id), isTrue);
    expect(controller.snapshot.playlists, hasLength(1));
    expect(controller.snapshot.playlists.single.name, '另一个');
  });

  test('adds and removes tracks and exposes a playback selection', () async {
    final id = (await controller.create('歌单'))!;
    expect(await controller.addTrack(id, _track('1')), isTrue);
    expect(await controller.addTrack(id, _track('2')), isTrue);

    final selection = await controller.playbackSelection(
      localId: id,
      selectedRef: _ref('2'),
    );
    expect(selection!.tracks.map((track) => track.ref.trackId), ['1', '2']);
    expect(selection.selectedIndex, 1);

    expect(await controller.removeTrack(id, _ref('1')), isTrue);
    expect((await controller.readSnapshot(id))!.tracks.single.ref.trackId, '2');
  });

  test('turns repository errors into a safe failure state', () async {
    final id = await controller.create('  ');

    expect(id, isNull);
    expect(controller.snapshot.status, PersonalOnlinePlaylistStatus.failed);
    expect(controller.snapshot.errorMessage, isNotNull);
    expect(controller.snapshot.errorMessage, isNot(contains('ArgumentError')));
  });

  test('rejects a playback selection for a missing track', () async {
    final id = (await controller.create('歌单'))!;
    await controller.addTrack(id, _track('1'));

    expect(
      () => controller.playbackSelection(localId: id, selectedRef: _ref('9')),
      throwsArgumentError,
    );
  });

  test(
    'loads and toggles favorite state without leaking to the list',
    () async {
      await controller.loadFavorites();
      expect(controller.isFavorite(_ref('1')), isFalse);

      expect(await controller.toggleFavorite(_track('1')), isTrue);
      expect(controller.isFavorite(_ref('1')), isTrue);

      expect(await controller.toggleFavorite(_track('1')), isFalse);
      expect(controller.isFavorite(_ref('1')), isFalse);
      // 收藏歌单不出现在「我的在线歌单」列表。
      expect(controller.snapshot.playlists, isEmpty);
    },
  );
}

PlatformTrackRef _ref(String id) =>
    PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

MusicTrack _track(String id) =>
    MusicTrack(ref: _ref(id), title: 'Title $id', artists: const ['Artist']);
