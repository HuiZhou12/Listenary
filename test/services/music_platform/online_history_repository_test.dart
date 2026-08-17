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

  test('starting history preserves its count until a listen is recorded', () {
    final track = _track('100');
    repository.recordPlaybackStarted(track, lastQuality: 'lossless');
    repository.recordPlaybackStarted(track, lastQuality: 'standard');

    final entry = repository.recentHistory().single;
    expect(entry.playCount, 0);
    expect(entry.lastQuality, 'standard');
    expect(repository.incrementPlayCount(track.ref), isTrue);
    expect(repository.recentHistory().single.playCount, 1);
  });
}

MusicTrack _track(String id) => MusicTrack(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
  title: 'Track $id',
  artists: const ['Artist'],
  duration: const Duration(minutes: 3),
  availability: TrackAvailability.playable,
);
