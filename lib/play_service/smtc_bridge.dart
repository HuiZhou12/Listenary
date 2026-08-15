import 'dart:async';

import 'package:pure_music/core/utils.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/playback_source.dart';

abstract interface class SmtcBackend {
  Stream<SMTCControlEvent> get controlEvents;
  Stream<int> get positionChangeEvents;

  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  });
  Future<void> updateState(SMTCState state);
  Future<void> updateTimeProperties(int progress);
  Future<void> refreshDisplay();
  Future<void> clearDisplay();
  Future<void> close();
}

class NativeSmtcBackend implements SmtcBackend {
  NativeSmtcBackend() : _native = SmtcFlutter();

  final SmtcFlutter _native;

  @override
  Stream<SMTCControlEvent> get controlEvents =>
      _native.subscribeToControlEvents();

  @override
  Stream<int> get positionChangeEvents => _native
      .subscribeToPositionChangeEvents()
      .map((position) => position.toInt());

  @override
  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) {
    return _native.updateDisplay(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      path: path,
    );
  }

  @override
  Future<void> updateState(SMTCState state) =>
      _native.updateState(state: state);

  @override
  Future<void> updateTimeProperties(int progress) =>
      _native.updateTimeProperties(progress: progress);

  @override
  Future<void> refreshDisplay() => _native.refreshDisplay();

  @override
  Future<void> clearDisplay() => _native.clearDisplay();

  @override
  Future<void> close() => _native.close();
}

class SmtcBridge {
  SmtcBridge.withBackend(this._backend);

  factory SmtcBridge.create() {
    try {
      return SmtcBridge.withBackend(NativeSmtcBackend());
    } catch (error, stackTrace) {
      logger.w('[smtc] initialization failed: $error\n$stackTrace');
      return SmtcBridge.withBackend(null);
    }
  }

  final SmtcBackend? _backend;
  static const _operationTimeout = Duration(seconds: 2);
  Future<void> _operationChain = Future<void>.value();
  _SmtcDisplayUpdate? _pendingDisplay;
  SMTCState? _pendingState;
  int? _pendingProgress;
  bool _displayDrainQueued = false;
  bool _stateDrainQueued = false;
  bool _timelineDrainQueued = false;
  bool _closed = false;

  Stream<SMTCControlEvent> get controlEvents =>
      _backend?.controlEvents ?? const Stream<SMTCControlEvent>.empty();

  Stream<int> get positionChangeEvents =>
      _backend?.positionChangeEvents ?? const Stream<int>.empty();

  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingDisplay = _SmtcDisplayUpdate(
      title: title,
      artist: artist,
      album: album,
      duration: duration,
      path: path,
    );
    if (_displayDrainQueued) return _operationChain;
    _displayDrainQueued = true;
    return _enqueue((backend) async {
      try {
        while (!_closed) {
          final update = _pendingDisplay;
          _pendingDisplay = null;
          if (update == null) break;
          await backend.updateDisplay(
            title: update.title,
            artist: update.artist,
            album: update.album,
            duration: update.duration,
            path: update.path,
          );
        }
      } finally {
        _displayDrainQueued = false;
      }
    }, 'update display');
  }

  Future<void> updateState(SMTCState state) {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingState = state;
    if (_stateDrainQueued) return _operationChain;
    _stateDrainQueued = true;
    return _enqueue((backend) async {
      try {
        while (!_closed) {
          final state = _pendingState;
          _pendingState = null;
          if (state == null) break;
          await backend.updateState(state);
        }
      } finally {
        _stateDrainQueued = false;
      }
    }, 'update state');
  }

  Future<void> updateTimeProperties(int progress) {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingProgress = progress;
    if (_timelineDrainQueued) return _operationChain;
    _timelineDrainQueued = true;
    return _enqueue((backend) async {
      try {
        while (!_closed) {
          final progress = _pendingProgress;
          _pendingProgress = null;
          if (progress == null) break;
          await backend.updateTimeProperties(progress);
        }
      } finally {
        _timelineDrainQueued = false;
      }
    }, 'update timeline');
  }

  Future<void> clearDisplay() {
    if (_closed || _backend == null) return Future<void>.value();
    _pendingDisplay = null;
    _pendingState = null;
    _pendingProgress = null;
    return _enqueue((backend) => backend.clearDisplay(), 'clear display');
  }

  Future<void> refreshDisplay() {
    if (_closed || _backend == null) return Future<void>.value();
    return _enqueue((backend) => backend.refreshDisplay(), 'refresh display');
  }

  Future<void> flush() => _operationChain;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pendingDisplay = null;
    _pendingState = null;
    _pendingProgress = null;
    await _operationChain;
    final backend = _backend;
    if (backend == null) return;
    try {
      await backend.close().timeout(const Duration(milliseconds: 750));
    } catch (error, stackTrace) {
      logger.w('[smtc] close failed: $error\n$stackTrace');
    }
  }

  Future<void> _enqueue(
    Future<void> Function(SmtcBackend backend) operation,
    String name,
  ) {
    final backend = _backend;
    if (_closed || backend == null) return Future<void>.value();
    _operationChain = _operationChain.then((_) async {
      try {
        await operation(backend).timeout(_operationTimeout);
      } catch (error, stackTrace) {
        logger.w('[smtc] $name failed: $error\n$stackTrace');
      }
    });
    return _operationChain;
  }
}

