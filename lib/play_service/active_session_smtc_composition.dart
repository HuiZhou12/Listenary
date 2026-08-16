import 'dart:async';

import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/active_session_smtc_publisher.dart';
import 'package:pure_music/play_service/local_smtc_publisher.dart';

typedef LocalSmtcPublisherAttacher<T extends Object> =
    void Function(T source, LocalSmtcPublisher publisher);
typedef LocalSmtcPublisherDetacher<T extends Object> =
    void Function(T source, LocalSmtcPublisher publisher);
typedef LocalSmtcSourceCreatedListener<T extends Object> =
    void Function(T source);

final class ActiveSessionSmtcComposition<T extends Object> {
  ActiveSessionSmtcComposition({
    required ActivePlaybackSession activeSession,
    required ActiveSessionSmtcPublisher publisher,
    required LocalSmtcPublisher localPublisher,
    required void Function(LocalSmtcSourceCreatedListener<T> listener)
    addLocalSourceCreatedListener,
    required void Function(LocalSmtcSourceCreatedListener<T> listener)
    removeLocalSourceCreatedListener,
    required LocalSmtcPublisherAttacher<T> attachLocalPublisher,
    required LocalSmtcPublisherDetacher<T> detachLocalPublisher,
    required void Function(void Function() publisher) bindRemoteKeepAlive,
    required void Function(void Function() publisher) clearRemoteKeepAlive,
  }) : _activeSession = activeSession,
       _publisher = publisher,
       _localPublisher = localPublisher,
       _addLocalSourceCreatedListener = addLocalSourceCreatedListener,
       _removeLocalSourceCreatedListener = removeLocalSourceCreatedListener,
       _attachLocalPublisher = attachLocalPublisher,
       _detachLocalPublisher = detachLocalPublisher,
       _bindRemoteKeepAlive = bindRemoteKeepAlive,
       _clearRemoteKeepAlive = clearRemoteKeepAlive {
    _activeSession.addListener(_onActiveSessionChanged);
    _addLocalSourceCreatedListener(_onLocalSourceCreated);
    _bindRemoteKeepAlive(_remoteKeepAliveHandler);
    _publishNonLocalSnapshot(_activeSession.value);
  }

  final ActivePlaybackSession _activeSession;
  final ActiveSessionSmtcPublisher _publisher;
  final LocalSmtcPublisher _localPublisher;
  final void Function(LocalSmtcSourceCreatedListener<T> listener)
  _addLocalSourceCreatedListener;
  final void Function(LocalSmtcSourceCreatedListener<T> listener)
  _removeLocalSourceCreatedListener;
  final LocalSmtcPublisherAttacher<T> _attachLocalPublisher;
  final LocalSmtcPublisherDetacher<T> _detachLocalPublisher;
  final void Function(void Function() publisher) _bindRemoteKeepAlive;
  final void Function(void Function() publisher) _clearRemoteKeepAlive;
  Future<void> _lastPublish = Future<void>.value();
  late final void Function() _remoteKeepAliveHandler = _pushRemoteKeepAlive;
  T? _localSource;
  bool _disposed = false;

  Future<void> get flush => _lastPublish;

  void _onActiveSessionChanged() {
    _publishNonLocalSnapshot(_activeSession.value);
  }

  void _publishNonLocalSnapshot(ActivePlaybackSessionSnapshot snapshot) {
    if (_disposed || snapshot.source == ActivePlaybackSessionSource.local) {
      return;
    }
    _lastPublish = _publisher.publish(snapshot);
  }

  void _pushRemoteKeepAlive() {
    if (_disposed) return;
    final snapshot = _activeSession.value;
    if (snapshot.source != ActivePlaybackSessionSource.remote) return;
    _lastPublish = _publisher.publish(snapshot);
  }

  void _onLocalSourceCreated(T source) {
    if (_disposed || _localSource != null) return;
    _localSource = source;
    try {
      _attachLocalPublisher(source, _localPublisher);
    } catch (_) {
      _localSource = null;
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _activeSession.removeListener(_onActiveSessionChanged);
    _removeLocalSourceCreatedListener(_onLocalSourceCreated);
    _clearRemoteKeepAlive(_remoteKeepAliveHandler);
    final source = _localSource;
    _localSource = null;
    if (source != null) {
      _detachLocalPublisher(source, _localPublisher);
    }
    await _publisher.dispose();
  }
}
