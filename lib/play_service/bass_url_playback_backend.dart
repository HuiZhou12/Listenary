import 'dart:async';

import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/playback_source.dart';

abstract interface class BassUrlPlaybackDriver {
  Stream<PlayerState> get stateStream;

  PlayerState get state;

  Future<void> open(Uri uri);

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<void> dispose();
}

final class BassPlayerUrlPlaybackDriver implements BassUrlPlaybackDriver {
  BassPlayerUrlPlaybackDriver({BassPlayer? player}) : _player = player;

  BassPlayer? _player;
  BassPlayer get _instance => _player ??= BassPlayer();

  @override
  Stream<PlayerState> get stateStream => _instance.playerStateStream;

  @override
  PlayerState get state => _instance.playerState;

  @override
  Future<void> open(Uri uri) async {
    _instance.setUrlSource(uri);
    _instance.start();
  }

  @override
  Future<void> pause() async {
    _player?.pause();
  }

  @override
  Future<void> resume() async {
    _player?.start();
  }

  @override
  Future<void> stop() async {
    _player?.freeFStream();
  }

  @override
  Future<void> dispose() async {
    _player?.free();
    _player = null;
  }
}

final class BassUrlPlaybackBackend implements ControllablePlaybackBackend {
  BassUrlPlaybackBackend({BassUrlPlaybackDriver? driver})
    : _driver = driver ?? BassPlayerUrlPlaybackDriver();

  final BassUrlPlaybackDriver _driver;
  final _stateController = StreamController<PlaybackBackendState>.broadcast();
  StreamSubscription<PlayerState>? _driverStateSubscription;
  Future<void> _openTail = Future<void>.value();
  int _operation = 0;
  bool _disposed = false;
  PlaybackBackendState? _lastState;

  @override
  Stream<PlaybackBackendState> get stateStream => _stateController.stream;

  @override
  Future<void> open(PlaybackSource source) {
    final operation = ++_operation;
    final completer = Completer<void>();
    final previous = _openTail;
    _openTail = completer.future.then<void>((_) {}, onError: (_, _) {});
    unawaited(
      previous.then((_) async {
        try {
          await _open(operation, source);
          completer.complete();
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      }),
    );
    return completer.future;
  }

  Future<void> _open(int operation, PlaybackSource source) async {
    if (_disposed || source is! RemotePlaybackSource) {
      throw const PlaybackBackendOpenException(
        kind: PlaybackBackendOpenFailure.unavailable,
      );
    }
    if (source.isExpiredAt(DateTime.now())) {
      throw const PlaybackBackendOpenException(
        kind: PlaybackBackendOpenFailure.expired,
      );
    }
    if (operation != _operation) return;

    await _driverStateSubscription?.cancel();
    if (operation != _operation || _disposed) return;
    _lastState = null;
    _emit(PlaybackBackendState.opening);
    _driverStateSubscription = _driver.stateStream.listen(
      (state) {
        if (!_disposed && operation == _operation) {
          _emit(_mapState(state));
        }
      },
      onError: (_) {
        if (!_disposed && operation == _operation) {
          _emit(PlaybackBackendState.failed);
        }
      },
    );

    try {
      await _driver.open(source.uri);
      if (_disposed || operation != _operation) {
        await _stopDriverSafely();
        return;
      }
      _emit(_mapState(_driver.state));
    } catch (_) {
      if (_disposed || operation != _operation) return;
      _emit(PlaybackBackendState.failed);
      throw const PlaybackBackendOpenException(
        kind: PlaybackBackendOpenFailure.unavailable,
      );
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _operation++;
    final stateSubscription = _driverStateSubscription;
    _driverStateSubscription = null;
    await _stopDriverSafely();
    await stateSubscription?.cancel();
    _emit(PlaybackBackendState.stopped);
  }

  @override
  Future<void> pause() => _control(
    expectedState: PlaybackBackendState.playing,
    action: _driver.pause,
  );

  @override
  Future<void> resume() => _control(
    expectedState: PlaybackBackendState.paused,
    action: _driver.resume,
  );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _operation++;
    await _driverStateSubscription?.cancel();
    _driverStateSubscription = null;
    try {
      await _driver.dispose();
    } catch (_) {}
    await _stateController.close();
  }

  Future<void> _stopDriverSafely() async {
    try {
      await _driver.stop();
    } catch (_) {}
  }

  Future<void> _control({
    required PlaybackBackendState expectedState,
    required Future<void> Function() action,
  }) async {
    if (_disposed || _lastState != expectedState) return;
    final operation = _operation;
    try {
      await action();
    } catch (_) {
      if (!_disposed && operation == _operation) {
        throw const PlaybackBackendControlException();
      }
      return;
    }
    if (!_disposed && operation == _operation) {
      _emit(_mapState(_driver.state));
    }
  }

  void _emit(PlaybackBackendState state) {
    if (!_disposed && !_stateController.isClosed && state != _lastState) {
      _lastState = state;
      _stateController.add(state);
    }
  }

  PlaybackBackendState _mapState(PlayerState state) => switch (state) {
    PlayerState.stopped => PlaybackBackendState.stopped,
    PlayerState.playing => PlaybackBackendState.playing,
    PlayerState.paused ||
    PlayerState.pausedDevice => PlaybackBackendState.paused,
    PlayerState.stalled => PlaybackBackendState.stalled,
    PlayerState.completed => PlaybackBackendState.completed,
    PlayerState.unknown => PlaybackBackendState.failed,
  };
}
