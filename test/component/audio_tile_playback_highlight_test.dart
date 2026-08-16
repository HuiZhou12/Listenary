import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

void main() {
  test('local active highlights only the matching path', () {
    expect(
      resolveAudioTileFocus(
        explicitFocus: false,
        activeSource: ActivePlaybackSessionSource.local,
        localNowPlayingPath: 'music/current.flac',
        audioPath: 'music/current.flac',
      ),
      isTrue,
    );
    expect(
      resolveAudioTileFocus(
        explicitFocus: false,
        activeSource: ActivePlaybackSessionSource.local,
        localNowPlayingPath: 'music/current.flac',
        audioPath: 'music/other.flac',
      ),
      isFalse,
    );
  });

  test('remote and inactive sources suppress stale local playback focus', () {
    for (final source in const [
      ActivePlaybackSessionSource.remote,
      ActivePlaybackSessionSource.inactive,
    ]) {
      expect(
        resolveAudioTileFocus(
          explicitFocus: false,
          activeSource: source,
          localNowPlayingPath: 'music/current.flac',
          audioPath: 'music/current.flac',
        ),
        isFalse,
      );
    }
  });

  test('explicit page focus remains independent from playback source', () {
    for (final source in ActivePlaybackSessionSource.values) {
      expect(
        resolveAudioTileFocus(
          explicitFocus: true,
          activeSource: source,
          localNowPlayingPath: null,
          audioPath: 'music/located.flac',
        ),
        isTrue,
      );
    }
  });
}
