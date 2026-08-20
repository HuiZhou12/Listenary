import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/remote_stream_coordinator.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late RemotePlaybackQueue queue;
  late _RecordingGateway gateway;
  late RemotePlaybackQueueController remoteController;
  late _RecordingLocalBridge localBridge;
  late RemotePlaybackSessionController sessionController;
  late _RecordingBackend backend;
  late List<RemotePlaybackSessionFailure> failures;

  setUp(() {
    queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2')]);
    gateway = _RecordingGateway();
    remoteController = RemotePlaybackQueueController(
      queue: queue,
      gateway: gateway,
    );
    localBridge = _RecordingLocalBridge();
    backend = _RecordingBackend();
    failures = [];
    sessionController = RemotePlaybackSessionController(
      queue: queue,
      remoteController: remoteController,
      localBridge: localBridge,
      backend: backend,
      onFailure: failures.add,
    );
  });

  tearDown(() async {
    sessionController.dispose();
    remoteController.dispose();
    queue.dispose();
    await backend.dispose();
  });

  test('captures and pauses local playback before opening remote', () async {
    final resumePoint = _FakeResumePoint();
    localBridge.resumePoint = resumePoint;
    localBridge.events = gateway.events;

    await sessionController.play(1, requestedQuality: 'lossless');

    expect(gateway.events, ['capture', 'pause', 'open']);
    expect(sessionController.localResumePoint, same(resumePoint));
    expect(queue.value.currentIndex, 1);
  });

  test(
    'successive remote selections preserve the first local capture',
    () async {
      final resumePoint = _FakeResumePoint();
      localBridge.resumePoint = resumePoint;

      await sessionController.play(0, requestedQuality: 'lossless');
      localBridge.resumePoint = _FakeResumePoint();
      await sessionController.play(1, requestedQuality: 'lossless');

      expect(localBridge.captureCount, 1);
      expect(localBridge.pauseCount, 1);
      expect(sessionController.localResumePoint, same(resumePoint));
      expect(gateway.refs.map((ref) => ref.trackId), ['1', '2']);
      expect(backend.stopCount, 1);
    },
  );

  test('switch selects immediately and waits for stop before opening', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    backend.emit(PlaybackBackendState.playing);
    final stopGate = Completer<void>();
    backend.pendingStops.add(stopGate.future);

    final switching = sessionController.play(1, requestedQuality: 'lossless');
    await pumpEventQueue();

    expect(backend.stopCount, 1);
    expect(queue.value.currentIndex, 1);
    expect(sessionController.controlState.state, PlaybackBackendState.opening);
    expect(gateway.refs.map((ref) => ref.trackId), ['1']);

    stopGate.complete();
    await switching;
    expect(gateway.refs.map((ref) => ref.trackId), ['1', '2']);
  });

  test('repeated opening playing and paused selections do not reopen', () async {
    final openGate = Completer<void>();
    gateway.pending.add(openGate.future);
    final firstPlay = sessionController.play(0, requestedQuality: 'lossless');
    await pumpEventQueue();

    await sessionController.play(0, requestedQuality: 'lossless');
    expect(gateway.refs, hasLength(1));
    openGate.complete();
    await firstPlay;

    backend.emit(PlaybackBackendState.playing);
    await sessionController.play(0, requestedQuality: 'lossless');
    backend.emit(PlaybackBackendState.paused);
    await sessionController.play(0, requestedQuality: 'lossless');

    expect(gateway.refs, hasLength(1));
    expect(backend.stopCount, 0);
  });

  test('failed current selection can retry', () async {
    gateway.error = StateError('open failed');
    await expectLater(
      sessionController.play(0, requestedQuality: 'lossless'),
      throwsStateError,
    );

    expect(queue.value.currentIndex, 0);
    expect(sessionController.controlState.state, PlaybackBackendState.failed);
    gateway.error = null;
    await sessionController.play(0, requestedQuality: 'lossless');

    expect(gateway.refs.map((ref) => ref.trackId), ['1', '1']);
    expect(backend.stopCount, 1);
  });

  test('stop failure keeps the target failed and does not open it', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    backend.emit(PlaybackBackendState.playing);
    backend.stopError = StateError('stop failed');

    await expectLater(
      sessionController.play(1, requestedQuality: 'lossless'),
      throwsA(isA<Exception>()),
    );

    expect(queue.value.currentIndex, 1);
    expect(sessionController.controlState.state, PlaybackBackendState.failed);
    expect(gateway.refs.map((ref) => ref.trackId), ['1']);
    expect(failures, [RemotePlaybackSessionFailure.remoteStop]);
  });

  test('opens remote directly when there is no local session', () async {
    await sessionController.play(0, requestedQuality: 'lossless');

    expect(localBridge.captureCount, 1);
    expect(localBridge.pauseCount, 0);
    expect(sessionController.localResumePoint, isNull);
    expect(gateway.refs.single.trackId, '1');
  });

  test('switches quality for the current remote track', () async {
    await sessionController.play(0, requestedQuality: 'lossless');

    final ok = await sessionController.switchQuality('exhigh');
    expect(ok, isTrue);
    expect(sessionController.requestedQuality, 'exhigh');
    expect(gateway.qualities, ['lossless', 'exhigh']);
    expect(gateway.refs.last.trackId, '1');
  });

  test('switching to the same quality is a no-op', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    gateway.qualities.clear();

    final ok = await sessionController.switchQuality('lossless');
    expect(ok, isTrue);
    expect(gateway.qualities, isEmpty);
  });

  test('switching quality failure keeps the current stream and reverts', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    gateway.error = Exception('unavailable');

    final ok = await sessionController.switchQuality('hires');
    expect(ok, isFalse);
    expect(sessionController.requestedQuality, 'lossless');
  });

  test('publishes remote control state and returns to inactive', () async {
    final snapshots = <RemotePlaybackControlSnapshot>[];
    final subscription = sessionController.controlStateStream.listen(
      snapshots.add,
    );

    expect(sessionController.controlState.isActive, isFalse);
    await sessionController.play(0, requestedQuality: 'lossless');
    expect(sessionController.controlState.state, PlaybackBackendState.opening);

    backend.emit(PlaybackBackendState.playing);
    backend.emit(PlaybackBackendState.paused);
    backend.emit(PlaybackBackendState.stalled);
    backend.emit(PlaybackBackendState.failed);
    await pumpEventQueue();
    expect(sessionController.controlState.state, PlaybackBackendState.failed);

    localBridge.requestLocalPlayback();
    expect(
      sessionController.controlState,
      RemotePlaybackControlSnapshot.inactive,
    );
    await pumpEventQueue();
    expect(snapshots.map((snapshot) => snapshot.state), [
      PlaybackBackendState.opening,
      PlaybackBackendState.playing,
      PlaybackBackendState.paused,
      PlaybackBackendState.stalled,
      PlaybackBackendState.failed,
      null,
    ]);

    await subscription.cancel();
  });

  test('pauses and resumes only in applicable remote states', () async {
    final resumePoint = _FakeResumePoint();
    localBridge.resumePoint = resumePoint;

    expect(sessionController.pause(), isFalse);
    await sessionController.play(0, requestedQuality: 'lossless');
    expect(sessionController.pause(), isTrue);
    expect(backend.pauseCount, 0);

    backend.emit(PlaybackBackendState.playing);
    await pumpEventQueue();
    expect(sessionController.pause(), isTrue);
    expect(sessionController.controlState.controlInFlight, isTrue);
    await pumpEventQueue();
    expect(backend.pauseCount, 1);
    expect(sessionController.controlState.state, PlaybackBackendState.paused);
    expect(sessionController.controlState.controlInFlight, isFalse);

    expect(sessionController.resume(), isTrue);
    await pumpEventQueue();
    expect(backend.resumeCount, 1);
    expect(sessionController.controlState.state, PlaybackBackendState.playing);
    expect(sessionController.localResumePoint, same(resumePoint));
    expect(gateway.refs, hasLength(1));
    expect(gateway.qualities, ['lossless']);
  });

  test('control in progress consumes repeated operations', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    backend.emit(PlaybackBackendState.playing);
    await pumpEventQueue();
    final pendingPause = Completer<void>();
    backend.pendingPauses.add(pendingPause.future);

    expect(sessionController.pause(), isTrue);
    expect(sessionController.pause(), isTrue);
    expect(sessionController.resume(), isTrue);
    expect(backend.pauseCount, 1);
    expect(backend.resumeCount, 0);

    pendingPause.complete();
    await pumpEventQueue();
    expect(sessionController.controlState.state, PlaybackBackendState.paused);
    expect(sessionController.controlState.controlInFlight, isFalse);
  });

  test('remote control failure reports safely and remains retryable', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    backend.emit(PlaybackBackendState.playing);
    await pumpEventQueue();
    backend.pauseError = StateError('pause failed');

    expect(sessionController.pause(), isTrue);
    await pumpEventQueue();

    expect(failures, [RemotePlaybackSessionFailure.control]);
    expect(sessionController.controlState.state, PlaybackBackendState.playing);
    expect(sessionController.controlState.controlInFlight, isFalse);

    backend.pauseError = null;
    expect(sessionController.pause(), isTrue);
    await pumpEventQueue();
    expect(backend.pauseCount, 2);
    expect(sessionController.controlState.state, PlaybackBackendState.paused);
  });

  test('ending the session suppresses a stale control failure', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    backend.emit(PlaybackBackendState.playing);
    await pumpEventQueue();
    final pendingPause = Completer<void>();
    backend.pendingPauses.add(pendingPause.future);
    backend.pauseError = StateError('stale pause failed');

    expect(sessionController.pause(), isTrue);
    localBridge.requestLocalPlayback();
    expect(sessionController.controlState.isActive, isFalse);

    pendingPause.complete();
    await pumpEventQueue();
    expect(failures, isEmpty);
    expect(sessionController.controlState.isActive, isFalse);
  });

  test('remote failure keeps the captured local session paused', () async {
    final resumePoint = _FakeResumePoint();
    localBridge.resumePoint = resumePoint;
    gateway.error = const RemoteStreamPlaybackException(
      kind: RemoteStreamPlaybackErrorKind.openFailed,
    );

    await expectLater(
      sessionController.play(0, requestedQuality: 'lossless'),
      throwsA(isA<RemoteStreamPlaybackException>()),
    );

    expect(localBridge.captureCount, 1);
    expect(localBridge.pauseCount, 1);
    expect(sessionController.localResumePoint, same(resumePoint));
    expect(queue.value.currentIndex, 0);
  });

  test(
    'pause failure leaves the session retryable and does not open',
    () async {
      final resumePoint = _FakeResumePoint();
      localBridge.resumePoint = resumePoint;
      localBridge.pauseError = StateError('pause failed');

      await expectLater(
        sessionController.play(0, requestedQuality: 'lossless'),
        throwsStateError,
      );
      expect(gateway.refs, isEmpty);
      expect(sessionController.localResumePoint, isNull);

      localBridge.pauseError = null;
      await sessionController.play(0, requestedQuality: 'lossless');
      expect(localBridge.captureCount, 2);
      expect(localBridge.pauseCount, 2);
      expect(gateway.refs.single.trackId, '1');
    },
  );

  test('natural completion advances to the next remote item once', () async {
    await sessionController.play(0, requestedQuality: 'lossless');

    backend.emit(PlaybackBackendState.completed);
    backend.emit(PlaybackBackendState.completed);
    await pumpEventQueue();

    expect(gateway.refs.map((ref) => ref.trackId), ['1', '2']);
    expect(queue.value.currentIndex, 1);
    expect(localBridge.restored, isEmpty);
  });

  test('automatic next failure reports a safe session failure', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    gateway.error = StateError('next failed');

    backend.emit(PlaybackBackendState.completed);
    await pumpEventQueue();

    expect(failures, [RemotePlaybackSessionFailure.nextTrack]);
    expect(localBridge.restored, isEmpty);
  });

  test(
    'a newer selection suppresses a cancelled automatic next error',
    () async {
      await sessionController.play(0, requestedQuality: 'lossless');
      final pendingNext = Completer<void>();
      gateway.pending.add(pendingNext.future);

      backend.emit(PlaybackBackendState.completed);
      await pumpEventQueue();
      final selected = sessionController.play(0, requestedQuality: 'lossless');
      await pumpEventQueue();
      pendingNext.complete();
      await selected;
      await pumpEventQueue();

      expect(failures, isEmpty);
      expect(queue.value.currentIndex, 0);
    },
  );

  test(
    'last item completion restores the captured local session once',
    () async {
      final resumePoint = _FakeResumePoint();
      localBridge.resumePoint = resumePoint;
      await sessionController.play(1, requestedQuality: 'lossless');

      backend.emit(PlaybackBackendState.completed);
      backend.emit(PlaybackBackendState.completed);
      await pumpEventQueue();

      expect(localBridge.restored, [same(resumePoint)]);
      expect(sessionController.localResumePoint, isNull);
      expect(failures, isEmpty);
    },
  );

  test('last item completion ends safely without a local session', () async {
    await sessionController.play(1, requestedQuality: 'lossless');

    backend.emit(PlaybackBackendState.completed);
    await pumpEventQueue();

    expect(localBridge.restored, isEmpty);
    expect(sessionController.localResumePoint, isNull);
    expect(failures, isEmpty);
  });

  test(
    'restore failure pauses local playback and reports a safe failure',
    () async {
      localBridge.resumePoint = _FakeResumePoint();
      localBridge.restoreError = StateError('restore failed');
      await sessionController.play(1, requestedQuality: 'lossless');

      backend.emit(PlaybackBackendState.completed);
      await pumpEventQueue();

      expect(localBridge.pauseCount, 2);
      expect(failures, [RemotePlaybackSessionFailure.localRestore]);
      expect(sessionController.localResumePoint, isNull);
    },
  );

  test('a replaced queue ignores completion from the old item', () async {
    localBridge.resumePoint = _FakeResumePoint();
    await sessionController.play(0, requestedQuality: 'lossless');
    queue.replace([_item('3')]);

    backend.emit(PlaybackBackendState.completed);
    await pumpEventQueue();

    expect(gateway.refs.map((ref) => ref.trackId), ['1']);
    expect(localBridge.restored, isEmpty);
    expect(failures, isEmpty);
  });

  test('manual previous and next stay inside the remote queue', () async {
    await sessionController.play(1, requestedQuality: 'lossless');

    expect(sessionController.previous(), isTrue);
    await pumpEventQueue();
    expect(queue.value.currentIndex, 0);
    expect(sessionController.next(), isTrue);
    await pumpEventQueue();

    expect(queue.value.currentIndex, 1);
    expect(gateway.refs.map((ref) => ref.trackId), ['2', '1', '2']);
    expect(gateway.qualities, everyElement('lossless'));
  });

  test('manual navigation consumes remote queue boundaries', () async {
    await sessionController.play(0, requestedQuality: 'lossless');

    expect(sessionController.previous(), isTrue);
    await pumpEventQueue();
    expect(gateway.refs, hasLength(1));

    await sessionController.play(1, requestedQuality: 'lossless');
    expect(sessionController.next(), isTrue);
    await pumpEventQueue();
    expect(gateway.refs, hasLength(2));
  });

  test('manual navigation is not consumed outside a remote session', () {
    expect(sessionController.previous(), isFalse);
    expect(sessionController.next(), isFalse);
  });

  test('manual remote navigation failure reports safely', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    gateway.error = StateError('navigation failed');

    expect(sessionController.next(), isTrue);
    await pumpEventQueue();

    expect(failures, [RemotePlaybackSessionFailure.navigation]);
    expect(queue.value.currentIndex, 1);
  });

  test('a newer selection suppresses cancelled navigation failure', () async {
    await sessionController.play(0, requestedQuality: 'lossless');
    final pendingNavigation = Completer<void>();
    gateway.pending.add(pendingNavigation.future);
    expect(sessionController.next(), isTrue);
    await pumpEventQueue();

    final selected = sessionController.play(0, requestedQuality: 'lossless');
    await pumpEventQueue();
    pendingNavigation.complete();
    await selected;
    await pumpEventQueue();

    expect(failures, isEmpty);
    expect(queue.value.currentIndex, 0);
  });

  test('local selection cancels an active remote request and stops', () async {
    localBridge.resumePoint = _FakeResumePoint();
    final pendingOpen = Completer<void>();
    gateway.pending.add(pendingOpen.future);
    final remotePlay = sessionController.play(0, requestedQuality: 'lossless');
    await pumpEventQueue();

    localBridge.requestLocalPlayback();
    expect(gateway.tokens.single.isCancelled, isTrue);
    expect(backend.stopCount, 1);
    expect(sessionController.localResumePoint, isNull);

    pendingOpen.complete();
    await expectLater(
      remotePlay,
      throwsA(isA<RemoteStreamPlaybackException>()),
    );
    backend.emit(PlaybackBackendState.completed);
    await pumpEventQueue();
    expect(localBridge.restored, isEmpty);
  });

  test('local selection without an active remote session does not stop', () {
    localBridge.requestLocalPlayback();

    expect(backend.stopCount, 0);
    expect(failures, isEmpty);
  });

  test(
    'scheme A restore does not cancel itself as a local selection',
    () async {
      localBridge.resumePoint = _FakeResumePoint();
      localBridge.notifyOnRestore = true;
      await sessionController.play(1, requestedQuality: 'lossless');

      backend.emit(PlaybackBackendState.completed);
      await pumpEventQueue();

      expect(localBridge.restored, hasLength(1));
      expect(backend.stopCount, 0);
    },
  );

  test('dispose removes the local playback request listener', () {
    sessionController.dispose();
    localBridge.requestLocalPlayback();

    expect(backend.stopCount, 0);
    expect(localBridge.listenerCount, 0);
  });

  test('invalid indexes and disposed sessions do not capture local state', () {
    expect(
      () => sessionController.play(2, requestedQuality: 'lossless'),
      throwsRangeError,
    );
    expect(localBridge.captureCount, 0);

    sessionController.dispose();
    expect(
      () => sessionController.play(0, requestedQuality: 'lossless'),
      throwsStateError,
    );
    expect(localBridge.captureCount, 0);
  });
}