final class RemoteSmtcProjection {
  const RemoteSmtcProjection({
    required this.title,
    required this.artist,
    required this.state,
  });

  final String title;
  final String artist;
  final PlaybackBackendState state;
}

final class RemoteSmtcProjectionController {
  RemoteSmtcProjectionController(this._bridge);

  final SmtcBridge _bridge;
  int _revision = 0;
  bool _hasProjection = false;
  bool _disposed = false;

  bool get hasProjection => _hasProjection;

  Future<void> project(RemoteSmtcProjection projection) async {
    if (_disposed) return;
    final revision = ++_revision;
    _hasProjection = true;
    await _bridge.updateDisplay(
      title: projection.title,
      artist: projection.artist,
      album: '',
      duration: 0,
      path: '',
    );
    if (!_isCurrent(revision)) return;
    await _bridge.updateState(_mapState(projection.state));
  }

  Future<void> clear() async {
    if (_disposed) return;
    ++_revision;
    if (!_hasProjection) return;
    _hasProjection = false;
    await _bridge.clearDisplay();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    ++_revision;
    _disposed = true;
    if (!_hasProjection) return;
    _hasProjection = false;
    await _bridge.clearDisplay();
  }

  bool _isCurrent(int revision) =>
      !_disposed && revision == _revision && _hasProjection;

  SMTCState _mapState(PlaybackBackendState state) =>
      state == PlaybackBackendState.playing
      ? SMTCState.playing
      : SMTCState.paused;
}

final class SmtcSessionOwner {
  SmtcSessionOwner.withBridge(
    this.bridge, {
    this.keepAliveInterval = const Duration(seconds: 3),
  });

  factory SmtcSessionOwner.create() =>
      SmtcSessionOwner.withBridge(SmtcBridge.create());

  final SmtcBridge bridge;
  final Duration keepAliveInterval;
  StreamSubscription<SMTCControlEvent>? _controlSubscription;
  StreamSubscription<int>? _positionSubscription;
  SmtcControlRouter? _controlRouter;
  Timer? _keepAliveTimer;
  void Function()? _keepAliveHandler;
  bool _closed = false;

  bool get isKeepAliveRunning => _keepAliveTimer != null;

  void bindControlRouter(SmtcControlRouter router) {
    if (_closed) {
      throw StateError('SmtcSessionOwner has been closed');
    }
    _controlRouter = router;
    _controlSubscription ??= bridge.controlEvents.listen((event) {
      _controlRouter?.routeControl(event);
    });
    _positionSubscription ??= bridge.positionChangeEvents.listen((position) {
      _controlRouter?.routePosition(position);
    });
  }

  void clearControlRouter(SmtcControlRouter router) {
    if (identical(_controlRouter, router)) {
      _controlRouter = null;
    }
  }

  void bindKeepAlive(void Function() handler) {
    if (_closed) {
      throw StateError('SmtcSessionOwner has been closed');
    }
    _keepAliveHandler = handler;
  }

  void clearKeepAlive(void Function() handler) {
    if (identical(_keepAliveHandler, handler)) {
      _keepAliveHandler = null;
    }
  }

  void startKeepAlive() {
    if (_closed || _keepAliveTimer != null) return;
    _keepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      pushKeepAlive();
    });
  }

  void stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  void pushKeepAlive() {
    if (_closed) return;
    _keepAliveHandler?.call();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stopKeepAlive();
    _keepAliveHandler = null;
    _controlRouter = null;
    final controlSubscription = _controlSubscription;
    final positionSubscription = _positionSubscription;
    _controlSubscription = null;
    _positionSubscription = null;
    await controlSubscription?.cancel();
    await positionSubscription?.cancel();
    await bridge.close();
  }
}

final class SmtcControlRouter {
  const SmtcControlRouter({
    required this.isRemoteActive,
    required this.remotePlay,
    required this.remotePause,
    required this.remotePrevious,
    required this.remoteNext,
    required this.localPlay,
    required this.localPause,
    required this.localPrevious,
    required this.localNext,
    required this.localStop,
    required this.localPosition,
  });

  final bool Function() isRemoteActive;
  final void Function() remotePlay;
  final void Function() remotePause;
  final void Function() remotePrevious;
  final void Function() remoteNext;
  final void Function() localPlay;
  final void Function() localPause;
  final void Function() localPrevious;
  final void Function() localNext;
  final void Function() localStop;
  final void Function(int position) localPosition;

  void routeControl(SMTCControlEvent event) {
    final remoteActive = isRemoteActive();
    switch (event) {
      case SMTCControlEvent.play:
        (remoteActive ? remotePlay : localPlay)();
        break;
      case SMTCControlEvent.pause:
        (remoteActive ? remotePause : localPause)();
        break;
      case SMTCControlEvent.previous:
        (remoteActive ? remotePrevious : localPrevious)();
        break;
      case SMTCControlEvent.next:
        (remoteActive ? remoteNext : localNext)();
        break;
      case SMTCControlEvent.stop:
        if (!remoteActive) localStop();
        break;
      case SMTCControlEvent.unknown:
    }
  }

  void routePosition(int position) {
    if (!isRemoteActive()) {
      localPosition(position);
    }
  }
}

class _SmtcDisplayUpdate {
  const _SmtcDisplayUpdate({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.path,
  });

  final String title;
  final String artist;
  final String album;
  final int duration;
  final String path;
}
