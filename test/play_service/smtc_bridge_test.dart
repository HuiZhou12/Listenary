import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/playback_source.dart';
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

  test('remote projection publishes only safe fields before state', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);
    final controller = RemoteSmtcProjectionController(bridge);

    await controller.clear();
    await controller.project(
      const RemoteSmtcProjection(
        title: 'Remote title',
        artist: 'Remote artist',
        state: PlaybackBackendState.playing,
      ),
    );

    expect(controller.hasProjection, isTrue);
    expect(backend.displayUpdates, <_DisplayUpdate>[
      const _DisplayUpdate(
        title: 'Remote title',
        artist: 'Remote artist',
        album: '',
        duration: 0,
        path: '',
      ),
    ]);
    expect(backend.operations, <String>[
      'display:Remote title',
      'state:playing',
    ]);
    expect(backend.progressUpdates, isEmpty);

    await controller.dispose();
    await bridge.close();
  });

  test('remote projection maps every non-playing state to paused', () async {
    final backend = _FakeSmtcBackend();
    final bridge = SmtcBridge.withBackend(backend);
    final controller = RemoteSmtcProjectionController(bridge);

    for (final state in PlaybackBackendState.values) {
      await controller.project(
        RemoteSmtcProjection(
          title: state.name,
          artist: 'artist',
          state: state,
        ),
      );
    }

    expect(
      backend.stateUpdates,
      PlaybackBackendState.values
          .map(
            (state) => state == PlaybackBackendState.playing
                ? SMTCState.playing
                : SMTCState.paused,
          )
          .toList(),
    );
    expect(backend.progressUpdates, isEmpty);

    await controller.dispose();
    await bridge.close();
  });

  test('new remote projection supersedes an in-flight revision', () async {
    final backend = _FakeSmtcBackend();
    final displayGate = Completer<void>();
    backend.displayGate = displayGate.future;
    final bridge = SmtcBridge.withBackend(backend);
    final controller = RemoteSmtcProjectionController(bridge);

    final first = controller.project(
      const RemoteSmtcProjection(
        title: 'Old title',
        artist: 'Old artist',
        state: PlaybackBackendState.paused,
      ),
    );
    await backend.firstDisplayCall.future;
    final second = controller.project(
      const RemoteSmtcProjection(
        title: 'New title',
        artist: 'New artist',
        state: PlaybackBackendState.playing,
      ),
    );
    displayGate.complete();
    await Future.wait([first, second]);

    expect(
      backend.displayUpdates.map((update) => update.title),
      <String>['Old title', 'New title'],
    );
    expect(backend.stateUpdates, <SMTCState>[SMTCState.playing]);
    expect(backend.operations.last, 'state:playing');

    await controller.dispose();
    await bridge.close();
  });

  test('clear invalidates an in-flight remote projection', () async {
    final backend = _FakeSmtcBackend();
    final displayGate = Completer<void>();
    backend.displayGate = displayGate.future;
    final bridge = SmtcBridge.withBackend(backend);
    final controller = RemoteSmtcProjectionController(bridge);

    final projection = controller.project(
      const RemoteSmtcProjection(
        title: 'Remote title',
        artist: 'Remote artist',
        state: PlaybackBackendState.playing,
      ),
    );
    await backend.firstDisplayCall.future;
    final clear = controller.clear();
    displayGate.complete();
    await Future.wait([projection, clear]);
    await controller.clear();

    expect(controller.hasProjection, isFalse);
    expect(backend.stateUpdates, isEmpty);
    expect(backend.operations, <String>['display:Remote title', 'clear']);

    await controller.dispose();
    await controller.dispose();
    await controller.project(
      const RemoteSmtcProjection(
        title: 'Ignored',
        artist: 'Ignored',
        state: PlaybackBackendState.playing,
      ),
    );
    await bridge.flush();

    expect(backend.operations, <String>['display:Remote title', 'clear']);
    await bridge.close();
  });

  test('dispose clears and invalidates an in-flight projection', () async {
    final backend = _FakeSmtcBackend();
    final displayGate = Completer<void>();
    backend.displayGate = displayGate.future;
    final bridge = SmtcBridge.withBackend(backend);
    final controller = RemoteSmtcProjectionController(bridge);

    final projection = controller.project(
      const RemoteSmtcProjection(
        title: 'Remote title',
        artist: 'Remote artist',
        state: PlaybackBackendState.playing,
      ),
    );
    await backend.firstDisplayCall.future;
    final dispose = controller.dispose();
    displayGate.complete();
    await Future.wait([projection, dispose]);
    await controller.dispose();
    await controller.project(
      const RemoteSmtcProjection(
        title: 'Ignored',
        artist: 'Ignored',
        state: PlaybackBackendState.playing,
      ),
    );

    expect(controller.hasProjection, isFalse);
    expect(backend.stateUpdates, isEmpty);
    expect(backend.operations, <String>['display:Remote title', 'clear']);
    await bridge.close();
  });

  test(
    'remote keep-alive refreshes display and state without timeline',
    () async {
      final backend = _FakeSmtcBackend();
      final bridge = SmtcBridge.withBackend(backend);
      final controller = RemoteSmtcProjectionController(bridge);

      controller.pushKeepAlive();
      await controller.project(
        const RemoteSmtcProjection(
          title: 'Remote title',
          artist: 'Remote artist',
          state: PlaybackBackendState.playing,
        ),
      );
      controller.pushKeepAlive();
      await pumpEventQueue();
      await bridge.flush();

      expect(backend.operations, <String>[
        'display:Remote title',
        'state:playing',
        'refresh',
        'state:playing',
      ]);
      expect(backend.progressUpdates, isEmpty);

      await controller.dispose();
      await bridge.close();
    },
  );

  test(
    'shared owner prioritizes remote and restores local publisher',
    () async {
      final backend = _FakeSmtcBackend();
      final owner = SmtcSessionOwner.withBridge(
        SmtcBridge.withBackend(backend),
        keepAliveInterval: const Duration(days: 1),
      );
      var localCount = 0;
      var latestLocalCount = 0;
      var remoteCount = 0;
      var latestRemoteCount = 0;
      void localPublisher() => localCount++;
      void latestLocalPublisher() => latestLocalCount++;
      void remotePublisher() => remoteCount++;
      void latestRemotePublisher() => latestRemoteCount++;

      owner.pushKeepAlive();
      owner.bindLocalKeepAlive(localPublisher);
      owner.startKeepAlive();
      owner.startKeepAlive();
      expect(owner.isKeepAliveRunning, isTrue);
      owner.pushKeepAlive();
      owner.bindLocalKeepAlive(latestLocalPublisher);
      owner.clearLocalKeepAlive(localPublisher);

      owner.bindRemoteKeepAlive(remotePublisher);
      owner.pushKeepAlive();
      owner.bindRemoteKeepAlive(latestRemotePublisher);
      owner.clearRemoteKeepAlive(remotePublisher);
      owner.pushKeepAlive();
      owner.clearRemoteKeepAlive(latestRemotePublisher);
      owner.clearRemoteKeepAlive(latestRemotePublisher);
      owner.pushKeepAlive();

      expect(localCount, 1);
      expect(latestLocalCount, 1);
      expect(remoteCount, 1);
      expect(latestRemoteCount, 1);
      owner.stopKeepAlive();
      owner.stopKeepAlive();
      expect(owner.isKeepAliveRunning, isFalse);

      await owner.close();
      expect(backend.closeCount, 1);
    },
  );

  test('shared owner close is idempotent and rejects new bindings', () async {
    final backend = _FakeSmtcBackend();
    final owner = SmtcSessionOwner.withBridge(SmtcBridge.withBackend(backend));

    await owner.close();
    await owner.close();
    owner.startKeepAlive();
    owner.pushKeepAlive();

    expect(owner.isKeepAliveRunning, isFalse);
    expect(backend.closeCount, 1);
    expect(() => owner.bindLocalKeepAlive(() {}), throwsStateError);
    expect(() => owner.bindRemoteKeepAlive(() {}), throwsStateError);
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
  final displayUpdates = <_DisplayUpdate>[];
  final stateUpdates = <SMTCState>[];
  final progressUpdates = <int>[];
  final firstDisplayCall = Completer<void>();
  final firstTimelineCall = Completer<void>();
  late final StreamController<SMTCControlEvent> controlController;
  late final StreamController<int> positionController;
  Future<void>? timelineGate;
  Future<void>? displayGate;
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
    displayUpdates.add(
      _DisplayUpdate(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        path: path,
      ),
    );
    operations.add('display:$title');
    if (!firstDisplayCall.isCompleted) firstDisplayCall.complete();
    await displayGate;
    displayGate = null;
  }

  @override
  Future<void> updateState(SMTCState state) async {
    stateUpdates.add(state);
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

final class _DisplayUpdate {
  const _DisplayUpdate({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.path,
  });

  final String title;
  final String artist;
  final String album;
  final int duration;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is _DisplayUpdate &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      duration == other.duration &&
      path == other.path;

  @override
  int get hashCode => Object.hash(title, artist, album, duration, path);
}
