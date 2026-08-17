import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/play_service/remote_playback_timeline_binding.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late _Harness harness;

  setUp(() => harness = _Harness());
  tearDown(() => harness.dispose());

  test('binds opening playing and the current queue duration', () async {
    expect(
      harness.timeline.value,
      const RemotePlaybackTimelineSnapshot.unknown(),
    );

    await harness.session.play(0, requestedQuality: 'lossless');
    expect(harness.timeline.value.position, Duration.zero);
    expect(harness.timeline.value.duration, const Duration(seconds: 10));
    expect(harness.tickers.activeCount, 0);

    harness.backend.positions.addAll([
      const Duration(seconds: 2),
      const Duration(seconds: 3),
    ]);
    harness.backend.emit(PlaybackBackendState.playing);
    expect(harness.timeline.value.position, const Duration(seconds: 2));
    expect(harness.tickers.activeCount, 1);

    harness.tickers.tickActive();
    expect(harness.timeline.value.position, const Duration(seconds: 3));
  });

  test(
    'new session revision resets position and rejects stale ticks',
    () async {
      harness.backend.positions.add(const Duration(seconds: 8));
      await harness.session.play(0, requestedQuality: 'lossless');
      harness.backend.emit(PlaybackBackendState.playing);
      final staleTicker = harness.tickers.created.single;
      final firstRevision = harness.session.playbackRevision;

      await harness.session.play(1, requestedQuality: 'lossless');
      staleTicker.tick(ignoreCancelled: true);

      expect(harness.session.playbackRevision, greaterThan(firstRevision));
      expect(harness.timeline.value.position, Duration.zero);
      expect(harness.timeline.value.duration, const Duration(seconds: 20));
      expect(harness.tickers.activeCount, 0);
    },
  );

  test('pause freezes and failed state preserves the last sample', () async {
    harness.backend.positions.addAll([
      const Duration(seconds: 4),
      const Duration(seconds: 5),
    ]);
    await harness.session.play(0, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);
    harness.backend.emit(PlaybackBackendState.paused);

    expect(harness.timeline.value.position, const Duration(seconds: 5));
    expect(harness.tickers.activeCount, 0);

    harness.backend.emit(PlaybackBackendState.failed);
    harness.tickers.tickAll(includeCancelled: true);
    expect(harness.timeline.value.position, const Duration(seconds: 5));
  });

  test('local playback request clears timeline synchronously', () async {
    harness.backend.positions.add(const Duration(seconds: 2));
    await harness.session.play(0, requestedQuality: 'lossless');
    harness.backend.emit(PlaybackBackendState.playing);

    harness.localBridge.requestLocalPlayback();

    expect(
      harness.timeline.value,
      const RemotePlaybackTimelineSnapshot.unknown(),
    );
    expect(harness.tickers.activeCount, 0);
  });

  test(
    'binding dispose clears and ignores later queue or state events',
    () async {
      harness.backend.positions.add(const Duration(seconds: 2));
      await harness.session.play(0, requestedQuality: 'lossless');
      harness.backend.emit(PlaybackBackendState.playing);

      await harness.binding.dispose();
      harness.queue.select(1);
      harness.backend.emit(PlaybackBackendState.paused);

      expect(
        harness.timeline.value,
        const RemotePlaybackTimelineSnapshot.unknown(),
      );
      expect(harness.tickers.activeCount, 0);
    },
  );
}

final class _Harness {
  _Harness() {
    queue.replace([_item('1', 10), _item('2', 20)]);
    queueController = RemotePlaybackQueueController(
      queue: queue,
      gateway: gateway,
    );
    session = RemotePlaybackSessionController(
      queue: queue,
      remoteController: queueController,
      localBridge: localBridge,
      backend: backend,
    );
    timeline = RemotePlaybackTimelineController(
      readPosition: backend.readPosition,
      tickerFactory: tickers.create,
    );
    binding = RemotePlaybackTimelineBinding(
      queue: queue,
      sessionController: session,
      timelineController: timeline,
    );
  }

  final queue = RemotePlaybackQueue();
  final gateway = _Gateway();
  final localBridge = _LocalBridge();
  final backend = _Backend();
  final tickers = _FakeTickerFactory();
  late final RemotePlaybackQueueController queueController;
  late final RemotePlaybackSessionController session;
  late final RemotePlaybackTimelineController timeline;
  late final RemotePlaybackTimelineBinding binding;

  Future<void> dispose() async {
    await binding.dispose();
    timeline.dispose();
    session.dispose();
    queueController.dispose();
    queue.dispose();
    await backend.dispose();
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

  @override
  void restore(LocalPlaybackResumePoint resumePoint) {}

  void requestLocalPlayback() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}

final class _Backend
    implements ControllablePlaybackBackend, PositionReadablePlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast(sync: true);
  final positions = <Duration?>[];

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  void emit(PlaybackBackendState state) => _states.add(state);

  @override
  Duration? readPosition() => positions.isEmpty ? null : positions.removeAt(0);

  @override
  Future<void> open(PlaybackSource source) async {}

  @override
  Future<void> pause() async => emit(PlaybackBackendState.paused);

  @override
  Future<void> resume() async => emit(PlaybackBackendState.playing);

  @override
  Future<void> stop() async => emit(PlaybackBackendState.stopped);

  @override
  Future<void> dispose() => _states.close();
}

final class _FakeTickerFactory {
  final created = <_FakeTicker>[];

  int get activeCount => created.where((ticker) => ticker.active).length;

  RemotePlaybackTimelineTicker create(
    Duration interval,
    void Function() callback,
  ) {
    final ticker = _FakeTicker(callback);
    created.add(ticker);
    return ticker;
  }

  void tickActive() => tickAll();

  void tickAll({bool includeCancelled = false}) {
    for (final ticker in List.of(created)) {
      ticker.tick(ignoreCancelled: includeCancelled);
    }
  }
}

final class _FakeTicker implements RemotePlaybackTimelineTicker {
  _FakeTicker(this._callback);

  final void Function() _callback;
  bool active = true;

  void tick({bool ignoreCancelled = false}) {
    if (active || ignoreCancelled) _callback();
  }

  @override
  void cancel() {
    active = false;
  }
}

RemotePlaybackQueueItem _item(String id, int durationSeconds) =>
    RemotePlaybackQueueItem(
      ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
      title: 'Track $id',
      artists: ['Artist $id'],
      duration: Duration(seconds: durationSeconds),
    );
