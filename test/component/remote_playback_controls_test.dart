import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';

void main() {
  test('local presentation preserves play pause and replay states', () {
    const inactive = _RemoteState(null);

    expect(
      resolvePlaybackControlPresentation(
        remoteState: inactive,
        localState: PlayerState.stopped,
        hasLocalSession: false,
      ).action,
      PlaybackControlAction.none,
    );
    expect(
      resolvePlaybackControlPresentation(
        remoteState: inactive,
        localState: PlayerState.playing,
        hasLocalSession: true,
      ).action,
      PlaybackControlAction.pause,
    );
    expect(
      resolvePlaybackControlPresentation(
        remoteState: inactive,
        localState: PlayerState.completed,
        hasLocalSession: true,
      ).action,
      PlaybackControlAction.replay,
    );
    expect(
      resolvePlaybackControlPresentation(
        remoteState: inactive,
        localState: PlayerState.paused,
        hasLocalSession: true,
      ).action,
      PlaybackControlAction.play,
    );
  });

  test('remote presentation enables only playing and paused controls', () {
    final playing = resolvePlaybackControlPresentation(
      remoteState: const _RemoteState(PlaybackBackendState.playing),
      localState: PlayerState.stopped,
      hasLocalSession: false,
    );
    final paused = resolvePlaybackControlPresentation(
      remoteState: const _RemoteState(PlaybackBackendState.paused),
      localState: PlayerState.playing,
      hasLocalSession: true,
    );

    expect(playing.hasSession, isTrue);
    expect(playing.canToggle, isTrue);
    expect(playing.isPlaying, isTrue);
    expect(playing.action, PlaybackControlAction.pause);
    expect(paused.hasSession, isTrue);
    expect(paused.canToggle, isTrue);
    expect(paused.isPlaying, isFalse);
    expect(paused.action, PlaybackControlAction.play);

    for (final state in const [
      PlaybackBackendState.opening,
      PlaybackBackendState.stalled,
      PlaybackBackendState.completed,
      PlaybackBackendState.failed,
    ]) {
      final presentation = resolvePlaybackControlPresentation(
        remoteState: _RemoteState(state),
        localState: PlayerState.playing,
        hasLocalSession: true,
      );
      expect(presentation.hasSession, isTrue);
      expect(presentation.canToggle, isFalse);
      expect(presentation.action, PlaybackControlAction.none);
    }

    final inFlight = resolvePlaybackControlPresentation(
      remoteState: const _RemoteState(
        PlaybackBackendState.playing,
        controlInFlight: true,
      ),
      localState: PlayerState.playing,
      hasLocalSession: true,
    );
    expect(inFlight.hasSession, isTrue);
    expect(inFlight.canToggle, isFalse);
    expect(inFlight.action, PlaybackControlAction.none);
  });

  test(
    'space toggle forwards remote actions and ignores busy states',
    () async {
      final playService = PlayService.instance;
      final source = StreamController<RemotePlaybackControlState>.broadcast();
      var pauseCount = 0;
      var resumeCount = 0;
      addTearDown(() async {
        playService.clearRemotePlaybackControlHandlers();
        await source.close();
      });

      playService.setRemotePlaybackControlHandlers(
        initialState: const _RemoteState(PlaybackBackendState.playing),
        stateStream: source.stream,
        isActive: () => true,
        pause: () {
          pauseCount++;
          return true;
        },
        resume: () {
          resumeCount++;
          return true;
        },
      );

      expect(
        HotkeysHelper.togglePlayback(playService),
        PlaybackControlAction.pause,
      );
      expect(pauseCount, 1);

      source.add(const _RemoteState(PlaybackBackendState.paused));
      await pumpEventQueue();
      expect(
        HotkeysHelper.togglePlayback(playService),
        PlaybackControlAction.play,
      );
      expect(resumeCount, 1);

      source.add(const _RemoteState(PlaybackBackendState.opening));
      await pumpEventQueue();
      expect(
        HotkeysHelper.togglePlayback(playService),
        PlaybackControlAction.none,
      );
      expect(pauseCount, 1);
      expect(resumeCount, 1);
    },
  );
}

final class _RemoteState implements RemotePlaybackControlState {
  const _RemoteState(this.state, {this.controlInFlight = false});

  @override
  final PlaybackBackendState? state;

  @override
  final bool controlInFlight;

  @override
  bool get isActive => state != null;
}
