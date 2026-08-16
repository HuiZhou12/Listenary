import 'dart:async';

import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';

final class RemoteActivePlaybackSessionBinding {
  RemoteActivePlaybackSessionBinding({
    required RemotePlaybackQueue queue,
    required RemotePlaybackSessionController sessionController,
    required ActivePlaybackSession activeSession,
  }) : _queue = queue,
       _activeSession = activeSession,
       _controlState = sessionController.controlState {
    _queue.addListener(_onQueueChanged);
    _controlSubscription = sessionController.controlStateStream.listen(
      _onControlStateChanged,
    );
    _sync();
  }

  final RemotePlaybackQueue _queue;
  final ActivePlaybackSession _activeSession;
  late final StreamSubscription<RemotePlaybackControlSnapshot>
  _controlSubscription;
  RemotePlaybackControlSnapshot _controlState;
  ActivePlaybackSessionLease? _lease;
  bool _disposed = false;

  void _onQueueChanged() {
    if (_disposed) return;
    _sync();
  }

  void _onControlStateChanged(RemotePlaybackControlSnapshot state) {
    if (_disposed) return;
    _controlState = state;
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final state = _controlState.state;
    if (state == null) {
      _releaseLease();
      return;
    }

    final queue = _queue.value;
    final items = queue.items
        .map(
          (item) => ActivePlaybackSessionItem(
            title: item.title,
            artist: item.artistDisplay,
            album: item.album,
          ),
        )
        .toList(growable: false);
    final capabilities = _capabilitiesFor(
      state: state,
      controlInFlight: _controlState.controlInFlight,
      currentIndex: queue.currentIndex,
      queueLength: items.length,
    );
    final activeState = _mapState(state);
    final lease = _lease;
    if (lease == null) {
      _lease = _activeSession.switchTo(
        source: ActivePlaybackSessionSource.remote,
        queue: items,
        currentIndex: queue.currentIndex,
        state: activeState,
        controlInFlight: _controlState.controlInFlight,
        capabilities: capabilities,
      );
      return;
    }
    _activeSession.publish(
      lease,
      queue: items,
      currentIndex: queue.currentIndex,
      state: activeState,
      controlInFlight: _controlState.controlInFlight,
      capabilities: capabilities,
    );
  }

  void _releaseLease() {
    final lease = _lease;
    if (lease == null) return;
    _lease = null;
    _activeSession.release(lease);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queue.removeListener(_onQueueChanged);
    _releaseLease();
    await _controlSubscription.cancel();
  }
}

ActivePlaybackSessionState _mapState(PlaybackBackendState state) =>
    switch (state) {
      PlaybackBackendState.stopped => ActivePlaybackSessionState.stopped,
      PlaybackBackendState.opening => ActivePlaybackSessionState.opening,
      PlaybackBackendState.playing => ActivePlaybackSessionState.playing,
      PlaybackBackendState.paused => ActivePlaybackSessionState.paused,
      PlaybackBackendState.stalled => ActivePlaybackSessionState.stalled,
      PlaybackBackendState.completed => ActivePlaybackSessionState.completed,
      PlaybackBackendState.failed => ActivePlaybackSessionState.failed,
    };

ActivePlaybackSessionCapabilities _capabilitiesFor({
  required PlaybackBackendState state,
  required bool controlInFlight,
  required int? currentIndex,
  required int queueLength,
}) => ActivePlaybackSessionCapabilities(
  canPlay: !controlInFlight && state == PlaybackBackendState.paused,
  canPause: !controlInFlight && state == PlaybackBackendState.playing,
  canPrevious: currentIndex != null && currentIndex > 0,
  canNext: currentIndex != null && currentIndex + 1 < queueLength,
  canSeek: false,
);
