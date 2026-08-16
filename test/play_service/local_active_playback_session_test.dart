import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/local_active_playback_session.dart';

void main() {
  late _Harness harness;

  tearDown(() => harness.dispose());

  test('empty local source does not claim the active session', () {
    harness = _Harness();

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );
    expect(harness.activeSession.value.queue, isEmpty);
  });

  test('valid initial source synchronously claims a safe local snapshot', () {
    final first = _audio('1', path: 'SECRET-PATH-1');
    final second = _audio('2', path: 'SECRET-PATH-2');
    harness = _Harness(
      initialPlaylist: [first, second],
      initialNowPlaying: second,
      initialIndex: 1,
      initialState: PlayerState.paused,
    );

    final snapshot = harness.activeSession.value;
    expect(snapshot.source, ActivePlaybackSessionSource.local);
    expect(snapshot.currentIndex, 1);
    expect(
      snapshot.currentItem,
      const ActivePlaybackSessionItem(
        title: 'Track 2',
        artist: 'Artist 2',
        album: 'Album 2',
      ),
    );
    expect(
      snapshot.queue.expand((item) => [item.title, item.artist, item.album]),
      isNot(contains(contains('SECRET-PATH'))),
    );
    expect(
      () => snapshot.queue.add(snapshot.currentItem!),
      throwsUnsupportedError,
    );
  });

  test('maps every local player state and preserves local controls', () {
    final audio = _audio('1');
    harness = _Harness(
      initialPlaylist: [audio],
      initialNowPlaying: audio,
      initialState: PlayerState.stopped,
    );
    const expectedStates = {
      PlayerState.stopped: ActivePlaybackSessionState.stopped,
      PlayerState.playing: ActivePlaybackSessionState.playing,
      PlayerState.paused: ActivePlaybackSessionState.paused,
      PlayerState.pausedDevice: ActivePlaybackSessionState.paused,
      PlayerState.stalled: ActivePlaybackSessionState.stalled,
      PlayerState.completed: ActivePlaybackSessionState.completed,
      PlayerState.unknown: ActivePlaybackSessionState.failed,
    };

    for (final entry in expectedStates.entries) {
      harness.playerState.value = entry.key;
      final snapshot = harness.activeSession.value;
      expect(snapshot.state, entry.value, reason: entry.key.name);
      expect(snapshot.controlInFlight, isFalse, reason: entry.key.name);
      expect(
        snapshot.capabilities.canPlay,
        entry.key != PlayerState.playing,
        reason: entry.key.name,
      );
      expect(
        snapshot.capabilities.canPause,
        entry.key == PlayerState.playing,
        reason: entry.key.name,
      );
      expect(snapshot.capabilities.canPrevious, isTrue, reason: entry.key.name);
      expect(snapshot.capabilities.canNext, isTrue, reason: entry.key.name);
      expect(snapshot.capabilities.canSeek, isTrue, reason: entry.key.name);
    }
  });

  test('queue updates use one lease and map the current item', () {
    final first = _audio('1');
    final second = _audio('2');
    final third = _audio('3');
    harness = _Harness(
      initialPlaylist: [first, second],
      initialNowPlaying: first,
    );
    final revision = harness.activeSession.value.revision;

    harness.playlist.value = [first, second, third];
    harness.playlistIndex = 2;
    harness.nowPlaying.value = third;

    expect(harness.activeSession.value.revision, revision);
    expect(harness.activeSession.value.queue, hasLength(3));
    expect(harness.activeSession.value.currentIndex, 2);
    expect(harness.activeSession.value.currentItem?.title, 'Track 3');
  });

  test('reorder falls back to path when the index notifier is early', () {
    final first = _audio('1');
    final second = _audio('2');
    final third = _audio('3');
    harness = _Harness(
      initialPlaylist: [first, second, third],
      initialNowPlaying: second,
      initialIndex: 1,
    );

    harness.playlist.value = [first, third, second];

    expect(harness.playlistIndex, 1);
    expect(harness.activeSession.value.currentIndex, 2);
    expect(harness.activeSession.value.currentItem?.title, 'Track 2');
  });

  test('missing current item releases local ownership without guessing', () {
    final first = _audio('1');
    final second = _audio('2');
    harness = _Harness(initialPlaylist: [first], initialNowPlaying: first);

    harness.playlist.value = [second];

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );
    expect(harness.activeSession.value.currentItem, isNull);

    harness.playlistIndex = 0;
    harness.nowPlaying.value = second;
    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.local,
    );
    expect(harness.activeSession.value.currentItem?.title, 'Track 2');
  });

  test('remote ownership rejects all local source updates', () {
    final first = _audio('1');
    final second = _audio('2');
    harness = _Harness(initialPlaylist: [first], initialNowPlaying: first);
    final remoteLease = harness.claimRemote();

    harness.playlist.value = [second];
    harness.playlistIndex = 0;
    harness.nowPlaying.value = second;
    harness.playerState.value = PlayerState.playing;

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.remote,
    );
    expect(harness.activeSession.value.currentItem?.title, 'Remote');
    expect(harness.activeSession.release(remoteLease), isTrue);
  });

  test('remote release creates a new local lease from the latest source', () {
    final first = _audio('1');
    final second = _audio('2');
    harness = _Harness(initialPlaylist: [first], initialNowPlaying: first);
    final remoteLease = harness.claimRemote();
    harness.playlist.value = [second];
    harness.playlistIndex = 0;
    harness.nowPlaying.value = second;
    harness.playerState.value = PlayerState.paused;

    expect(harness.activeSession.release(remoteLease), isTrue);

    final snapshot = harness.activeSession.value;
    expect(snapshot.source, ActivePlaybackSessionSource.local);
    expect(snapshot.revision, greaterThan(remoteLease.revision));
    expect(snapshot.currentItem?.title, 'Track 2');
    expect(snapshot.state, ActivePlaybackSessionState.paused);
  });

  test('remote release stays inactive without a valid local session', () {
    final audio = _audio('1');
    harness = _Harness(initialPlaylist: [audio], initialNowPlaying: audio);
    final remoteLease = harness.claimRemote();
    harness.nowPlaying.value = null;

    expect(harness.activeSession.release(remoteLease), isTrue);
    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );
  });

  test('dispose releases local ownership and ignores stale events', () {
    final first = _audio('1');
    final second = _audio('2');
    harness = _Harness(initialPlaylist: [first], initialNowPlaying: first);

    harness.binding.dispose();
    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );

    harness.playlist.value = [second];
    harness.nowPlaying.value = second;
    harness.playerState.value = PlayerState.playing;
    final remoteLease = harness.claimRemote();
    expect(harness.activeSession.release(remoteLease), isTrue);

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );
  });
}

