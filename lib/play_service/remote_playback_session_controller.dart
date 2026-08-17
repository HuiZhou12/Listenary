import 'dart:async';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/services/music_platform/chksz/remote_stream_coordinator.dart';

abstract interface class LocalPlaybackResumePoint {}

final class PlaybackServiceResumePoint implements LocalPlaybackResumePoint {
  PlaybackServiceResumePoint({
    required Iterable<Audio> playlist,
    required this.playlistIndex,
    required this.position,
    required this.playerState,
  }) : playlist = List.unmodifiable(playlist);

  final List<Audio> playlist;
  final int playlistIndex;
  final double position;
  final PlayerState playerState;
}

abstract interface class LocalPlaybackSessionBridge {
  LocalPlaybackResumePoint? capture();

  void pause();

  void restore(LocalPlaybackResumePoint resumePoint);

  void addLocalPlaybackRequestListener(void Function() listener);

  void removeLocalPlaybackRequestListener(void Function() listener);
}

final class PlaybackServiceLocalPlaybackSessionBridge
    implements LocalPlaybackSessionBridge {
  const PlaybackServiceLocalPlaybackSessionBridge({
    required PlayService playService,
  }) : _playService = playService;

  final PlayService _playService;

  @override
  LocalPlaybackResumePoint? capture() {
    if (!_playService.hasPlaybackSession) return null;
    final playback = _playService.playbackService;
    final nowPlaying = playback.nowPlaying;
    final playlist = playback.playlist.value;
    if (nowPlaying == null || playlist.isEmpty) return null;

    var index = playback.playlistIndex;
    if (index >= playlist.length || playlist[index].path != nowPlaying.path) {
      index = playlist.indexWhere((audio) => audio.path == nowPlaying.path);
    }
    if (index < 0) return null;

    return PlaybackServiceResumePoint(
      playlist: playlist,
      playlistIndex: index,
      position: playback.position,
      playerState: playback.playerState,
    );
  }

  @override
  void pause() => _playService.playbackService.pause();

  @override
  void restore(LocalPlaybackResumePoint resumePoint) {
    if (resumePoint is! PlaybackServiceResumePoint) {
      throw ArgumentError.value(resumePoint, 'resumePoint');
    }
    final playback = _playService.playbackService;
    final currentPlaylist = playback.playlist.value;
    if (currentPlaylist.length != resumePoint.playlist.length) {
      throw StateError('The local playlist changed during remote playback');
    }
    for (var index = 0; index < currentPlaylist.length; index++) {
      if (currentPlaylist[index].path != resumePoint.playlist[index].path) {
        throw StateError('The local playlist changed during remote playback');
      }
    }

    if (!playback.playIndexOfPlaylist(resumePoint.playlistIndex)) {
      throw StateError('The local playback context could not be restored');
    }
    final expectedPath = resumePoint.playlist[resumePoint.playlistIndex].path;
    if (playback.nowPlaying?.path != expectedPath) {
      throw StateError('The local playback context could not be restored');
    }
    if (resumePoint.position > 0) {
      playback.seek(resumePoint.position);
    }
    if (resumePoint.playerState != PlayerState.playing) {
      playback.pause();
    }
  }

  @override
  void addLocalPlaybackRequestListener(void Function() listener) {
    _playService.addLocalPlaybackRequestListener(listener);
  }

  @override
  void removeLocalPlaybackRequestListener(void Function() listener) {
    _playService.removeLocalPlaybackRequestListener(listener);
  }
}

enum RemotePlaybackSessionFailure {
  nextTrack,
  navigation,
  control,
  localRestore,
  remoteStop,
}

final class RemotePlaybackControlSnapshot
    implements RemotePlaybackControlState {
  const RemotePlaybackControlSnapshot({
    required this.state,
    required this.controlInFlight,
  });

  static const inactive = RemotePlaybackControlSnapshot(
    state: null,
    controlInFlight: false,
  );

  @override
  final PlaybackBackendState? state;
  @override
  final bool controlInFlight;

  @override
  bool get isActive => state != null;
}

final class RemotePlaybackSessionController {
  RemotePlaybackSessionController({
    required RemotePlaybackQueue queue,
    required RemotePlaybackQueueController remoteController,
    required LocalPlaybackSessionBridge localBridge,
    required ControllablePlaybackBackend backend,
    void Function(RemotePlaybackSessionFailure failure)? onFailure,
  }) : _queue = queue,
       _remoteController = remoteController,
       _localBridge = localBridge,
       _backend = backend,
       _onFailure = onFailure {
    _backendStateSubscription = backend.stateStream.listen(_onBackendState);
    _localBridge.addLocalPlaybackRequestListener(_onLocalPlaybackRequested);
  }

