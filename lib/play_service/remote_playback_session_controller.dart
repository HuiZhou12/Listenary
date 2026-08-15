import 'dart:async';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';

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

enum RemotePlaybackSessionFailure { nextTrack, localRestore, remoteStop }

final class RemotePlaybackSessionController {
  RemotePlaybackSessionController({
    required RemotePlaybackQueue queue,
    required RemotePlaybackQueueController remoteController,
    required LocalPlaybackSessionBridge localBridge,
    required PlaybackBackend backend,
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
  final PlaybackBackend _backend;
  final void Function(RemotePlaybackSessionFailure failure)? _onFailure;
  late final StreamSubscription<PlaybackBackendState> _backendStateSubscription;
  LocalPlaybackResumePoint? _localResumePoint;
  String? _requestedQuality;
  int _revision = 0;
  int? _activeRemoteRevision;
  bool _sessionStarted = false;
  bool _disposed = false;

  LocalPlaybackResumePoint? get localResumePoint => _localResumePoint;

  Future<void> play(int index, {required String requestedQuality}) async {
    _throwIfDisposed();
    RangeError.checkValidIndex(index, _queue.value.items, 'index');
    if (!_sessionStarted) {
      final resumePoint = _localBridge.capture();
      if (resumePoint != null) {
        _localBridge.pause();
      }
      _localResumePoint = resumePoint;
      _sessionStarted = true;
    }
    await _playRemote(index, requestedQuality: requestedQuality);
  }

  Future<void> _playRemote(
    int index, {
    required String requestedQuality,
  }) async {
    final revision = ++_revision;
    _activeRemoteRevision = null;
    _requestedQuality = requestedQuality;
    await _remoteController.play(index, requestedQuality: requestedQuality);
    if (!_disposed && revision == _revision) {
      _activeRemoteRevision = revision;
    }
  }

  void _onBackendState(PlaybackBackendState state) {
    if (_disposed || state != PlaybackBackendState.completed) return;
    final revision = _activeRemoteRevision;
    if (!_sessionStarted || revision == null) return;
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
      } catch (_) {
        if (!_disposed && _revision == nextRevision) {
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
    _sessionStarted = false;
    _localResumePoint = null;
    _requestedQuality = null;
    _activeRemoteRevision = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _localBridge.removeLocalPlaybackRequestListener(_onLocalPlaybackRequested);
    ++_revision;
    _endSession();
    unawaited(_backendStateSubscription.cancel());
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('RemotePlaybackSessionController has been disposed');
    }
  }
}
