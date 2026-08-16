import 'dart:async';

import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

final class ActiveSessionSmtcPublisher {
  ActiveSessionSmtcPublisher(this._bridge);

  final SmtcBridge _bridge;
  Future<void> _operationChain = Future<void>.value();
  ActivePlaybackSessionSource _displayedSource =
      ActivePlaybackSessionSource.inactive;
  int _revision = 0;
  bool _disposed = false;

  Future<void> publish(ActivePlaybackSessionSnapshot snapshot) {
    if (_disposed) return Future<void>.value();
    final token = ++_revision;
    _operationChain = _operationChain.then((_) {
      if (_disposed) return Future<void>.value();
      return _publishSnapshot(snapshot, token);
    });
    return _operationChain;
  }

  Future<void> _publishSnapshot(
    ActivePlaybackSessionSnapshot snapshot,
    int token,
  ) async {
    if (_disposed || token != _revision) return;
    if (snapshot.source == ActivePlaybackSessionSource.inactive) {
      await _clearDisplayedSource();
      return;
    }

    if (snapshot.source == ActivePlaybackSessionSource.local &&
        _displayedSource == ActivePlaybackSessionSource.remote) {
      _bridge.beginLocalDisplay();
    }

    final item = snapshot.currentItem;
    if (item == null) {
      await _clearDisplayedSource();
      return;
    }

    if (snapshot.source == ActivePlaybackSessionSource.remote) {
      await _bridge.updateRemoteDisplay(
        title: item.title,
        artist: item.artist,
        album: '',
        duration: 0,
        path: '',
      );
    } else {
      await _bridge.updateDisplay(
        title: item.title,
        artist: item.artist,
        album: item.album,
        duration: 0,
        path: '',
      );
    }
    if (_disposed || token != _revision) return;

    final state = snapshot.state == ActivePlaybackSessionState.playing
        ? SMTCState.playing
        : SMTCState.paused;
    if (snapshot.source == ActivePlaybackSessionSource.remote) {
      await _bridge.updateRemoteState(state);
    } else {
      await _bridge.updateState(state);
    }
    if (!_disposed && token == _revision) {
      _displayedSource = snapshot.source;
    }
  }

  Future<void> _clearDisplayedSource() async {
    switch (_displayedSource) {
      case ActivePlaybackSessionSource.remote:
        await _bridge.clearRemoteDisplay();
      case ActivePlaybackSessionSource.local:
        await _bridge.clearDisplay();
      case ActivePlaybackSessionSource.inactive:
        break;
    }
    _displayedSource = ActivePlaybackSessionSource.inactive;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_revision;
    await _operationChain;
    await _clearDisplayedSource();
  }
}