final class _Harness {
  _Harness({
    List<Audio> initialPlaylist = const [],
    Audio? initialNowPlaying,
    int initialIndex = 0,
    PlayerState initialState = PlayerState.stopped,
  }) : playlist = ValueNotifier(List.of(initialPlaylist)),
       nowPlaying = ValueNotifier(initialNowPlaying),
       playerState = ValueNotifier(initialState),
       playlistIndex = initialIndex {
    binding = LocalActivePlaybackSessionBinding(
      playlist: playlist,
      nowPlaying: nowPlaying,
      playerState: playerState,
      readPlaylistIndex: () => playlistIndex,
      activeSession: activeSession,
    );
  }

  final ActivePlaybackSession activeSession = ActivePlaybackSession();
  final ValueNotifier<List<Audio>> playlist;
  final ValueNotifier<Audio?> nowPlaying;
  final ValueNotifier<PlayerState> playerState;
  int playlistIndex;
  late final LocalActivePlaybackSessionBinding binding;

  ActivePlaybackSessionLease claimRemote() => activeSession.switchTo(
    source: ActivePlaybackSessionSource.remote,
    queue: const [
      ActivePlaybackSessionItem(title: 'Remote', artist: 'Remote artist'),
    ],
    currentIndex: 0,
    state: ActivePlaybackSessionState.playing,
    controlInFlight: false,
    capabilities: ActivePlaybackSessionCapabilities.none,
  );

  void dispose() {
    binding.dispose();
    playlist.dispose();
    nowPlaying.dispose();
    playerState.dispose();
    activeSession.dispose();
  }
}

Audio _audio(String id, {String? path}) => Audio(
  'Track $id',
  'Artist $id',
  'Album $id',
  null,
  0,
  180,
  null,
  null,
  path ?? 'local-$id.mp3',
  0,
  0,
  null,
);
