import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
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
}

final class RemotePlaybackSessionController {
  RemotePlaybackSessionController({
    required RemotePlaybackQueue queue,
    required RemotePlaybackQueueController remoteController,
    required LocalPlaybackSessionBridge localBridge,
  }) : _queue = queue,
       _remoteController = remoteController,
       _localBridge = localBridge;

  final RemotePlaybackQueue _queue;
  final RemotePlaybackQueueController _remoteController;
  final LocalPlaybackSessionBridge _localBridge;
  LocalPlaybackResumePoint? _localResumePoint;
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
    await _remoteController.play(index, requestedQuality: requestedQuality);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _localResumePoint = null;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('RemotePlaybackSessionController has been disposed');
    }
  }
}