RemotePlaybackQueueItem _item(String trackId) => RemotePlaybackQueueItem(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
  title: 'Track $trackId',
  artists: const ['Artist'],
);

final class _FakeResumePoint implements LocalPlaybackResumePoint {}

final class _RecordingLocalBridge implements LocalPlaybackSessionBridge {
  LocalPlaybackResumePoint? resumePoint;
  List<String> events = [];
  int captureCount = 0;
  int pauseCount = 0;
  Object? pauseError;
  Object? restoreError;
  final restored = <LocalPlaybackResumePoint>[];
  final _listeners = <void Function()>{};
  bool notifyOnRestore = false;

  int get listenerCount => _listeners.length;

  void requestLocalPlayback() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  @override
  void addLocalPlaybackRequestListener(void Function() listener) {
    _listeners.add(listener);
  }

  @override
  LocalPlaybackResumePoint? capture() {
    captureCount++;
    events.add('capture');
    return resumePoint;
  }

  @override
  void pause() {
    pauseCount++;
    events.add('pause');
    final nextError = pauseError;
    if (nextError != null) throw nextError;
  }

  @override
  void restore(LocalPlaybackResumePoint resumePoint) {
    final nextError = restoreError;
    if (nextError != null) throw nextError;
    restored.add(resumePoint);
    if (notifyOnRestore) requestLocalPlayback();
  }