  final RemotePlaybackQueue _queue;
  final RemotePlaybackQueueController _remoteController;
  final LocalPlaybackSessionBridge _localBridge;
  final ControllablePlaybackBackend _backend;
  final void Function(RemotePlaybackSessionFailure failure)? _onFailure;
  final _controlStateController =
      StreamController<RemotePlaybackControlSnapshot>.broadcast(sync: true);
  late final StreamSubscription<PlaybackBackendState> _backendStateSubscription;
  RemotePlaybackControlSnapshot _controlState =
      RemotePlaybackControlSnapshot.inactive;
  LocalPlaybackResumePoint? _localResumePoint;
  String? _requestedQuality;
  int _revision = 0;
  int _controlRevision = 0;
  int? _activeRemoteRevision;
  int? _stopTransitionRevision;
  bool _sessionStarted = false;
  bool _disposed = false;

  LocalPlaybackResumePoint? get localResumePoint => _localResumePoint;
  int get playbackRevision => _revision;
  RemotePlaybackControlSnapshot get controlState => _controlState;
  Stream<RemotePlaybackControlSnapshot> get controlStateStream =>
      _controlStateController.stream;

  bool previous() => _navigate(-1);

  bool next() => _navigate(1);

  bool pause() => _control(
    expectedState: PlaybackBackendState.playing,
    action: _backend.pause,
  );

  bool resume() => _control(
    expectedState: PlaybackBackendState.paused,
    action: _backend.resume,
  );

  bool _navigate(int offset) {
    if (_disposed || !_sessionStarted) return false;
    final snapshot = _queue.value;
    final currentIndex = snapshot.currentIndex;
    final requestedQuality = _requestedQuality;
    if (currentIndex == null || requestedQuality == null) return true;
    final targetIndex = currentIndex + offset;
    if (targetIndex < 0 || targetIndex >= snapshot.items.length) return true;
    final expectedRevision = _revision + 1;
    unawaited(
      _playRemote(targetIndex, requestedQuality: requestedQuality).catchError((
        error,
      ) {
        if (error is! _RemoteTransitionStopException &&
            !_disposed &&
            _revision == expectedRevision) {
          _onFailure?.call(RemotePlaybackSessionFailure.navigation);
        }
      }),
    );
    return true;
  }

  Future<void> play(int index, {required String requestedQuality}) async {
    _throwIfDisposed();
    RangeError.checkValidIndex(index, _queue.value.items, 'index');
    if (_ignoresRepeatedSelection(index)) return;
    final hadRemoteSession = _sessionStarted;
    if (!_sessionStarted) {
      final resumePoint = _localBridge.capture();
      if (resumePoint != null) {
        _localBridge.pause();
      }
      _localResumePoint = resumePoint;
      _sessionStarted = true;
    }
    await _playRemote(
      index,
      requestedQuality: requestedQuality,
      stopCurrent: hadRemoteSession,
    );
  }

  Future<void> _playRemote(
    int index, {
    required String requestedQuality,
    bool stopCurrent = true,
  }) async {
    final revision = ++_revision;
    _invalidateControl();
    _remoteController.cancel();
    _setControlState(
      const RemotePlaybackControlSnapshot(
        state: PlaybackBackendState.opening,
        controlInFlight: false,
      ),
    );
    _queue.select(index);
    _activeRemoteRevision = null;
    _requestedQuality = requestedQuality;
    try {
      if (stopCurrent) {
        _stopTransitionRevision = revision;
        try {
          await _backend.stop();
        } catch (_) {
          if (!_disposed && revision == _revision) {
            _onFailure?.call(RemotePlaybackSessionFailure.remoteStop);
          }
          throw const _RemoteTransitionStopException();
        } finally {
          if (_stopTransitionRevision == revision) {
            _stopTransitionRevision = null;
          }
        }
        if (_disposed || revision != _revision) {
          throw const RemoteStreamPlaybackException(
            kind: RemoteStreamPlaybackErrorKind.cancelled,
          );
        }
        _setControlState(
          const RemotePlaybackControlSnapshot(
            state: PlaybackBackendState.opening,
            controlInFlight: false,
          ),
        );
      }
      await _remoteController.play(index, requestedQuality: requestedQuality);
    } catch (_) {
      if (!_disposed && revision == _revision) {
        _setControlState(
          const RemotePlaybackControlSnapshot(
            state: PlaybackBackendState.failed,
            controlInFlight: false,
          ),
        );
      }
      rethrow;
    }
    if (!_disposed && revision == _revision) {
      _activeRemoteRevision = revision;
    }
  }

