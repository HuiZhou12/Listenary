import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

void main() {
  test('rapid timeline updates keep only the latest pending value', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);

    for (var progress = 0; progress < 100; progress++) {
      unawaited(bridge.updateTimeProperties(progress));
    }
    await bridge.flush();

    expect(backend.progressUpdates, <int>[99]);
  });

  test('display and state updates preserve cross-stack order', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);

    unawaited(
      bridge.updateDisplay(
        title: 'title',
        artist: 'artist',
        album: 'album',
        duration: 1000,
        path: 'track.wav',
      ),
    );
    unawaited(bridge.updateState(SMTCState.playing));
    await bridge.flush();

    expect(backend.operations, <String>['display:title', 'state:playing']);
  });

  test('updates arriving during a native call are conflated', () async {
    final backend = _FakeSmtcBackend();
    final firstCall = Completer<void>();
    backend.timelineGate = firstCall.future;
    final bridge = SmtcBridge.withBackend(backend);

    unawaited(bridge.updateTimeProperties(10));
    await backend.firstTimelineCall.future;
    for (var progress = 11; progress <= 40; progress++) {
      unawaited(bridge.updateTimeProperties(progress));
    }
    firstCall.complete();
    await bridge.flush();

    expect(backend.progressUpdates, <int>[10, 40]);
  });

  test('close releases the backend and ignores later work', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);

    await bridge.close();
    await bridge.updateState(SMTCState.playing);

    expect(backend.closed, isTrue);
    expect(backend.operations, <String>['close']);
  });

  test('shared owner binds one keep-alive handler and one timer', () async {
    final backend = _FakeSmtcBackend();
    final owner = SmtcSessionOwner.withBridge(
      SmtcBridge.withBackend(backend),
      keepAliveInterval: const Duration(days: 1),
    );
    var firstCount = 0;
    var secondCount = 0;
    void firstHandler() => firstCount++;
    void secondHandler() => secondCount++;

    owner.bindKeepAlive(firstHandler);
    owner.startKeepAlive();
    owner.startKeepAlive();
    expect(owner.isKeepAliveRunning, isTrue);
    owner.pushKeepAlive();

    owner.bindKeepAlive(secondHandler);
    owner.clearKeepAlive(firstHandler);
    owner.pushKeepAlive();

    expect(firstCount, 1);
    expect(secondCount, 1);
    owner.stopKeepAlive();
    expect(owner.isKeepAliveRunning, isFalse);

    await owner.close();
    expect(backend.closeCount, 1);
  });

  test('shared owner close is idempotent and rejects new bindings', () async {
    final backend = _FakeSmtcBackend();
    final owner = SmtcSessionOwner.withBridge(SmtcBridge.withBackend(backend));

    await owner.close();
    await owner.close();
    owner.startKeepAlive();
    owner.pushKeepAlive();

    expect(owner.isKeepAliveRunning, isFalse);
    expect(backend.closeCount, 1);
    expect(() => owner.bindKeepAlive(() {}), throwsStateError);
  });

  test('control router isolates remote and local operations', () {
    var remoteActive = true;
    final calls = <String>[];
    final router = SmtcControlRouter(
      isRemoteActive: () => remoteActive,
      remotePlay: () => calls.add('remote-play'),
      remotePause: () => calls.add('remote-pause'),
      remotePrevious: () => calls.add('remote-previous'),
      remoteNext: () => calls.add('remote-next'),
      localPlay: () => calls.add('local-play'),
      localPause: () => calls.add('local-pause'),
      localPrevious: () => calls.add('local-previous'),
      localNext: () => calls.add('local-next'),
      localStop: () => calls.add('local-stop'),
      localPosition: (position) => calls.add('local-position:$position'),
    );

    for (final event in const [
      SMTCControlEvent.play,
      SMTCControlEvent.pause,
      SMTCControlEvent.previous,
      SMTCControlEvent.next,
      SMTCControlEvent.stop,
      SMTCControlEvent.unknown,
    ]) {
      router.routeControl(event);
    }
    router.routePosition(1500);

    expect(calls, <String>[
      'remote-play',
      'remote-pause',
      'remote-previous',
      'remote-next',
    ]);

    calls.clear();
    remoteActive = false;
    for (final event in const [
      SMTCControlEvent.play,
      SMTCControlEvent.pause,
      SMTCControlEvent.previous,
      SMTCControlEvent.next,
      SMTCControlEvent.stop,
      SMTCControlEvent.unknown,
    ]) {
      router.routeControl(event);
    }
    router.routePosition(2500);

    expect(calls, <String>[
      'local-play',
      'local-pause',
      'local-previous',
      'local-next',
      'local-stop',
      'local-position:2500',
    ]);
  });

  test(
    'shared owner subscribes once and routes through latest binding',
    () async {
      final backend = _FakeSmtcBackend();
      final owner = SmtcSessionOwner.withBridge(
        SmtcBridge.withBackend(backend),
      );
      final calls = <String>[];
      final first = _router(calls, 'first');
      final second = _router(calls, 'second');

      owner.bindControlRouter(first);
      owner.bindControlRouter(second);
      owner.clearControlRouter(first);
      backend.controlController.add(SMTCControlEvent.play);
      backend.positionController.add(1234);
      await pumpEventQueue();

      expect(backend.controlListenCount, 1);
      expect(backend.positionListenCount, 1);
      expect(calls, <String>['second-local-play', 'second-position:1234']);

      await owner.close();

      expect(backend.controlCancelCount, 1);
      expect(backend.positionCancelCount, 1);
      expect(backend.closeCount, 1);
      expect(() => owner.bindControlRouter(first), throwsStateError);
    },
  );
}

