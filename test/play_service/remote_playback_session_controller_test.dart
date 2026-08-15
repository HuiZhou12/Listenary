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
    },
  );

  test('opens remote directly when there is no local session', () async {
    await sessionController.play(0, requestedQuality: 'lossless');

    expect(localBridge.captureCount, 1);
    expect(localBridge.pauseCount, 0);
    expect(sessionController.localResumePoint, isNull);
    expect(gateway.refs.single.trackId, '1');
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
    expect(queue.value.currentIndex, isNull);
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
    tokens.add(cancelToken);
    events.add('open');
    if (pending.isNotEmpty) await pending.removeAt(0);
    final nextError = error;
    if (nextError != null) throw nextError;
  }
}

final class _RecordingBackend implements PlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast();
  int stopCount = 0;

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  void emit(PlaybackBackendState state) => _states.add(state);

  @override
  Future<void> open(PlaybackSource source) {
    throw UnsupportedError('The session test opens through its gateway');
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> dispose() => _states.close();
}
