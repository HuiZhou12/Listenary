import 'dart:async';

import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

final class RemoteSmtcProjectionBinding {
  RemoteSmtcProjectionBinding({
    required RemotePlaybackQueue queue,
    required RemotePlaybackSessionController sessionController,
    required RemoteSmtcProjectionController projectionController,
  }) : _queue = queue,
       _projectionController = projectionController,
       _controlState = sessionController.controlState {
    _queue.addListener(_onQueueChanged);
    _controlSubscription = sessionController.controlStateStream.listen(
      _onControlStateChanged,
    );
    unawaited(_syncProjection());
  }

  final RemotePlaybackQueue _queue;
  final RemoteSmtcProjectionController _projectionController;
  late final StreamSubscription<RemotePlaybackControlSnapshot>
  _controlSubscription;
  RemotePlaybackControlSnapshot _controlState;
  bool _disposed = false;

  void _onQueueChanged() {
    if (_disposed) return;
    unawaited(_syncProjection());
  }

  void _onControlStateChanged(RemotePlaybackControlSnapshot state) {
    if (_disposed) return;
    _controlState = state;
    unawaited(_syncProjection());
  }

  Future<void> _syncProjection() async {
    if (_disposed) return;
    final state = _controlState.state;
    if (state == null) {
      await _projectionController.clear();
      return;
    }
    final item = _queue.value.currentItem;
    if (item == null) return;
    await _projectionController.project(
      RemoteSmtcProjection(
        title: item.title,
        artist: item.artistDisplay,
        state: state,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queue.removeListener(_onQueueChanged);
    await _controlSubscription.cancel();
    await _projectionController.dispose();
  }
}
