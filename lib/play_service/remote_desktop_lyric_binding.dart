import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/desktop_lyric_service.dart';
import 'package:pure_music/play_service/lyric_service.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

final class RemoteDesktopLyricBinding {
  RemoteDesktopLyricBinding({
    required PlayService playService,
    required ActivePlaybackSession activeSession,
    required RemotePlaybackQueue queue,
    required RemotePlaybackTimelineController timeline,
    required RemoteLyricController lyrics,
  }) : _playService = playService,
       _activeSession = activeSession,
       _queue = queue,
       _timeline = timeline,
       _lyrics = lyrics {
    _activeSession.addListener(_sync);
    _queue.addListener(_sync);
    _timeline.addListener(_sync);
    _lyrics.addListener(_sync);
    _playService.addDesktopLyricServiceCreatedListener(_attachService);
    _sync();
  }

  final PlayService _playService;
  final ActivePlaybackSession _activeSession;
  final RemotePlaybackQueue _queue;
  final RemotePlaybackTimelineController _timeline;
  final RemoteLyricController _lyrics;
  DesktopLyricService? _desktopService;
  PlatformTrackRef? _lastMetadataRef;
  PlatformTrackRef? _lastLyricRef;
  RemoteLyricStatus? _lastLyricStatus;
  ActivePlaybackSessionState? _lastPlayerState;
  int? _lastLineIndex;
  bool _wasRunning = false;
  bool _disposed = false;

  void _attachService(DesktopLyricService service) {
    if (_disposed || identical(service, _desktopService)) return;
    _desktopService?.removeListener(_sync);
    _desktopService = service..addListener(_sync);
    _resetProjectionCache();
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final service = _desktopService;
    if (service == null) return;
    final active = _activeSession.value;
    final isRemote = active.source == ActivePlaybackSessionSource.remote;
    service.setLocalProjectionSuppressed(isRemote);
    if (!isRemote) {
      _resetProjectionCache();
      return;
    }
    if (!service.isRunning) {
      _wasRunning = false;
      return;
    }
    if (!_wasRunning) {
      _resetProjectionCache();
      _wasRunning = true;
    }

    final item = _queue.value.currentItem;
    if (item != null && _lastMetadataRef != item.ref) {
      _lastMetadataRef = item.ref;
      _lastLyricRef = null;
      _lastLineIndex = null;
      service.sendRemoteNowPlayingMessage(
        title: item.title,
        artist: item.artistDisplay,
        album: item.album,
      );
      service.clearRemoteLyricMessage();
    }

    if (_lastPlayerState != active.state) {
      _lastPlayerState = active.state;
      service.sendRemotePlayerStateMessage(
        active.state == ActivePlaybackSessionState.playing,
      );
    }

    final lyricSnapshot = _lyrics.value;
    if (item == null || lyricSnapshot.ref != item.ref) return;
    if (lyricSnapshot.status != RemoteLyricStatus.ready) {
      if (_lastLyricStatus != lyricSnapshot.status) {
        _lastLyricStatus = lyricSnapshot.status;
        _lastLyricRef = null;
        _lastLineIndex = null;
        service.clearRemoteLyricMessage();
      }
      return;
    }

    final lyric = lyricSnapshot.lyric;
    final lineIndex = lyricSnapshot.currentLineIndex;
    final position = _timeline.projectedSnapshot.position ?? Duration.zero;
    if (lyric == null || lineIndex == null || lineIndex >= lyric.lines.length) {
      return;
    }
    final lineChanged =
        _lastLyricRef != item.ref || _lastLineIndex != lineIndex;
    _lastLyricStatus = lyricSnapshot.status;
    _lastLyricRef = item.ref;
    _lastLineIndex = lineIndex;
    if (lineChanged) {
      service.sendRemoteLyricLineMessage(
        lyric.lines[lineIndex],
        nextLine: lineIndex + 1 < lyric.lines.length
            ? lyric.lines[lineIndex + 1]
            : null,
        isWordByWord: lyric.isWordByWord,
        position: position,
        highlightDeadlineMs: lyricHighlightDeadlineMsForLine(lyric, lineIndex),
      );
      return;
    }
    service.sendRemoteLyricProgressMessage(
      position: position,
      isPlaying: active.state == ActivePlaybackSessionState.playing,
    );
  }

  void _resetProjectionCache() {
    _lastMetadataRef = null;
    _lastLyricRef = null;
    _lastLyricStatus = null;
    _lastPlayerState = null;
    _lastLineIndex = null;
    _wasRunning = false;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playService.removeDesktopLyricServiceCreatedListener(_attachService);
    _desktopService?.removeListener(_sync);
    _activeSession.removeListener(_sync);
    _queue.removeListener(_sync);
    _timeline.removeListener(_sync);
    _lyrics.removeListener(_sync);
  }
}
