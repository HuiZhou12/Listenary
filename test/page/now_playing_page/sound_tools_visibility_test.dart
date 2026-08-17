import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/sound_tools.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

void main() {
  test('sound tools are available only for an active local item', () {
    expect(
      shouldShowNowPlayingSoundTools(
        ActivePlaybackSessionSnapshot.inactive(revision: 1),
      ),
      isFalse,
    );
    expect(
      shouldShowNowPlayingSoundTools(
        _snapshot(ActivePlaybackSessionSource.remote),
      ),
      isFalse,
    );
    expect(
      shouldShowNowPlayingSoundTools(
        _snapshot(ActivePlaybackSessionSource.local),
      ),
      isTrue,
    );
  });
}

ActivePlaybackSessionSnapshot _snapshot(ActivePlaybackSessionSource source) =>
    ActivePlaybackSessionSnapshot.active(
      revision: 1,
      source: source,
      queue: const [
        ActivePlaybackSessionItem(title: 'Track', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );
