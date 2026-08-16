import 'dart:async';

import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

final class ActiveSessionSmtcPublisher {
  ActiveSessionSmtcPublisher(this._bridge);

  final SmtcBridge _bridge;
  Future<void> _operationChain = Future<void>.value();
  ActivePlaybackSessionSource _displayedSource =
      ActivePlaybackSessionSource.inactive;
  int _revision = 0;
  bool _disposed = false;

  Future<void> publish(
    ActivePlaybackSessionSnapshot snapshot, {
    LocalSmtcInput? localInput,
  }) {
    if (_disposed) return Future<void>.value();
    final token = ++_revision;
    _operationChain = _operationChain.then((_) {
      if (_disposed) return Future<void>.value();
      return _publishSnapshot(snapshot, token, localInput);
    });
    return _operationChain;
  }

  Future<void> publishLocalPosition(
    ActivePlaybackSessionSnapshot snapshot,
    int positionMs,
  ) {
    if (_disposed || snapshot.source != ActivePlaybackSessionSource.local) {
      return Future<void>.value();
    }
    final expectedRevision = _revision;
    _operationChain = _operationChain.then((_) async {
      if (_disposed ||
          expectedRevision != _revision ||
          _displayedSource != ActivePlaybackSessionSource.local) {
        return;
      }
      await _bridge.updateTimeProperties(positionMs);
    });
    return _operationChain;
  }

  Future<void> _publishSnapshot(
    ActivePlaybackSessionSnapshot snapshot,
    int token,
    LocalSmtcInput? localInput,
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
        title: localInput?.title ?? item.title,
        artist: localInput?.artist ?? item.artist,
        album: localInput?.album ?? item.album,
        duration: localInput?.durationMs ?? 0,
        path: localInput?.path ?? '',
      );
    }
    if (_disposed || token != _revision) return;

    final state =
        snapshot.source == ActivePlaybackSessionSource.local &&
            localInput != null
        ? localInput.state
        : (snapshot.state == ActivePlaybackSessionState.playing
              ? SMTCState.playing
              : SMTCState.paused);
    if (snapshot.source == ActivePlaybackSessionSource.remote) {
      await _bridge.updateRemoteState(state);
    } else {
      await _bridge.updateState(state);
      if (!_disposed && token == _revision && localInput != null) {
        await _bridge.updateTimeProperties(localInput.positionMs);
      }
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
