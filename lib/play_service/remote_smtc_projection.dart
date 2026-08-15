import 'dart:async';

import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

final class RemoteSmtcProjectionBinding {
  factory RemoteSmtcProjectionBinding({
    required RemotePlaybackQueue queue,
    required RemotePlaybackSessionController sessionController,
    required RemoteSmtcProjectionController projectionController,
  }) => RemoteSmtcProjectionBinding._(
    queue: queue,
    sessionController: sessionController,
    projectionController: projectionController,
  );

  factory RemoteSmtcProjectionBinding.lazy({
    required RemotePlaybackQueue queue,
    required RemotePlaybackSessionController sessionController,
    required RemoteSmtcProjectionController Function()
    createProjectionController,
    required void Function(void Function()) bindRemoteKeepAlive,
    required void Function(void Function()) clearRemoteKeepAlive,
  }) => RemoteSmtcProjectionBinding._(
    queue: queue,
    sessionController: sessionController,
    createProjectionController: createProjectionController,
    bindRemoteKeepAlive: bindRemoteKeepAlive,
    clearRemoteKeepAlive: clearRemoteKeepAlive,
  );

  RemoteSmtcProjectionBinding._({
    required RemotePlaybackQueue queue,
    required RemotePlaybackSessionController sessionController,
    RemoteSmtcProjectionController? projectionController,
    RemoteSmtcProjectionController Function()? createProjectionController,
    void Function(void Function())? bindRemoteKeepAlive,
    void Function(void Function())? clearRemoteKeepAlive,
  }) : _queue = queue,
       _projectionController = projectionController,
       _createProjectionController = createProjectionController,
       _bindRemoteKeepAlive = bindRemoteKeepAlive,
       _clearRemoteKeepAlive = clearRemoteKeepAlive,
       _controlState = sessionController.controlState {
    _keepAlivePublisher = pushKeepAlive;
    _queue.addListener(_onQueueChanged);
    _controlSubscription = sessionController.controlStateStream.listen(
      _onControlStateChanged,
    );
    if (_controlState.isActive) {
      _bindKeepAlive();
    }
    unawaited(_syncProjection());
  }

  final RemotePlaybackQueue _queue;
  RemoteSmtcProjectionController? _projectionController;
  final RemoteSmtcProjectionController Function()? _createProjectionController;
  final void Function(void Function())? _bindRemoteKeepAlive;
  final void Function(void Function())? _clearRemoteKeepAlive;
  late final void Function() _keepAlivePublisher;
  late final StreamSubscription<RemotePlaybackControlSnapshot>
  _controlSubscription;
  RemotePlaybackControlSnapshot _controlState;
  bool _keepAliveBound = false;
  bool _disposed = false;

  void pushKeepAlive() {
    _projectionController?.pushKeepAlive();
  }

  void _onQueueChanged() {
    if (_disposed) return;
    unawaited(_syncProjection());
  }

  void _onControlStateChanged(RemotePlaybackControlSnapshot state) {
    if (_disposed) return;
    final wasActive = _controlState.isActive;
    _controlState = state;
    if (!wasActive && state.isActive) {
      _bindKeepAlive();
    } else if (wasActive && !state.isActive) {
      _unbindKeepAlive();
    }
    unawaited(_syncProjection());
  }

  Future<void> _syncProjection() async {
    if (_disposed) return;
    final state = _controlState.state;
    if (state == null) {
      await _projectionController?.clear();
      return;
    }
    final item = _queue.value.currentItem;
    if (item == null) return;
    final projectionController = _projectionController ??=
        _createProjectionController!();
    await projectionController.project(
      RemoteSmtcProjection(
        title: item.title,
        artist: item.artistDisplay,
        state: state,
      ),
    );
  }

  void _bindKeepAlive() {
    if (_keepAliveBound || _bindRemoteKeepAlive == null) return;
    _bindRemoteKeepAlive(_keepAlivePublisher);
    _keepAliveBound = true;
  }

  void _unbindKeepAlive() {
    if (!_keepAliveBound) return;
    _clearRemoteKeepAlive?.call(_keepAlivePublisher);
    _keepAliveBound = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _queue.removeListener(_onQueueChanged);
    _unbindKeepAlive();
    final subscriptionCancellation = _controlSubscription.cancel();
    final projectionDisposal = _projectionController?.dispose();
    if (projectionDisposal != null) {
      await projectionDisposal;
    }
    await subscriptionCancellation;
  }
}
