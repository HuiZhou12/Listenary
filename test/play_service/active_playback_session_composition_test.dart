import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/active_playback_session_composition.dart';
import 'package:pure_music/play_service/local_active_playback_session.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late _Harness harness;

  tearDown(() => harness.dispose());

  test('remote-only construction does not request a local source', () {
    harness = _Harness();

    expect(harness.handoff.listenerCount, 1);
    expect(harness.localAttachCount, 0);
    expect(
      harness.composition.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );
  });

  test('existing local source attaches once to the unique session', () {
    harness = _Harness(existingLocal: true);

    final session = harness.composition.activeSession;
    expect(harness.localAttachCount, 1);
    expect(session, same(harness.composition.activeSession));
    expect(session.value.source, ActivePlaybackSessionSource.local);
    expect(session.value.currentItem?.title, 'Local 1');
    expect(session.value.currentItem?.artist, 'Local artist 1');
    expect(session.value.currentItem?.album, 'Local album 1');
    expect(
      '${session.value.currentItem?.title}|'
      '${session.value.currentItem?.artist}|'
      '${session.value.currentItem?.album}',
      isNot(contains('SECRET-LOCAL-PATH')),
    );
  });

  test('delayed and duplicate local notifications attach only once', () {
    harness = _Harness();

    harness.handoff.publish(harness.localSource);
    harness.handoff.publish(harness.localSource);

    expect(harness.localAttachCount, 1);
    expect(
      harness.composition.activeSession.value.source,
      ActivePlaybackSessionSource.local,
    );
  });

  test(
    'active remote source synchronously takes priority over local',
    () async {
      harness = _Harness(existingLocal: true);

      await harness.remoteSession.play(1, requestedQuality: 'lossless');
      harness.backend.emit(PlaybackBackendState.playing);
      harness.localSource.setCurrent(2, state: PlayerState.playing);

      final snapshot = harness.composition.activeSession.value;
      expect(snapshot.source, ActivePlaybackSessionSource.remote);
      expect(snapshot.currentItem?.title, 'Remote 2');
      expect(snapshot.currentItem?.artist, 'Remote artist 2、Remote guest 2');
      expect(snapshot.currentItem?.album, 'Remote album 2');
    },
  );

  test('remote release lets the latest valid local source take over', () async {
    harness = _Harness(existingLocal: true);
    await harness.remoteSession.play(0, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);
    harness.localSource.setCurrent(2, state: PlayerState.paused);

    harness.localBridge.requestLocalPlayback();

    final snapshot = harness.composition.activeSession.value;
    expect(snapshot.source, ActivePlaybackSessionSource.local);
    expect(snapshot.currentItem?.title, 'Local 2');
    expect(snapshot.state, ActivePlaybackSessionState.paused);
  });

  test('dispose unregisters local first and does not reclaim local', () async {
    harness = _Harness(existingLocal: true);
    await harness.remoteSession.play(0, requestedQuality: 'lossless');
    final transitions = <ActivePlaybackSessionSource>[];
    final session = harness.composition.activeSession;
    session.addListener(() => transitions.add(session.value.source));

    await harness.composition.dispose();
    harness.handoff.publish(harness.localSource);
    harness.localSource.setCurrent(2, state: PlayerState.playing);
    await harness.composition.dispose();

    expect(harness.handoff.listenerCount, 0);
    expect(harness.localDisposeCount, 1);
    expect(transitions, isNot(contains(ActivePlaybackSessionSource.local)));
  });
}

final class _Harness {
  _Harness({bool existingLocal = false}) {
    remoteQueue.replace([_remoteItem(1), _remoteItem(2)]);
    remoteController = RemotePlaybackQueueController(
      queue: remoteQueue,
      gateway: gateway,
    );
    remoteSession = RemotePlaybackSessionController(
      queue: remoteQueue,
      remoteController: remoteController,
      localBridge: localBridge,
      backend: backend,
    );
    if (existingLocal) {
      handoff.publish(localSource);
    }
    composition = ActivePlaybackSessionComposition<_LocalSource>(
      remoteQueue: remoteQueue,
      remoteSessionController: remoteSession,
      addLocalSourceCreatedListener: handoff.addListener,
      removeLocalSourceCreatedListener: handoff.removeListener,
      attachLocalBinding: (source, activeSession) {
        localAttachCount++;
        final binding = LocalActivePlaybackSessionBinding(
          playlist: source.playlist,
          nowPlaying: source.nowPlaying,
          playerState: source.playerState,
          readPlaylistIndex: () => source.playlistIndex,
          activeSession: activeSession,
        );
        return () {
          localDisposeCount++;
          binding.dispose();
        };
      },
    );
  }

