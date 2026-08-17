import 'package:flutter/material.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_media_artwork.dart';

typedef RemotePaletteApplier = void Function(List<Color> palette);
typedef ThemeRestoreCallback = void Function();

final class RemoteMediaArtworkBinding {
  RemoteMediaArtworkBinding({
    required ActivePlaybackSession activeSession,
    required RemoteMediaArtworkController artwork,
    required RemotePaletteApplier applyRemotePalette,
    required ThemeRestoreCallback restoreLocalTheme,
    required ThemeRestoreCallback restoreConfiguredTheme,
  }) : _activeSession = activeSession,
       _artwork = artwork,
       _applyRemotePalette = applyRemotePalette,
       _restoreLocalTheme = restoreLocalTheme,
       _restoreConfiguredTheme = restoreConfiguredTheme {
    _activeSession.addListener(_onActiveSessionChanged);
    _artwork.addListener(_onArtworkChanged);
    _sync();
  }

  final ActivePlaybackSession _activeSession;
  final RemoteMediaArtworkController _artwork;
  final RemotePaletteApplier _applyRemotePalette;
  final ThemeRestoreCallback _restoreLocalTheme;
  final ThemeRestoreCallback _restoreConfiguredTheme;
  _RemoteArtworkSessionKey? _remoteKey;
  RemoteMediaArtworkSnapshot? _lastAppliedArtwork;
  bool _disposed = false;

  void _onActiveSessionChanged() {
    if (_disposed) return;
    _sync();
  }

  void _onArtworkChanged() {
    if (_disposed || _remoteKey == null) return;
    final snapshot = _artwork.value;
    if (identical(snapshot, _lastAppliedArtwork)) return;
    if (snapshot.hasArtwork && snapshot.palette.isNotEmpty) {
      _lastAppliedArtwork = snapshot;
      _applyRemotePalette(snapshot.palette);
    }
  }

  void _sync() {
    final snapshot = _activeSession.value;
    if (snapshot.source != ActivePlaybackSessionSource.remote) {
      final hadRemote = _remoteKey != null;
      _remoteKey = null;
      _lastAppliedArtwork = null;
      _artwork.clear();
      if (snapshot.source == ActivePlaybackSessionSource.local) {
        if (hadRemote) _restoreLocalTheme();
      } else if (hadRemote) {
        _restoreConfiguredTheme();
      }
      return;
    }

    final key = _RemoteArtworkSessionKey(
      revision: snapshot.revision,
      currentIndex: snapshot.currentIndex,
      coverUri: snapshot.currentItem?.coverUri,
    );
    final changed = key != _remoteKey;
    if (changed) {
      _remoteKey = key;
      _lastAppliedArtwork = null;
      _restoreConfiguredTheme();
    }
    _artwork.synchronizeRemote(
      revision: snapshot.revision,
      coverUri: snapshot.currentItem?.coverUri,
    );
    _onArtworkChanged();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeSession.removeListener(_onActiveSessionChanged);
    _artwork.removeListener(_onArtworkChanged);
    _remoteKey = null;
    _lastAppliedArtwork = null;
    _artwork.clear();
  }
}

@immutable
final class _RemoteArtworkSessionKey {
  const _RemoteArtworkSessionKey({
    required this.revision,
    required this.currentIndex,
    required this.coverUri,
  });

  final int revision;
  final int? currentIndex;
  final Uri? coverUri;

  @override
  bool operator ==(Object other) =>
      other is _RemoteArtworkSessionKey &&
      revision == other.revision &&
      currentIndex == other.currentIndex &&
      coverUri == other.coverUri;

  @override
  int get hashCode => Object.hash(revision, currentIndex, coverUri);
}