  void _onBackendState(PlaybackBackendState state) {
    if (_disposed || !_sessionStarted) return;
    if (_stopTransitionRevision != null) return;
    _setControlState(
      RemotePlaybackControlSnapshot(
        state: state,
        controlInFlight: _controlState.controlInFlight,
      ),
    );
    if (state != PlaybackBackendState.completed) return;
    final revision = _activeRemoteRevision;
    if (revision == null) return;
    _activeRemoteRevision = null;
    unawaited(_handleCompleted(revision));
  }

  void _onLocalPlaybackRequested() {
    if (_disposed || !_sessionStarted) return;
    ++_revision;
    _remoteController.cancel();
    _endSession();
    unawaited(_stopRemoteSafely());
  }

  Future<void> _stopRemoteSafely() async {
    try {
      await _backend.stop();
    } catch (_) {
      if (!_disposed) {
        _onFailure?.call(RemotePlaybackSessionFailure.remoteStop);
      }
    }
  }

  bool _control({
    required PlaybackBackendState expectedState,
    required Future<void> Function() action,
  }) {
    if (_disposed || !_sessionStarted) return false;
    if (_controlState.controlInFlight || _controlState.state != expectedState) {
      return true;
    }
    final controlRevision = ++_controlRevision;
    _setControlState(
      RemotePlaybackControlSnapshot(
        state: _controlState.state,
        controlInFlight: true,
      ),
    );
    unawaited(_runControl(controlRevision, action));
    return true;
  }

  Future<void> _runControl(
    int controlRevision,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (_isCurrentControl(controlRevision)) {
        _onFailure?.call(RemotePlaybackSessionFailure.control);
      }
    } finally {
      if (_isCurrentControl(controlRevision)) {
        _setControlState(
          RemotePlaybackControlSnapshot(
            state: _controlState.state,
            controlInFlight: false,
          ),
        );
      }
    }
  }

  bool _isCurrentControl(int controlRevision) =>
      !_disposed && _sessionStarted && controlRevision == _controlRevision;

  Future<void> _handleCompleted(int revision) async {
    if (_disposed || revision != _revision) return;
    final snapshot = _queue.value;
    final currentIndex = snapshot.currentIndex;
    final requestedQuality = _requestedQuality;
    if (currentIndex == null || requestedQuality == null) return;

    if (currentIndex + 1 < snapshot.items.length) {
      final nextRevision = _revision + 1;
      try {
        await _playRemote(currentIndex + 1, requestedQuality: requestedQuality);
      } catch (error) {
        if (error is! _RemoteTransitionStopException &&
            !_disposed &&
            _revision == nextRevision) {
          _onFailure?.call(RemotePlaybackSessionFailure.nextTrack);
        }
      }
      return;
    }

    ++_revision;
    final resumePoint = _localResumePoint;
    _endSession();
    if (resumePoint == null) return;
    try {
      _localBridge.restore(resumePoint);
    } catch (_) {
      try {
        _localBridge.pause();
      } catch (_) {}
      if (!_disposed) {
        _onFailure?.call(RemotePlaybackSessionFailure.localRestore);
      }
    }
  }

  void _endSession() {
    _invalidateControl();
    _sessionStarted = false;
    _localResumePoint = null;
    _requestedQuality = null;
    _activeRemoteRevision = null;
    _stopTransitionRevision = null;
    _setControlState(RemotePlaybackControlSnapshot.inactive);
  }

  bool _ignoresRepeatedSelection(int index) {
    if (!_sessionStarted || _queue.value.currentIndex != index) return false;
    return switch (_controlState.state) {
      PlaybackBackendState.opening ||
      PlaybackBackendState.playing ||
      PlaybackBackendState.paused ||
      PlaybackBackendState.stalled ||
      PlaybackBackendState.completed => true,
      _ => false,
    };
  }

  void _invalidateControl() {
    ++_controlRevision;
    if (_controlState.controlInFlight) {
      _setControlState(
        RemotePlaybackControlSnapshot(
          state: _controlState.state,
          controlInFlight: false,
        ),
      );
    }
  }

  void _setControlState(RemotePlaybackControlSnapshot state) {
    if (_controlState.state == state.state &&
        _controlState.controlInFlight == state.controlInFlight) {
      return;
    }
    _controlState = state;
    if (!_controlStateController.isClosed) {
      _controlStateController.add(state);
    }
  }

  void dispose() {
    if (_disposed) return;
    _localBridge.removeLocalPlaybackRequestListener(_onLocalPlaybackRequested);
    ++_revision;
    _endSession();
    _disposed = true;
    unawaited(
      _backendStateSubscription.cancel().whenComplete(
        _controlStateController.close,
      ),
    );
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('RemotePlaybackSessionController has been disposed');
    }
  }
}

final class _RemoteTransitionStopException implements Exception {
  const _RemoteTransitionStopException();
}