  @override
  void removeLocalPlaybackRequestListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

final class _RecordingGateway implements RemoteQueuePlaybackGateway {
  final refs = <PlatformTrackRef>[];
  final qualities = <String>[];
  final events = <String>[];
  final pending = <Future<void>>[];
  final tokens = <ChkszCancelToken>[];
  Object? error;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    refs.add(ref);
    qualities.add(requestedQuality);
    tokens.add(cancelToken);
    events.add('open');
    if (pending.isNotEmpty) await pending.removeAt(0);
    final nextError = error;
    if (nextError != null) throw nextError;
  }
}

final class _RecordingBackend implements ControllablePlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast();
  final pendingPauses = <Future<void>>[];
  final pendingResumes = <Future<void>>[];
  final pendingStops = <Future<void>>[];
  Object? pauseError;
  Object? resumeError;
  Object? stopError;
  int pauseCount = 0;
  int resumeCount = 0;
  int stopCount = 0;

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  void emit(PlaybackBackendState state) => _states.add(state);

  @override
  Future<void> open(PlaybackSource source) {
    throw UnsupportedError('The session test opens through its gateway');
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    if (pendingPauses.isNotEmpty) await pendingPauses.removeAt(0);
    final error = pauseError;
    if (error != null) throw error;
    emit(PlaybackBackendState.paused);
  }

  @override
  Future<void> resume() async {
    resumeCount++;
    if (pendingResumes.isNotEmpty) await pendingResumes.removeAt(0);
    final error = resumeError;
    if (error != null) throw error;
    emit(PlaybackBackendState.playing);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    if (pendingStops.isNotEmpty) await pendingStops.removeAt(0);
    final error = stopError;
    if (error != null) throw error;
    emit(PlaybackBackendState.stopped);
  }

  @override
  Future<void> dispose() => _states.close();
}
