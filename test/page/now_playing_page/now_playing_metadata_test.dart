import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

void main() {
  test('remote metadata replaces only local title and artist', () {
    final metadata = resolveNowPlayingMetadata(
      snapshot: _snapshot(
        source: ActivePlaybackSessionSource.remote,
        title: 'Remote title',
        artist: 'Remote artist',
      ),
      localTitle: 'A/Z',
      localArtist: 'Local artist',
    );

    expect(metadata.title, 'Remote title');
    expect(metadata.artist, 'Remote artist');
  });

  test('local metadata keeps the existing title and artist', () {
    final metadata = resolveNowPlayingMetadata(
      snapshot: _snapshot(source: ActivePlaybackSessionSource.local),
      localTitle: 'A/Z',
      localArtist: 'Local artist',
    );

    expect(metadata.title, 'A/Z');
    expect(metadata.artist, 'Local artist');
  });

  test('inactive metadata keeps existing defaults', () {
    final metadata = resolveNowPlayingMetadata(
      snapshot: ActivePlaybackSessionSnapshot.inactive(revision: 3),
      localTitle: null,
      localArtist: null,
    );

    expect(metadata.title, 'Pure Music');
    expect(metadata.artist, 'Enjoy Music');
  });
}

ActivePlaybackSessionSnapshot _snapshot({
  required ActivePlaybackSessionSource source,
  String title = 'Title',
  String artist = 'Artist',
}) {
  return ActivePlaybackSessionSnapshot.active(
    revision: 1,
    source: source,
    queue: [ActivePlaybackSessionItem(title: title, artist: artist)],
    currentIndex: 0,
    state: ActivePlaybackSessionState.playing,
    controlInFlight: false,
    capabilities: const ActivePlaybackSessionCapabilities(
      canPlay: false,
      canPause: true,
      canPrevious: false,
      canNext: false,
      canSeek: false,
    ),
  );
}
