import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';

typedef LocalPlaybackSourceCreatedListener<T extends Object> =
    void Function(T source);
typedef LocalActivePlaybackSessionAttacher<T extends Object> =
    void Function() Function(T source, ActivePlaybackSession activeSession);

final class ActivePlaybackSessionComposition<T extends Object> {
  ActivePlaybackSessionComposition({
    required RemotePlaybackQueue remoteQueue,
    required RemotePlaybackSessionController remoteSessionController,
    required void Function(LocalPlaybackSourceCreatedListener<T> listener)
    addLocalSourceCreatedListener,
    required void Function(LocalPlaybackSourceCreatedListener<T> listener)
    removeLocalSourceCreatedListener,
    required LocalActivePlaybackSessionAttacher<T> attachLocalBinding,
  }) : _addLocalSourceCreatedListener = addLocalSourceCreatedListener,
       _removeLocalSourceCreatedListener = removeLocalSourceCreatedListener,
       _attachLocalBinding = attachLocalBinding,
       activeSession = ActivePlaybackSession() {
    _remoteBinding = RemoteActivePlaybackSessionBinding(
      queue: remoteQueue,
      sessionController: remoteSessionController,
      activeSession: activeSession,
    );
    _addLocalSourceCreatedListener(_onLocalSourceCreated);
  }

  final void Function(LocalPlaybackSourceCreatedListener<T> listener)
  _addLocalSourceCreatedListener;
  final void Function(LocalPlaybackSourceCreatedListener<T> listener)
  _removeLocalSourceCreatedListener;
  final LocalActivePlaybackSessionAttacher<T> _attachLocalBinding;
  final ActivePlaybackSession activeSession;
  late final RemoteActivePlaybackSessionBinding _remoteBinding;
  void Function()? _disposeLocalBinding;
  bool _localBindingAttached = false;
  bool _disposed = false;

  void _onLocalSourceCreated(T source) {
    if (_disposed || _localBindingAttached) return;
    _localBindingAttached = true;
    try {
      _disposeLocalBinding = _attachLocalBinding(source, activeSession);
    } catch (_) {
      _localBindingAttached = false;
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _removeLocalSourceCreatedListener(_onLocalSourceCreated);
    final disposeLocalBinding = _disposeLocalBinding;
    _disposeLocalBinding = null;
    try {
      disposeLocalBinding?.call();
    } finally {
      try {
        await _remoteBinding.dispose();
      } finally {
        activeSession.dispose();
      }
    }
  }
}
