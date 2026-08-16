import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late _Harness harness;

  setUp(() {
    harness = _Harness();
  });

  tearDown(() => harness.dispose());

  test('inactive control does not claim the active session', () {
    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );
    expect(harness.activeSession.value.queue, isEmpty);
  });

  test('first opening exposes the queue without a current item', () async {
    final gate = Completer<void>();
    harness.gateway.nextOpen = gate.future;

    final play = harness.session.play(0, requestedQuality: 'lossless');

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.remote,
    );
    expect(
      harness.activeSession.value.state,
      ActivePlaybackSessionState.opening,
    );
    expect(harness.activeSession.value.queue.map((item) => item.title), [
      'Track 1',
      'Track 2',
      'Track 3',
    ]);
    expect(harness.activeSession.value.currentIndex, isNull);
    expect(
      harness.activeSession.value.capabilities,
      ActivePlaybackSessionCapabilities.none,
    );

    gate.complete();
    await play;
  });

  test('first failure keeps the remote queue without a current item', () async {
    harness.gateway.error = StateError('open failed');

    await expectLater(
      harness.session.play(1, requestedQuality: 'lossless'),
      throwsStateError,
    );

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.remote,
    );
    expect(
      harness.activeSession.value.state,
      ActivePlaybackSessionState.failed,
    );
    expect(harness.activeSession.value.queue, hasLength(3));
    expect(harness.activeSession.value.currentIndex, isNull);
  });

  test('successful selection maps the current safe item', () async {
    await harness.session.play(1, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);

    expect(harness.activeSession.value.currentIndex, 1);
    expect(
      harness.activeSession.value.currentItem,
      const ActivePlaybackSessionItem(
        title: 'Track 2',
        artist: 'Artist 2、Guest 2',
        album: 'Album 2',
      ),
    );
    expect(
      harness.activeSession.value.state,
      ActivePlaybackSessionState.playing,
    );
  });

  test('switch opening preserves the last successful index', () async {
    await harness.session.play(0, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);
    final gate = Completer<void>();
    harness.gateway.nextOpen = gate.future;

    final play = harness.session.play(2, requestedQuality: 'lossless');

    expect(
      harness.activeSession.value.state,
      ActivePlaybackSessionState.opening,
    );
    expect(harness.activeSession.value.currentIndex, 0);
    expect(harness.activeSession.value.currentItem?.title, 'Track 1');

    gate.complete();
    await play;
    expect(harness.activeSession.value.currentIndex, 2);
  });

  test(
    'queue replacement and selection publish through the current lease',
    () async {
      await harness.session.play(0, requestedQuality: 'lossless');
      final revision = harness.activeSession.value.revision;

      harness.queue.replace([_item('4'), _item('5')], currentIndex: 1);

      expect(harness.activeSession.value.revision, revision);
      expect(harness.activeSession.value.queue.map((item) => item.title), [
        'Track 4',
        'Track 5',
      ]);
      expect(harness.activeSession.value.currentIndex, 1);

      harness.queue.select(0);
      expect(harness.activeSession.value.currentIndex, 0);
    },
  );

  test('control state and queue boundaries map remote capabilities', () async {
    await harness.session.play(1, requestedQuality: 'lossless');

    harness.backend.emit(PlaybackBackendState.playing);
    expect(
      harness.activeSession.value.capabilities,
      const ActivePlaybackSessionCapabilities(
        canPlay: false,
        canPause: true,
        canPrevious: true,
        canNext: true,
        canSeek: false,
      ),
    );

    final pauseGate = Completer<void>();
    harness.backend.pauseGate = pauseGate.future;
    expect(harness.session.pause(), isTrue);
    expect(harness.activeSession.value.controlInFlight, isTrue);
    expect(harness.activeSession.value.capabilities.canPlay, isFalse);
    expect(harness.activeSession.value.capabilities.canPause, isFalse);
    expect(harness.activeSession.value.capabilities.canSeek, isFalse);

    pauseGate.complete();
    await pumpEventQueue();
    expect(
      harness.activeSession.value.state,
      ActivePlaybackSessionState.paused,
    );
    expect(harness.activeSession.value.capabilities.canPlay, isTrue);
    expect(harness.activeSession.value.capabilities.canPause, isFalse);

    harness.queue.select(0);
    expect(harness.activeSession.value.capabilities.canPrevious, isFalse);
    expect(harness.activeSession.value.capabilities.canNext, isTrue);
    harness.queue.select(2);
    expect(harness.activeSession.value.capabilities.canPrevious, isTrue);
    expect(harness.activeSession.value.capabilities.canNext, isFalse);
  });

  test('inactive control releases the remote lease', () async {
    await harness.session.play(0, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);

    harness.localBridge.requestLocalPlayback();

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.inactive,
    );
    expect(harness.activeSession.value.queue, isEmpty);
    expect(harness.activeSession.value.currentIndex, isNull);
  });

  test('dispose releases the lease and ignores stale source events', () async {
    await harness.session.play(0, requestedQuality: 'lossless');
    await harness.binding.dispose();
    final localLease = harness.activeSession.switchTo(
      source: ActivePlaybackSessionSource.local,
      queue: const [
        ActivePlaybackSessionItem(title: 'Local', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );

    harness.queue.replace([_item('stale')], currentIndex: 0);
    harness.backend.emit(PlaybackBackendState.playing);

    expect(
      harness.activeSession.value.source,
      ActivePlaybackSessionSource.local,
    );
    expect(harness.activeSession.value.currentItem?.title, 'Local');
    expect(harness.activeSession.release(localLease), isTrue);
  });

  test('projection excludes remote references and storage fields', () async {
    harness.queue.replace([
      RemotePlaybackQueueItem(
        ref: const PlatformTrackRef(
          platform: MusicPlatform.netease,
          trackId: 'SECRET-REF',
        ),
        title: 'Safe title',
        artists: const ['Safe artist'],
        album: 'Safe album',
        duration: const Duration(hours: 1),
      ),
    ]);

    await harness.session.play(0, requestedQuality: 'lossless');
    final item = harness.activeSession.value.currentItem!;

    expect(item.title, 'Safe title');
    expect(item.artist, 'Safe artist');
    expect(item.album, 'Safe album');
    expect(
      '${item.title}|${item.artist}|${item.album}',
      isNot(contains('SECRET-REF')),
    );
  });
}

final class _Harness {
  _Harness() {
    queue.replace([_item('1'), _item('2'), _item('3')]);
    remoteController = RemotePlaybackQueueController(
      queue: queue,
      gateway: gateway,
    );
    session = RemotePlaybackSessionController(
      queue: queue,
      remoteController: remoteController,
      localBridge: localBridge,
      backend: backend,
    );
    binding = RemoteActivePlaybackSessionBinding(
      queue: queue,
      sessionController: session,
      activeSession: activeSession,
    );
  }

  final queue = RemotePlaybackQueue();
  final gateway = _Gateway();
  final localBridge = _LocalBridge();
  final backend = _Backend();
  final activeSession = ActivePlaybackSession();
  late final RemotePlaybackQueueController remoteController;
  late final RemotePlaybackSessionController session;
  late final RemoteActivePlaybackSessionBinding binding;

  Future<void> dispose() async {
    await binding.dispose();
    session.dispose();
    remoteController.dispose();
    queue.dispose();
    activeSession.dispose();
    await backend.dispose();
  }
}

final class _Gateway implements RemoteQueuePlaybackGateway {
  Future<void>? nextOpen;
  Object? error;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    final currentError = error;
    if (currentError != null) throw currentError;
    final pending = nextOpen;
    nextOpen = null;
    if (pending != null) await pending;
  }
}

final class _LocalBridge implements LocalPlaybackSessionBridge {
  final _listeners = <void Function()>{};

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
  Future<void>? pauseGate;

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  void emit(PlaybackBackendState state) => _states.add(state);

  @override
  Future<void> open(PlaybackSource source) async {}

  @override
  Future<void> pause() async {
    final pending = pauseGate;
    pauseGate = null;
    if (pending != null) await pending;
    emit(PlaybackBackendState.paused);
  }

  @override
  Future<void> resume() async {
    emit(PlaybackBackendState.playing);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _states.close();
}

RemotePlaybackQueueItem _item(String id) => RemotePlaybackQueueItem(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
  title: 'Track $id',
  artists: ['Artist $id', 'Guest $id'],
  album: 'Album $id',
);
