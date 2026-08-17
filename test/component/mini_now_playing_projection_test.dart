import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/mini_now_playing.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';

void main() {
  test('remote metadata ignores the paused local session', () {
    final projection = resolveMiniNowPlayingMetadata(
      snapshot: _remoteSnapshot(),
      localTitle: 'Old local title',
      localArtist: 'Old local artist',
      localAlbum: 'Old local album',
    );

    expect(projection.title, 'Remote title');
    expect(projection.subtitle, 'Remote artist');
    expect(projection.usesLocalMedia, isFalse);
    expect(projection.coverUri, Uri.parse('https://cover.invalid/remote.jpg'));
  });

  test('remote without a current item never falls back to local metadata', () {
    final projection = resolveMiniNowPlayingMetadata(
      snapshot: _remoteSnapshot(currentIndex: null),
      localTitle: 'Old local title',
      localArtist: 'Old local artist',
      localAlbum: 'Old local album',
    );

    expect(projection.title, 'Pure Music');
    expect(projection.subtitle, '享受音乐');
    expect(projection.usesLocalMedia, isFalse);
  });

  test('local and inactive sessions preserve local metadata and media', () {
    for (final snapshot in [
      _localSnapshot(),
      ActivePlaybackSessionSnapshot.inactive(revision: 3),
    ]) {
      final projection = resolveMiniNowPlayingMetadata(
        snapshot: snapshot,
        localTitle: 'Local title',
        localArtist: 'Local artist',
        localAlbum: 'Local album',
      );

      expect(projection.title, 'Local title');
      expect(projection.subtitle, 'Local artist - Local album');
      expect(projection.usesLocalMedia, isTrue);
      expect(projection.coverUri, isNull);
    }
  });

  test('remote controls follow active-session state and capabilities', () {
    final playing = resolveMiniNowPlayingControls(
      snapshot: _remoteSnapshot(
        state: ActivePlaybackSessionState.playing,
        capabilities: const ActivePlaybackSessionCapabilities(
          canPlay: false,
          canPause: true,
          canPrevious: false,
          canNext: true,
          canSeek: false,
        ),
      ),
      remoteState: const _RemoteState(PlaybackBackendState.failed),
      localState: PlayerState.paused,
      hasLocalSession: true,
    );

    expect(playing.presentation.action, PlaybackControlAction.pause);
    expect(playing.presentation.isPlaying, isTrue);
    expect(playing.canPrevious, isFalse);
    expect(playing.canNext, isTrue);

    final paused = resolveMiniNowPlayingControls(
      snapshot: _remoteSnapshot(
        state: ActivePlaybackSessionState.paused,
        capabilities: const ActivePlaybackSessionCapabilities(
          canPlay: true,
          canPause: false,
          canPrevious: true,
          canNext: false,
          canSeek: false,
        ),
      ),
      remoteState: const _RemoteState(PlaybackBackendState.playing),
      localState: PlayerState.playing,
      hasLocalSession: true,
    );

    expect(paused.presentation.action, PlaybackControlAction.play);
    expect(paused.presentation.isPlaying, isFalse);
    expect(paused.canPrevious, isTrue);
    expect(paused.canNext, isFalse);
  });

  test('remote busy and opening states disable play pause', () {
    for (final snapshot in [
      _remoteSnapshot(controlInFlight: true),
      _remoteSnapshot(state: ActivePlaybackSessionState.opening),
    ]) {
      final projection = resolveMiniNowPlayingControls(
        snapshot: snapshot,
        remoteState: const _RemoteState(PlaybackBackendState.playing),
        localState: PlayerState.playing,
        hasLocalSession: true,
      );

      expect(projection.presentation.hasSession, isTrue);
      expect(projection.presentation.canToggle, isFalse);
      expect(projection.presentation.action, PlaybackControlAction.none);
    }
  });

  test('local controls retain the existing playback presentation', () {
    final projection = resolveMiniNowPlayingControls(
      snapshot: _localSnapshot(),
      remoteState: const _RemoteState(null),
      localState: PlayerState.completed,
      hasLocalSession: true,
    );

    expect(projection.presentation.action, PlaybackControlAction.replay);
    expect(projection.canPrevious, isTrue);
    expect(projection.canNext, isTrue);
  });
}

ActivePlaybackSessionSnapshot _remoteSnapshot({
  int? currentIndex = 0,
  ActivePlaybackSessionState state = ActivePlaybackSessionState.playing,
  bool controlInFlight = false,
  ActivePlaybackSessionCapabilities capabilities =
      const ActivePlaybackSessionCapabilities(
        canPlay: false,
        canPause: true,
        canPrevious: true,
        canNext: true,
        canSeek: false,
      ),
}) => ActivePlaybackSessionSnapshot.active(
  revision: 1,
  source: ActivePlaybackSessionSource.remote,
  queue: [
    ActivePlaybackSessionItem(
      title: 'Remote title',
      artist: 'Remote artist',
      album: 'Remote album',
      coverUri: Uri.parse('https://cover.invalid/remote.jpg'),
    ),
  ],
  currentIndex: currentIndex,
  state: state,
  controlInFlight: controlInFlight,
  capabilities: capabilities,
);

ActivePlaybackSessionSnapshot _localSnapshot() =>
    ActivePlaybackSessionSnapshot.active(
      revision: 2,
      source: ActivePlaybackSessionSource.local,
      queue: const [
        ActivePlaybackSessionItem(
          title: 'Local title',
          artist: 'Local artist',
          album: 'Local album',
        ),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: true,
        canPause: false,
        canPrevious: true,
        canNext: true,
        canSeek: true,
      ),
    );

final class _RemoteState implements RemotePlaybackControlState {
  const _RemoteState(this.state);

  @override
  final PlaybackBackendState? state;

  @override
  bool get controlInFlight => false;

  @override
  bool get isActive => state != null;
}
