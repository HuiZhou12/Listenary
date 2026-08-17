import 'package:flutter/foundation.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

@immutable
final class NowPlayingControlProjection {
  const NowPlayingControlProjection({
    required this.presentation,
    required this.canPrevious,
    required this.canNext,
    required this.canChangePlaybackMode,
    required this.usesRemoteQueueMode,
    required this.navigationBlocked,
  });

  final PlaybackControlPresentation presentation;
  final bool canPrevious;
  final bool canNext;
  final bool canChangePlaybackMode;
  final bool usesRemoteQueueMode;
  final bool navigationBlocked;
}

bool shouldShowNowPlayingDesktopLyric(ActivePlaybackSessionSource source) =>
    source != ActivePlaybackSessionSource.inactive;

NowPlayingControlProjection resolveNowPlayingControls(
  ActivePlaybackSessionSnapshot snapshot,
) {
  final hasSession = snapshot.isActive && snapshot.currentItem != null;
  if (snapshot.source == ActivePlaybackSessionSource.inactive) {
    return const NowPlayingControlProjection(
      presentation: PlaybackControlPresentation(
        hasSession: false,
        canToggle: false,
        isPlaying: false,
        action: PlaybackControlAction.none,
      ),
      canPrevious: false,
      canNext: false,
      canChangePlaybackMode: false,
      usesRemoteQueueMode: false,
      navigationBlocked: false,
    );
  }

  final isRemote = snapshot.source == ActivePlaybackSessionSource.remote;
  final capabilities = snapshot.capabilities;
  final action = !hasSession || snapshot.controlInFlight
      ? PlaybackControlAction.none
      : isRemote
      ? switch (snapshot.state) {
          ActivePlaybackSessionState.playing when capabilities.canPause =>
            PlaybackControlAction.pause,
          ActivePlaybackSessionState.paused when capabilities.canPlay =>
            PlaybackControlAction.play,
          _ => PlaybackControlAction.none,
        }
      : switch (snapshot.state) {
          ActivePlaybackSessionState.playing => PlaybackControlAction.pause,
          ActivePlaybackSessionState.completed => PlaybackControlAction.replay,
          _ => PlaybackControlAction.play,
        };
  final navigationBlocked =
      isRemote &&
      (snapshot.controlInFlight ||
          snapshot.state == ActivePlaybackSessionState.opening);

  return NowPlayingControlProjection(
    presentation: PlaybackControlPresentation(
      hasSession: hasSession,
      canToggle: action != PlaybackControlAction.none,
      isPlaying: snapshot.state == ActivePlaybackSessionState.playing,
      action: action,
    ),
    canPrevious:
        hasSession &&
        (isRemote ? !navigationBlocked && capabilities.canPrevious : true),
    canNext:
        hasSession &&
        (isRemote ? !navigationBlocked && capabilities.canNext : true),
    canChangePlaybackMode: hasSession && !isRemote,
    usesRemoteQueueMode: isRemote,
    navigationBlocked: navigationBlocked,
  );
}