  final remoteQueue = RemotePlaybackQueue();
  final gateway = _Gateway();
  final localBridge = _LocalBridge();
  final backend = _Backend();
  final handoff = _LocalHandoff<_LocalSource>();
  final localSource = _LocalSource();
  late final RemotePlaybackQueueController remoteController;
  late final RemotePlaybackSessionController remoteSession;
  late final ActivePlaybackSessionComposition<_LocalSource> composition;
  int localAttachCount = 0;
  int localDisposeCount = 0;

  Future<void> dispose() async {
    await composition.dispose();
    remoteSession.dispose();
    remoteController.dispose();
    remoteQueue.dispose();
    localSource.dispose();
    await backend.dispose();
  }
}

final class _LocalHandoff<T extends Object> {
  final Set<LocalPlaybackSourceCreatedListener<T>> _listeners = {};
  T? _existing;

  int get listenerCount => _listeners.length;

  void addListener(LocalPlaybackSourceCreatedListener<T> listener) {
    if (!_listeners.add(listener)) return;
    final existing = _existing;
    if (existing != null) listener(existing);
  }

  void removeListener(LocalPlaybackSourceCreatedListener<T> listener) {
    _listeners.remove(listener);
  }

  void publish(T source) {
    _existing = source;
    for (final listener in List.of(_listeners)) {
      listener(source);
    }
  }
}

final class _LocalSource {
  _LocalSource()
    : playlist = ValueNotifier([_localAudio(1), _localAudio(2)]),
      nowPlaying = ValueNotifier(_localAudio(1)),
      playerState = ValueNotifier(PlayerState.paused);

  final ValueNotifier<List<Audio>> playlist;
  final ValueNotifier<Audio?> nowPlaying;
  final ValueNotifier<PlayerState> playerState;
  int playlistIndex = 0;

  void setCurrent(int id, {required PlayerState state}) {
    playlistIndex = id - 1;
    nowPlaying.value = playlist.value[playlistIndex];
    playerState.value = state;
  }

  void dispose() {
    playlist.dispose();
    nowPlaying.dispose();
    playerState.dispose();
  }
}

final class _Gateway implements RemoteQueuePlaybackGateway {
  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {}
}

final class _LocalBridge implements LocalPlaybackSessionBridge {
  final Set<void Function()> _listeners = {};

  @override
  void addLocalPlaybackRequestListener(void Function() listener) {
    _listeners.add(listener);
  }

  @override
  LocalPlaybackResumePoint? capture() => null;

  @override
  void pause() {}

  @override
  void removeLocalPlaybackRequestListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void requestLocalPlayback() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  @override
  void restore(LocalPlaybackResumePoint resumePoint) {}
}

final class _Backend implements ControllablePlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast(sync: true);

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  void emit(PlaybackBackendState state) => _states.add(state);

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<void> open(PlaybackSource source) async {}

  @override
  Future<void> pause() async => emit(PlaybackBackendState.paused);

  @override
  Future<void> resume() async => emit(PlaybackBackendState.playing);

  @override
  Future<void> stop() async {}
}

Audio _localAudio(int id) => Audio(
  'Local $id',
  'Local artist $id',
  'Local album $id',
  null,
  0,
  180,
  null,
  null,
  'SECRET-LOCAL-PATH-$id',
  0,
  0,
  null,
);

RemotePlaybackQueueItem _remoteItem(int id) => RemotePlaybackQueueItem(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: 'remote-$id'),
  title: 'Remote $id',
  artists: ['Remote artist $id', 'Remote guest $id'],
  album: 'Remote album $id',
);
