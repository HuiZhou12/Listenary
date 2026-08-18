import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/play_service/online_history_projection.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/play_service/remote_playback_timeline_binding.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/remote_stream_coordinator.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late _Harness harness;

  setUp(() {
    harness = _Harness();
  });

  tearDown(() async {
    await harness.dispose();
  });

  test('records a remote item only after playback starts', () async {
    await harness.session.play(0, requestedQuality: 'lossless');

    expect(harness.repository.recentHistory(), isEmpty);
    await harness.emitPlaying();

    final history = harness.repository.recentHistory();
    expect(history, hasLength(1));
    expect(history.single.track.ref.trackId, '1');
    expect(history.single.track.availability, TrackAvailability.playable);
    expect(history.single.lastQuality, 'lossless');
    expect(history.single.playCount, 0);
  });

  test(
    'counts a remote session after the local listen threshold once',
    () async {
      await harness.session.play(0, requestedQuality: 'standard');
      await harness.emitPlaying();

      for (var seconds = 1; seconds <= 9; seconds++) {
        harness.tick(Duration(seconds: seconds));
      }
      await pumpEventQueue();
      expect(harness.repository.recentHistory().single.playCount, 1);

      harness.tick(const Duration(seconds: 10));
      expect(harness.repository.recentHistory().single.playCount, 1);
    },
  );

  test(
    'late stream duration updates history and enables play counting',
    () async {
      harness.queue.replace([_item('1', 0), _item('2', 90)]);
      await harness.session.play(0, requestedQuality: 'standard');
      await harness.emitPlaying();

      expect(
        harness.repository.recentHistory().single.track.duration,
        Duration.zero,
      );
      expect(
        harness.queue.enrichDuration(
          0,
          expectedRef: harness.queue.value.currentItem!.ref,
          duration: const Duration(seconds: 10),
        ),
        isTrue,
      );
      await pumpEventQueue();

      expect(
        harness.repository.recentHistory().single.track.duration,
        const Duration(seconds: 10),
      );
      for (var seconds = 1; seconds <= 9; seconds++) {
        harness.tick(Duration(seconds: seconds));
      }
      await pumpEventQueue();
      expect(harness.repository.recentHistory().single.playCount, 1);
    },
  );

  test('does not count a seek jump as accumulated listening', () async {
    await harness.session.play(0, requestedQuality: 'standard');
    await harness.emitPlaying();

    harness.tick(const Duration(seconds: 9));
    harness.tick(const Duration(seconds: 10));

    expect(harness.repository.recentHistory().single.playCount, 0);
  });

  test(
    'keeps remote history isolated across switching and local takeover',
    () async {
      await harness.session.play(0, requestedQuality: 'standard');
      await harness.emitPlaying();
      harness.tick(const Duration(seconds: 1));

      await harness.session.play(1, requestedQuality: 'lossless');
      await harness.emitPlaying();
      harness.tick(const Duration(seconds: 1));
      harness.localBridge.requestLocalPlayback();
      harness.tick(const Duration(seconds: 60));
      await pumpEventQueue();

      expect(
        harness.repository.recentHistory().map(
          (entry) => entry.track.ref.trackId,
        ),
        ['2', '1'],
      );
      expect(
        harness.repository.recentHistory().map((entry) => entry.playCount),
        [0, 0],
      );
    },
  );

  test('does not write history when resolving fails before playing', () async {
    harness.gateway.error = const RemoteStreamPlaybackException(
      kind: RemoteStreamPlaybackErrorKind.openFailed,
    );

    await expectLater(
      harness.session.play(0, requestedQuality: 'standard'),
      throwsA(isA<RemoteStreamPlaybackException>()),
    );

    expect(harness.repository.recentHistory(), isEmpty);
  });

  test('database failures do not interrupt remote playback state', () async {
    await harness.session.play(0, requestedQuality: 'standard');
    harness.closeDatabase();

    await harness.emitPlaying();

    expect(harness.session.controlState.state, PlaybackBackendState.playing);
    expect(harness.failures, [OnlineHistoryProjectionFailure.playbackStarted]);
  });
}

final class _Harness {
  _Harness() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    historyController = OnlineHistoryController(
      repository: Future.value(repository),
    );
    queue.replace([_item('1', 10), _item('2', 90)]);
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
    timelineBinding = RemotePlaybackTimelineBinding(
      queue: queue,
      sessionController: session,
      timelineController: timeline,
    );
    historyBinding = OnlineHistoryProjectionBinding(
      queue: queue,
      sessionController: session,
      timelineController: timeline,
      historyController: historyController,
      onFailure: failures.add,
    );
  }

  late final Database database;
  late final OnlineLibraryRepository repository;
  late final OnlineHistoryController historyController;
  final queue = RemotePlaybackQueue();
  final gateway = _Gateway();
  final localBridge = _LocalBridge();
  final backend = _Backend();
  final tickers = _TickerFactory();
  final failures = <OnlineHistoryProjectionFailure>[];
  late final RemotePlaybackQueueController queueController;
  late final RemotePlaybackSessionController session;
  late final RemotePlaybackTimelineController timeline;
  late final RemotePlaybackTimelineBinding timelineBinding;
  late final OnlineHistoryProjectionBinding historyBinding;
  bool _databaseClosed = false;

  Future<void> emitPlaying() async {
    backend.positions.add(Duration.zero);
    backend.emit(PlaybackBackendState.playing);
    await pumpEventQueue();
  }

  void tick(Duration position) {
    backend.positions.add(position);
    tickers.tickActive();
  }

  void closeDatabase() {
    database.dispose();
    _databaseClosed = true;
  }

  Future<void> dispose() async {
    await historyBinding.dispose();
    historyController.dispose();
    await timelineBinding.dispose();
    timeline.dispose();
    session.dispose();
    queueController.dispose();
    queue.dispose();
    await backend.dispose();
    if (!_databaseClosed) database.dispose();
  }
}

RemotePlaybackQueueItem _item(String id, int durationSeconds) =>
    RemotePlaybackQueueItem(
      ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
      title: 'Track $id',
      artists: ['Artist $id'],
      album: 'Album $id',
      duration: Duration(seconds: durationSeconds),
    );

final class _Gateway implements RemoteQueuePlaybackGateway {
  Object? error;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    final nextError = error;
    if (nextError != null) throw nextError;
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
  Future<void> dispose() => _states.close();

  @override
  Future<void> open(PlaybackSource source) async {}

  @override
  Future<void> pause() async => emit(PlaybackBackendState.paused);

  @override
  Future<void> resume() async => emit(PlaybackBackendState.playing);

  @override
  Future<void> stop() async => emit(PlaybackBackendState.stopped);
}

final class _TickerFactory {
  final created = <_Ticker>[];

  RemotePlaybackTimelineTicker create(
    Duration interval,
    void Function() callback,
  ) {
    final ticker = _Ticker(callback);
    created.add(ticker);
    return ticker;
  }

  void tickActive() {
    for (final ticker in List.of(created)) {
      ticker.tick();
    }
  }
}

final class _Ticker implements RemotePlaybackTimelineTicker {
  _Ticker(this._callback);

  final void Function() _callback;
  bool _active = true;

  void tick() {
    if (_active) _callback();
  }

  @override
  void cancel() {
    _active = false;
  }
}
