import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/play_service/remote_smtc_projection.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late _Harness harness;

  setUp(() {
    harness = _Harness();
  });

  tearDown(() => harness.dispose());

  test(
    'publishes safe metadata while the first target is opening',
    () async {
      final openGate = Completer<void>();
      harness.gateway.pending.add(openGate.future);

      final play = harness.session.play(0, requestedQuality: 'lossless');
      await pumpEventQueue();
      await harness.settle();

      expect(
        harness.smtc.displayUpdates.last,
        const _DisplayUpdate(
          title: 'Track 1',
          artist: 'Artist 1',
          album: '',
          duration: 0,
          path: '',
        ),
      );
      expect(harness.smtc.stateUpdates.last, SMTCState.paused);

      openGate.complete();
      await play;
      harness.backend.emit(PlaybackBackendState.playing);
      await harness.settle();

      expect(
        harness.smtc.displayUpdates.last,
        const _DisplayUpdate(
          title: 'Track 1',
          artist: 'Artist 1',
          album: '',
          duration: 0,
          path: '',
        ),
      );
      expect(harness.smtc.stateUpdates.last, SMTCState.playing);
      expect(harness.smtc.timelineUpdates, isEmpty);
    },
  );

  test('first open failure keeps the target display paused', () async {
    harness.gateway.error = StateError('open failed');

    await expectLater(
      harness.session.play(0, requestedQuality: 'lossless'),
      throwsStateError,
    );
    await harness.settle();

    expect(harness.smtc.displayUpdates.last.title, 'Track 1');
    expect(harness.smtc.stateUpdates.last, SMTCState.paused);
    expect(harness.session.controlState.state, PlaybackBackendState.failed);
  });

  test(
    'manual switch publishes target metadata while opening',
    () async {
      await harness.session.play(0, requestedQuality: 'lossless');
      harness.backend.emit(PlaybackBackendState.playing);
      await harness.settle();
      final switchGate = Completer<void>();
      harness.gateway.pending.add(switchGate.future);

      final switchTrack = harness.session.play(1, requestedQuality: 'lossless');
      await harness.settle();

      expect(harness.smtc.displayUpdates.last.title, 'Track 2');
      expect(harness.smtc.stateUpdates.last, SMTCState.paused);

      switchGate.complete();
      await switchTrack;
      await harness.settle();

      expect(harness.smtc.displayUpdates.last.title, 'Track 2');
      expect(harness.smtc.stateUpdates.last, SMTCState.paused);

      harness.backend.emit(PlaybackBackendState.playing);
      await harness.settle();
      expect(harness.smtc.displayUpdates.last.title, 'Track 2');
      expect(harness.smtc.stateUpdates.last, SMTCState.playing);
    },
  );

  test('a stale open cannot replace the newer selected item', () async {
    final oldGate = Completer<void>();
    final newGate = Completer<void>();
    harness.gateway.pending.addAll([oldGate.future, newGate.future]);

    final oldPlay = harness.session.play(0, requestedQuality: 'lossless');
    await pumpEventQueue();
    final newPlay = harness.session.play(1, requestedQuality: 'lossless');
    await pumpEventQueue();

    newGate.complete();
    await newPlay;
    harness.backend.emit(PlaybackBackendState.playing);
    await harness.settle();
    expect(harness.smtc.displayUpdates.last.title, 'Track 2');

    oldGate.complete();
    await expectLater(oldPlay, throwsException);
    await harness.settle();

    expect(harness.smtc.displayUpdates.last.title, 'Track 2');
    expect(harness.smtc.stateUpdates.last, SMTCState.playing);
  });

  test(
    'failed state preserves current metadata and completion projects next',
    () async {
      await harness.session.play(0, requestedQuality: 'lossless');
      harness.backend.emit(PlaybackBackendState.playing);
      await harness.settle();

      harness.backend.emit(PlaybackBackendState.failed);
      await harness.settle();
      expect(harness.smtc.displayUpdates.last.title, 'Track 1');
      expect(harness.smtc.stateUpdates.last, SMTCState.paused);

      final nextGate = Completer<void>();
      harness.gateway.pending.add(nextGate.future);
      harness.backend.emit(PlaybackBackendState.completed);
      await harness.settle();

      expect(harness.smtc.displayUpdates.last.title, 'Track 2');
      expect(harness.smtc.stateUpdates.last, SMTCState.paused);

      nextGate.complete();
      await harness.settle();
      expect(harness.smtc.displayUpdates.last.title, 'Track 2');
    },
  );

  test('inactive clears before scheme A local display is restored', () async {
    harness.localBridge.resumePoint = _ResumePoint();
    harness.localBridge.onRestore = () {
      unawaited(
        harness.smtcBridge.updateDisplay(
          title: 'Local track',
          artist: 'Local artist',
          album: 'Local album',
          duration: 1000,
          path: 'local.wav',
        ),
      );
    };
    await harness.session.play(1, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);
    await harness.settle();

    harness.backend.emit(PlaybackBackendState.completed);
    await harness.settle();

    expect(harness.session.controlState.isActive, isFalse);
    expect(
      harness.smtc.operations,
      containsAllInOrder(['clear', 'display:Local track']),
    );
    expect(harness.smtc.displayUpdates.last.title, 'Local track');
  });

  test(
    'natural end without a local restore point clears the display',
    () async {
      await harness.session.play(1, requestedQuality: 'lossless');
      harness.backend.emit(PlaybackBackendState.playing);
      await harness.settle();

      harness.backend.emit(PlaybackBackendState.completed);
      await harness.settle();

      expect(harness.session.controlState.isActive, isFalse);
      expect(harness.smtc.operations.last, 'clear');
    },
  );

  test('dispose clears and ignores later queue or control events', () async {
    await harness.session.play(0, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);
    await harness.settle();

    await harness.binding.dispose();
    final operationCount = harness.smtc.operations.length;
    harness.backend.emit(PlaybackBackendState.paused);
    harness.queue.select(1);
    await harness.settle();

    expect(harness.smtc.operations[operationCount - 1], 'clear');
    expect(harness.smtc.operations, hasLength(operationCount));
  });

  test(
    'lazy production binding creates one owner on target selection',
    () async {
      final lazyHarness = _Harness.lazy();
      addTearDown(lazyHarness.dispose);
      final openGate = Completer<void>();
      lazyHarness.gateway.pending.add(openGate.future);

      final play = lazyHarness.session.play(0, requestedQuality: 'lossless');
      await pumpEventQueue();

      expect(lazyHarness.projectionCreateCount, 1);
      expect(lazyHarness.keepAlivePublisher, isNotNull);
      expect(lazyHarness.lifecycleEvents, ['bind']);

      openGate.complete();
      await play;
      lazyHarness.backend.emit(PlaybackBackendState.playing);
      await lazyHarness.settle();

      expect(lazyHarness.projectionCreateCount, 1);
      expect(lazyHarness.smtc.displayUpdates.last.title, 'Track 1');
      lazyHarness.keepAlivePublisher?.call();
      await lazyHarness.settle();
      expect(lazyHarness.smtc.operations, contains('refresh'));

      await lazyHarness.session.play(1, requestedQuality: 'lossless');
      await lazyHarness.settle();
      expect(lazyHarness.projectionCreateCount, 1);

      lazyHarness.localBridge.requestLocalPlayback();
      await lazyHarness.settle();
      expect(lazyHarness.lifecycleEvents, ['bind', 'clear']);
      expect(lazyHarness.keepAlivePublisher, isNull);
      expect(lazyHarness.smtc.operations.last, 'clear');
    },
  );

  test('lazy production binding keeps the failed target owner', () async {
    final lazyHarness = _Harness.lazy();
    addTearDown(lazyHarness.dispose);
    lazyHarness.gateway.error = StateError('open failed');

    await expectLater(
      lazyHarness.session.play(0, requestedQuality: 'lossless'),
      throwsStateError,
    );
    await lazyHarness.settle();

    expect(lazyHarness.projectionCreateCount, 1);
    expect(lazyHarness.smtc.displayUpdates.last.title, 'Track 1');
    expect(lazyHarness.smtc.stateUpdates.last, SMTCState.paused);
    expect(lazyHarness.keepAlivePublisher, isNotNull);

    await lazyHarness.binding.dispose();
    expect(lazyHarness.lifecycleEvents, ['bind', 'clear']);
    expect(lazyHarness.keepAlivePublisher, isNull);
  });

  test('lazy production dispose unbinds before clearing projection', () async {
    final lazyHarness = _Harness.lazy();
    addTearDown(lazyHarness.dispose);
    await lazyHarness.session.play(0, requestedQuality: 'lossless');
    lazyHarness.backend.emit(PlaybackBackendState.playing);
    await lazyHarness.settle();
    final stalePublisher = lazyHarness.keepAlivePublisher;

    await lazyHarness.binding.dispose();
    await lazyHarness.settle();

    expect(lazyHarness.lifecycleEvents, ['bind', 'clear']);
    expect(lazyHarness.keepAlivePublisher, isNull);
    expect(lazyHarness.smtc.operations.last, 'clear');
    final operationCount = lazyHarness.smtc.operations.length;
    stalePublisher?.call();
    await lazyHarness.settle();
    expect(lazyHarness.smtc.operations, hasLength(operationCount));
  });
}

