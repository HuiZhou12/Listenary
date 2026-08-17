import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/page/now_playing_page/now_playing_control_projection.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

void main() {
  test('inactive session disables every primary control', () {
    final controls = resolveNowPlayingControls(
      ActivePlaybackSessionSnapshot.inactive(revision: 1),
    );

    expect(controls.presentation.hasSession, isFalse);
    expect(controls.presentation.action, PlaybackControlAction.none);
    expect(controls.canPrevious, isFalse);
    expect(controls.canNext, isFalse);
    expect(controls.canChangePlaybackMode, isFalse);
    expect(controls.usesRemoteQueueMode, isFalse);
  });

  test('local session preserves playback and cyclic queue controls', () {
    final paused = resolveNowPlayingControls(
      _snapshot(
        source: ActivePlaybackSessionSource.local,
        state: ActivePlaybackSessionState.paused,
        capabilities: _localCapabilities,
      ),
    );
    final completed = resolveNowPlayingControls(
      _snapshot(
        source: ActivePlaybackSessionSource.local,
        state: ActivePlaybackSessionState.completed,
        capabilities: _localCapabilities,
      ),
    );

    expect(paused.presentation.action, PlaybackControlAction.play);
    expect(paused.canPrevious, isTrue);
    expect(paused.canNext, isTrue);
    expect(paused.canChangePlaybackMode, isTrue);
    expect(paused.usesRemoteQueueMode, isFalse);
    expect(completed.presentation.action, PlaybackControlAction.replay);
  });

  test('remote queue boundaries follow active session capabilities', () {
    final first = resolveNowPlayingControls(
      _snapshot(
        source: ActivePlaybackSessionSource.remote,
        state: ActivePlaybackSessionState.playing,
        capabilities: const ActivePlaybackSessionCapabilities(
          canPlay: false,
          canPause: true,
          canPrevious: false,
          canNext: true,
          canSeek: false,
        ),
      ),
    );
    final last = resolveNowPlayingControls(
      _snapshot(
        source: ActivePlaybackSessionSource.remote,
        state: ActivePlaybackSessionState.paused,
        capabilities: const ActivePlaybackSessionCapabilities(
          canPlay: true,
          canPause: false,
          canPrevious: true,
          canNext: false,
          canSeek: false,
        ),
      ),
    );

    expect(first.presentation.action, PlaybackControlAction.pause);
    expect(first.canPrevious, isFalse);
    expect(first.canNext, isTrue);
    expect(first.canChangePlaybackMode, isFalse);
    expect(first.usesRemoteQueueMode, isTrue);
    expect(last.presentation.action, PlaybackControlAction.play);
    expect(last.canPrevious, isTrue);
    expect(last.canNext, isFalse);
  });

  test('remote opening and in-flight controls block navigation', () {
    for (final snapshot in [
      _snapshot(
        source: ActivePlaybackSessionSource.remote,
        state: ActivePlaybackSessionState.opening,
        capabilities: _remoteCapabilities,
      ),
      _snapshot(
        source: ActivePlaybackSessionSource.remote,
        state: ActivePlaybackSessionState.playing,
        controlInFlight: true,
        capabilities: _remoteCapabilities,
      ),
    ]) {
      final controls = resolveNowPlayingControls(snapshot);

      expect(controls.presentation.canToggle, isFalse);
      expect(controls.canPrevious, isFalse);
      expect(controls.canNext, isFalse);
      expect(controls.navigationBlocked, isTrue);
    }
  });
}

ActivePlaybackSessionSnapshot _snapshot({
  required ActivePlaybackSessionSource source,
  required ActivePlaybackSessionState state,
  required ActivePlaybackSessionCapabilities capabilities,
  bool controlInFlight = false,
}) => ActivePlaybackSessionSnapshot.active(
  revision: 1,
  source: source,
  queue: const [
    ActivePlaybackSessionItem(title: 'Track', artist: 'Artist'),
  ],
  currentIndex: 0,
  state: state,
  controlInFlight: controlInFlight,
  capabilities: capabilities,
);

const _localCapabilities = ActivePlaybackSessionCapabilities(
  canPlay: true,
  canPause: true,
  canPrevious: true,
  canNext: true,
  canSeek: true,
);

const _remoteCapabilities = ActivePlaybackSessionCapabilities(
  canPlay: false,
  canPause: true,
  canPrevious: true,
  canNext: true,
  canSeek: false,
);
