import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  test('keeps the displayed order and selected index', () {
    final selection = OnlineTrackSelection.fromResultPage(
      tracks: [_track('3'), _track('1'), _track('2')],
      selectedRef: _ref('1'),
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['3', '1', '2']);
    expect(selection.selectedIndex, 1);
  });

  test('filters unavailable tracks without changing playable order', () {
    final selection = OnlineTrackSelection.fromResultPage(
      tracks: [
        _track('3', TrackAvailability.paid),
        _track('1'),
        _track('4', TrackAvailability.unavailable),
        _track('2'),
      ],
      selectedRef: _ref('2'),
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['1', '2']);
    expect(selection.selectedIndex, 1);
  });

  test('rejects a missing or unplayable selected track', () {
    expect(
      () => OnlineTrackSelection.fromResultPage(
        tracks: [_track('1')],
        selectedRef: _ref('2'),
      ),
      throwsArgumentError,
    );
    expect(
      () => OnlineTrackSelection.fromResultPage(
        tracks: [_track('1', TrackAvailability.paid)],
        selectedRef: _ref('1'),
      ),
      throwsArgumentError,
    );
  });
}

PlatformTrackRef _ref(String id) => PlatformTrackRef(
  platform: MusicPlatform.netease,
  trackId: id,
);

MusicTrack _track(
  String id, [
  TrackAvailability availability = TrackAvailability.playable,
]) => MusicTrack(
  ref: _ref(id),
  title: id,
  artists: const ['Artist'],
  availability: availability,
);
