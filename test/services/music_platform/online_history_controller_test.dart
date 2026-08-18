import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late OnlineHistoryController controller;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    controller = OnlineHistoryController(repository: Future.value(repository));
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  test('loads recent, top played and summary from one view snapshot', () async {
    repository.recordPlaybackStarted(
      _track('1', artists: const ['First', 'Second']),
      playedAt: DateTime.utc(2026, 8, 18, 10),
    );
    repository.recordPlaybackStarted(
      _track('2'),
      playedAt: DateTime.utc(2026, 8, 18, 11),
    );
    repository.incrementPlayCount(_ref('1'));
    repository.incrementPlayCount(_ref('1'));
    repository.incrementPlayCount(_ref('2'));

    await controller.refresh();

    expect(controller.snapshot.status, OnlineHistoryLoadStatus.ready);
    expect(controller.snapshot.recent.map((entry) => entry.track.ref.trackId), [
      '2',
      '1',
    ]);
    expect(controller.snapshot.recent.last.track.artists, ['First', 'Second']);
    expect(controller.snapshot.topPlayed.first.track.ref.trackId, '1');
    expect(controller.snapshot.totalPlayCount, 3);
    expect(controller.snapshot.trackCount, 2);
  });

  test('writes, refreshes for listeners and clears history', () async {
    controller.addListener(() {});

    await controller.recordPlaybackStarted(
      _track('1'),
      lastQuality: 'lossless',
    );
    await pumpEventQueue();

    expect(controller.revision, 1);
    expect(controller.snapshot.recent.single.lastQuality, 'lossless');

    expect(await controller.incrementPlayCount(_ref('1')), isTrue);
    await pumpEventQueue();
    expect(controller.snapshot.totalPlayCount, 1);

    await controller.updateTrackMetadata(
      _track('1', duration: const Duration(minutes: 4)),
      lastQuality: 'lossless',
    );
    await pumpEventQueue();
    expect(
      controller.snapshot.recent.single.track.duration,
      const Duration(minutes: 4),
    );

    await controller.clearHistory();
    expect(controller.snapshot.status, OnlineHistoryLoadStatus.ready);
    expect(controller.snapshot.hasData, isFalse);
    expect(repository.recentHistory(), isEmpty);
  });

  test('exposes a safe failed state when the database cannot open', () async {
    controller.dispose();
    controller = OnlineHistoryController(
      repository: Future<OnlineLibraryRepository>.error(
        StateError('database unavailable'),
      ),
    );

    await controller.refresh();

    expect(controller.snapshot.status, OnlineHistoryLoadStatus.failed);
    expect(controller.snapshot.hasData, isFalse);
  });
}

PlatformTrackRef _ref(String id) =>
    PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

MusicTrack _track(
  String id, {
  List<String> artists = const ['Artist'],
  Duration duration = const Duration(minutes: 3),
}) => MusicTrack(
  ref: _ref(id),
  title: 'Track $id',
  artists: artists,
  album: 'Album',
  duration: duration,
  availability: TrackAvailability.playable,
);
