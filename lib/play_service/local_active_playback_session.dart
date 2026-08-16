import 'package:flutter/foundation.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

final class LocalActivePlaybackSessionBinding {
  LocalActivePlaybackSessionBinding({
    required ValueListenable<List<Audio>> playlist,
    required ValueListenable<Audio?> nowPlaying,
    required ValueListenable<PlayerState> playerState,
    required int Function() readPlaylistIndex,
    required ActivePlaybackSession activeSession,
  }) : _playlist = playlist,
       _nowPlaying = nowPlaying,
       _playerState = playerState,
       _readPlaylistIndex = readPlaylistIndex,
       _activeSession = activeSession {
    _playlist.addListener(_onLocalSourceChanged);
    _nowPlaying.addListener(_onLocalSourceChanged);
    _playerState.addListener(_onLocalSourceChanged);
    _activeSession.addListener(_onActiveSessionChanged);
    _sync();
  }

  final ValueListenable<List<Audio>> _playlist;
  final ValueListenable<Audio?> _nowPlaying;
  final ValueListenable<PlayerState> _playerState;
  final int Function() _readPlaylistIndex;
  final ActivePlaybackSession _activeSession;
  ActivePlaybackSessionLease? _lease;
  bool _syncing = false;
  bool _disposed = false;

  void _onLocalSourceChanged() => _sync();

  void _onActiveSessionChanged() => _sync();

  void _sync() {
    if (_disposed || _syncing) return;
    _syncing = true;
    try {
      final source = _activeSession.value.source;
      if (source == ActivePlaybackSessionSource.remote) {
        _lease = null;
        return;
      }

      final currentIndex = _resolveCurrentIndex();
      if (currentIndex == null) {
        _releaseLease();
        return;
      }

      final queue = _playlist.value
          .map(
            (audio) => ActivePlaybackSessionItem(
              title: audio.title,
              artist: audio.artist,
              album: audio.album,
            ),
          )
          .toList(growable: false);
      final state = _mapState(_playerState.value);
      final capabilities = _capabilitiesFor(_playerState.value);
      if (source == ActivePlaybackSessionSource.inactive) {
        _lease = _activeSession.switchTo(
          source: ActivePlaybackSessionSource.local,
          queue: queue,
          currentIndex: currentIndex,
          state: state,
          controlInFlight: false,
          capabilities: capabilities,
        );
        return;
      }

      final lease = _lease;
      if (lease == null) return;
      _activeSession.publish(
        lease,
        queue: queue,
        currentIndex: currentIndex,
        state: state,
        controlInFlight: false,
        capabilities: capabilities,
      );
    } finally {
      _syncing = false;
    }
  }

  int? _resolveCurrentIndex() {
    final queue = _playlist.value;
    final current = _nowPlaying.value;
    if (queue.isEmpty || current == null) return null;

    final preferredIndex = _readPlaylistIndex();
    if (preferredIndex >= 0 &&
        preferredIndex < queue.length &&
        queue[preferredIndex].path == current.path) {
      return preferredIndex;
    }
    final matchedIndex = queue.indexWhere(
      (audio) => audio.path == current.path,
    );
    return matchedIndex < 0 ? null : matchedIndex;
  }

  void _releaseLease() {
    final lease = _lease;
    if (lease == null) return;
    _lease = null;
    _activeSession.release(lease);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playlist.removeListener(_onLocalSourceChanged);
    _nowPlaying.removeListener(_onLocalSourceChanged);
    _playerState.removeListener(_onLocalSourceChanged);
    _activeSession.removeListener(_onActiveSessionChanged);
    _releaseLease();
  }
}

ActivePlaybackSessionState _mapState(PlayerState state) => switch (state) {
  PlayerState.stopped => ActivePlaybackSessionState.stopped,
  PlayerState.playing => ActivePlaybackSessionState.playing,
  PlayerState.paused ||
  PlayerState.pausedDevice => ActivePlaybackSessionState.paused,
  PlayerState.stalled => ActivePlaybackSessionState.stalled,
  PlayerState.completed => ActivePlaybackSessionState.completed,
  PlayerState.unknown => ActivePlaybackSessionState.failed,
};

ActivePlaybackSessionCapabilities _capabilitiesFor(PlayerState state) =>
    ActivePlaybackSessionCapabilities(
      canPlay: state != PlayerState.playing,
      canPause: state == PlayerState.playing,
      canPrevious: true,
      canNext: true,
      canSeek: true,
    );