SmtcControlRouter _router(List<String> calls, String prefix) {
  return SmtcControlRouter(
    isRemoteActive: () => false,
    remotePlay: () => calls.add('$prefix-remote-play'),
    remotePause: () => calls.add('$prefix-remote-pause'),
    remotePrevious: () => calls.add('$prefix-remote-previous'),
    remoteNext: () => calls.add('$prefix-remote-next'),
    localPlay: () => calls.add('$prefix-local-play'),
    localPause: () => calls.add('$prefix-local-pause'),
    localPrevious: () => calls.add('$prefix-local-previous'),
    localNext: () => calls.add('$prefix-local-next'),
    localStop: () => calls.add('$prefix-local-stop'),
    localPosition: (position) => calls.add('$prefix-position:$position'),
  );
}

class _FakeSmtcBackend implements SmtcBackend {
  _FakeSmtcBackend() {
    controlController = StreamController<SMTCControlEvent>.broadcast(
      onListen: () => controlListenCount++,
      onCancel: () => controlCancelCount++,
    );
    positionController = StreamController<int>.broadcast(
      onListen: () => positionListenCount++,
      onCancel: () => positionCancelCount++,
    );
  }

  final operations = <String>[];
  final progressUpdates = <int>[];
  final firstTimelineCall = Completer<void>();
  late final StreamController<SMTCControlEvent> controlController;
  late final StreamController<int> positionController;
  Future<void>? timelineGate;
  bool closed = false;
  int closeCount = 0;
  int controlListenCount = 0;
  int positionListenCount = 0;
  int controlCancelCount = 0;
  int positionCancelCount = 0;

  @override
  Stream<SMTCControlEvent> get controlEvents => controlController.stream;

  @override
  Stream<int> get positionChangeEvents => positionController.stream;

  @override
  Future<void> clearDisplay() async {
    operations.add('clear');
  }

  @override
  Future<void> refreshDisplay() async {
    operations.add('refresh');
  }

  @override
  Future<void> close() async {
    closed = true;
    closeCount++;
    operations.add('close');
    await controlController.close();
    await positionController.close();
  }

  @override
  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) async {
    operations.add('display:$title');
  }

  @override
  Future<void> updateState(SMTCState state) async {
    operations.add('state:${state.name}');
  }

  @override
  Future<void> updateTimeProperties(int progress) async {
    progressUpdates.add(progress);
    if (!firstTimelineCall.isCompleted) firstTimelineCall.complete();
    await timelineGate;
    timelineGate = null;
  }
}