final class _Harness {
  _Harness() : _lazyProjection = false {
    _initialize();
  }

  _Harness.lazy() : _lazyProjection = true {
    _initialize();
  }

  final bool _lazyProjection;
  int projectionCreateCount = 0;
  void Function()? keepAlivePublisher;
  final lifecycleEvents = <String>[];

  void _initialize() {
    queue.replace([_item('1'), _item('2')]);
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
    binding = _lazyProjection
        ? RemoteSmtcProjectionBinding.lazy(
            queue: queue,
            sessionController: session,
            createProjectionController: () {
              projectionCreateCount++;
              return RemoteSmtcProjectionController(smtcBridge);
            },
            bindRemoteKeepAlive: (publisher) {
              lifecycleEvents.add('bind');
              keepAlivePublisher = publisher;
            },
            clearRemoteKeepAlive: (publisher) {
              if (!identical(keepAlivePublisher, publisher)) return;
              lifecycleEvents.add('clear');
              keepAlivePublisher = null;
            },
          )
        : RemoteSmtcProjectionBinding(
            queue: queue,
            sessionController: session,
            projectionController: RemoteSmtcProjectionController(smtcBridge),
          );
  }

  final queue = RemotePlaybackQueue();
  final gateway = _Gateway();
  final localBridge = _LocalBridge();
  final backend = _Backend();
  final smtc = _SmtcBackend();
  late final smtcBridge = SmtcBridge.withBackend(smtc);
  late final RemotePlaybackQueueController remoteController;
  late final RemotePlaybackSessionController session;
  late final RemoteSmtcProjectionBinding binding;

