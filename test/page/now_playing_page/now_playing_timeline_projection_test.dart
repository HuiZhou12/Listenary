import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';

void main() {
  test('remote projection ignores stale local position and duration', () {
    final projection = resolveNowPlayingTimeline(
      activeSession: _remoteSnapshot(),
      remoteTimeline: RemotePlaybackTimelineSnapshot.normalized(
        position: const Duration(milliseconds: 12500),
        duration: const Duration(seconds: 60),
      ),
      localPositionSeconds: 42,
      localDurationSeconds: 180,
      localIsPlaying: false,
    );

    expect(projection.usesRemoteTimeline, isTrue);
    expect(projection.positionSeconds, 12.5);
    expect(projection.durationSeconds, 60);
    expect(projection.paintPositionSeconds, 12.5);
    expect(projection.isAdvancing, isTrue);
  });

  test('unknown remote duration keeps time but paints zero progress', () {
    final projection = resolveNowPlayingTimeline(
      activeSession: _remoteSnapshot(),
      remoteTimeline: RemotePlaybackTimelineSnapshot.normalized(
        position: const Duration(seconds: 8),
        duration: null,
      ),
      localPositionSeconds: 42,
      localDurationSeconds: 180,
      localIsPlaying: true,
    );

    expect(projection.positionSeconds, 8);
    expect(projection.durationSeconds, isNull);
    expect(projection.paintPositionSeconds, 0);
  });

  test('remote paused state freezes the page interpolation driver', () {
    final projection = resolveNowPlayingTimeline(
      activeSession: _remoteSnapshot(
        state: ActivePlaybackSessionState.paused,
      ),
      remoteTimeline: RemotePlaybackTimelineSnapshot.normalized(
        position: const Duration(seconds: 15),
        duration: const Duration(seconds: 60),
      ),
      localPositionSeconds: 42,
      localDurationSeconds: 180,
      localIsPlaying: true,
    );

    expect(projection.positionSeconds, 15);
    expect(projection.isAdvancing, isFalse);
  });

  test('local and inactive sessions retain the local timeline', () {
    for (final activeSession in [
      _localSnapshot(),
      ActivePlaybackSessionSnapshot.inactive(revision: 3),
    ]) {
      final projection = resolveNowPlayingTimeline(
        activeSession: activeSession,
        remoteTimeline: RemotePlaybackTimelineSnapshot.normalized(
          position: const Duration(seconds: 8),
          duration: const Duration(seconds: 60),
        ),
        localPositionSeconds: 42,
        localDurationSeconds: 180,
        localIsPlaying: true,
      );

      expect(projection.usesRemoteTimeline, isFalse);
      expect(projection.positionSeconds, 42);
      expect(projection.durationSeconds, 180);
      expect(projection.paintPositionSeconds, 42);
      expect(projection.isAdvancing, isTrue);
    }
  });
}

ActivePlaybackSessionSnapshot _remoteSnapshot({
  ActivePlaybackSessionState state = ActivePlaybackSessionState.playing,
}) => ActivePlaybackSessionSnapshot.active(
  revision: 1,
  source: ActivePlaybackSessionSource.remote,
  queue: const [
    ActivePlaybackSessionItem(title: 'Remote title', artist: 'Remote artist'),
  ],
  currentIndex: 0,
  state: state,
  controlInFlight: false,
  capabilities: const ActivePlaybackSessionCapabilities(
    canPlay: false,
    canPause: true,
    canPrevious: true,
    canNext: true,
    canSeek: false,
  ),
);

ActivePlaybackSessionSnapshot _localSnapshot() =>
    ActivePlaybackSessionSnapshot.active(
      revision: 2,
      source: ActivePlaybackSessionSource.local,
      queue: const [
        ActivePlaybackSessionItem(title: 'Local title', artist: 'Local artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: false,
        canPause: true,
        canPrevious: true,
        canNext: true,
        canSeek: true,
      ),
    );
