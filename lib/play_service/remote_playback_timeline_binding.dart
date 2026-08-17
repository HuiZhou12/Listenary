import 'dart:async';

import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';

final class RemotePlaybackTimelineBinding {
  RemotePlaybackTimelineBinding({
    required RemotePlaybackQueue queue,
    required RemotePlaybackSessionController sessionController,
    required RemotePlaybackTimelineController timelineController,
  }) : _queue = queue,
       _sessionController = sessionController,
       _timelineController = timelineController,
       _controlState = sessionController.controlState {
    _queue.addListener(_sync);
    _controlSubscription = sessionController.controlStateStream.listen(
      _onControlStateChanged,
    );
    _sync();
  }

  final RemotePlaybackQueue _queue;
  final RemotePlaybackSessionController _sessionController;
  final RemotePlaybackTimelineController _timelineController;
  late final StreamSubscription<RemotePlaybackControlSnapshot>
  _controlSubscription;
  RemotePlaybackControlSnapshot _controlState;
  bool _disposed = false;

  void _onControlStateChanged(RemotePlaybackControlSnapshot state) {
    if (_disposed) return;
    _controlState = state;
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    _timelineController.synchronize(
      revision: _sessionController.playbackRevision,
      state: _controlState.state,
      duration: _queue.value.currentItem?.duration ?? Duration.zero,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queue.removeListener(_sync);
    _timelineController.clear();
    await _controlSubscription.cancel();
  }
}