  Future<void> settle() async {
    await pumpEventQueue();
    await smtcBridge.flush();
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    await binding.dispose();
    session.dispose();
    remoteController.dispose();
    queue.dispose();
    await backend.dispose();
    await smtcBridge.close();
  }
}

RemotePlaybackQueueItem _item(String trackId) => RemotePlaybackQueueItem(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
  title: 'Track $trackId',
  artists: ['Artist $trackId'],
  album: 'Private album $trackId',
);

final class _Gateway implements RemoteQueuePlaybackGateway {
  final pending = <Future<void>>[];
  Object? error;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    if (pending.isNotEmpty) await pending.removeAt(0);
    final nextError = error;
    if (nextError != null) throw nextError;
  }
}

final class _ResumePoint implements LocalPlaybackResumePoint {}

final class _LocalBridge implements LocalPlaybackSessionBridge {
  final _listeners = <void Function()>{};
  LocalPlaybackResumePoint? resumePoint;
  void Function()? onRestore;

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
  LocalPlaybackResumePoint? capture() => resumePoint;

  @override
  void pause() {}

  @override
  void removeLocalPlaybackRequestListener(void Function() listener) {
    _listeners.remove(listener);
  }

  @override
  void restore(LocalPlaybackResumePoint resumePoint) => onRestore?.call();
}

final class _Backend implements ControllablePlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast();

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  void emit(PlaybackBackendState state) => _states.add(state);

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<void> open(PlaybackSource source) => throw UnsupportedError('open');

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}
}

final class _SmtcBackend implements SmtcBackend {
  final operations = <String>[];
  final displayUpdates = <_DisplayUpdate>[];
  final stateUpdates = <SMTCState>[];
  final timelineUpdates = <int>[];

  @override
  Stream<SMTCControlEvent> get controlEvents => const Stream.empty();

  @override
  Stream<int> get positionChangeEvents => const Stream.empty();

  @override
  Future<void> clearDisplay() async {
    operations.add('clear');
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> refreshDisplay() async {
    operations.add('refresh');
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
  }

  @override
  Future<void> updateState(SMTCState state) async {
    stateUpdates.add(state);
    operations.add('state:${state.name}');
  }

  @override
  Future<void> updateTimeProperties(int progress) async {
    timelineUpdates.add(progress);
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
