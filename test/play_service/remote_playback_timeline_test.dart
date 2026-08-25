import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';

void main() {
  test('unknown snapshot keeps position and duration explicit', () {
    const snapshot = RemotePlaybackTimelineSnapshot.unknown();

    expect(snapshot.position, isNull);
    expect(snapshot.duration, isNull);
    expect(snapshot.hasKnownPosition, isFalse);
    expect(snapshot.hasKnownDuration, isFalse);
    expect(snapshot.progress, isNull);
  });

  test('normalizes invalid position and duration to unknown', () {
    final snapshot = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(milliseconds: -1),
      duration: Duration.zero,
    );

    expect(snapshot.position, isNull);
    expect(snapshot.duration, isNull);
  });

  test('keeps a known zero position with unknown duration', () {
    final snapshot = RemotePlaybackTimelineSnapshot.normalized(
      position: Duration.zero,
      duration: null,
    );

    expect(snapshot.position, Duration.zero);
    expect(snapshot.duration, isNull);
    expect(snapshot.hasKnownPosition, isTrue);
    expect(snapshot.progress, isNull);
  });

  test('clamps position to a known duration', () {
    final snapshot = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(seconds: 80),
      duration: const Duration(seconds: 60),
    );

    expect(snapshot.position, const Duration(seconds: 60));
    expect(snapshot.duration, const Duration(seconds: 60));
    expect(snapshot.progress, 1.0);
  });

  test('supports value equality for stable projections', () {
    final first = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(seconds: 15),
      duration: const Duration(seconds: 60),
    );
    final second = RemotePlaybackTimelineSnapshot.normalized(
      position: const Duration(seconds: 15),
      duration: const Duration(seconds: 60),
    );

    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(first.progress, 0.25);
  });

  group('controller', () {
    late _FakeTickerFactory tickerFactory;
    late List<Duration?> positions;
    late RemotePlaybackTimelineController controller;
    late Duration now;

    setUp(() {
      tickerFactory = _FakeTickerFactory();
      positions = [];
      now = Duration.zero;
      controller = RemotePlaybackTimelineController(
        readPosition: () => positions.isEmpty ? null : positions.removeAt(0),
        tickerFactory: tickerFactory.create,
        clock: () => now,
      );
    });

    tearDown(() => controller.dispose());

    test('playing samples immediately and keeps one 50ms ticker', () {
      positions.addAll([
        const Duration(seconds: 2),
        const Duration(seconds: 3),
      ]);

      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );

      expect(controller.value.position, const Duration(seconds: 2));
      expect(tickerFactory.activeCount, 1);
      expect(
        tickerFactory.created.single.interval,
        const Duration(milliseconds: 50),
      );

      tickerFactory.tickActive();
      expect(controller.value.position, const Duration(seconds: 3));
      expect(tickerFactory.activeCount, 1);
    });

    test('playing projects between samples without another native read', () {
      var notifications = 0;
      controller.addListener(() => notifications++);
      positions.add(const Duration(seconds: 2));
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );
      notifications = 0;

      now = const Duration(milliseconds: 450);
      final projected = controller.projectedSnapshot;

      expect(controller.value.position, const Duration(seconds: 2));
      expect(projected.position, const Duration(milliseconds: 2450));
      expect(projected.duration, const Duration(seconds: 10));
      expect(controller.isAdvancing, isTrue);
      expect(positions, isEmpty);
      expect(notifications, 0);
      expect(tickerFactory.activeCount, 1);
      expect(tickerFactory.created, hasLength(1));
    });

    test(
      'projected position clamps to duration and keeps unknown explicit',
      () {
        positions.add(const Duration(milliseconds: 9500));
        controller.synchronize(
          revision: 1,
          state: PlaybackBackendState.playing,
          duration: const Duration(seconds: 10),
        );
        now = const Duration(seconds: 2);

        expect(
          controller.projectedSnapshot.position,
          const Duration(seconds: 10),
        );

        controller.synchronize(
          revision: 2,
          state: PlaybackBackendState.opening,
          duration: Duration.zero,
        );
        expect(controller.projectedSnapshot.duration, isNull);
        expect(controller.projectedSnapshot.progress, isNull);
      },
    );

    test(
      'metadata-only duration update preserves the interpolation anchor',
      () {
        positions.add(const Duration(seconds: 2));
        controller.synchronize(
          revision: 1,
          state: PlaybackBackendState.playing,
          duration: const Duration(seconds: 10),
        );
        now = const Duration(milliseconds: 500);

        controller.synchronize(
          revision: 1,
          state: PlaybackBackendState.playing,
          duration: const Duration(seconds: 20),
        );
        now = const Duration(seconds: 1);

        expect(
          controller.projectedSnapshot.position,
          const Duration(seconds: 3),
        );
        expect(
          controller.projectedSnapshot.duration,
          const Duration(seconds: 20),
        );
        expect(positions, isEmpty);
      },
    );

    test('paused stalled and completed sample once then freeze', () {
      positions.addAll([
        const Duration(seconds: 2),
        const Duration(seconds: 3),
        const Duration(seconds: 4),
        const Duration(seconds: 5),
      ]);
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );

      for (final state in [
        PlaybackBackendState.paused,
        PlaybackBackendState.stalled,
        PlaybackBackendState.completed,
      ]) {
        now += const Duration(milliseconds: 500);
        controller.synchronize(
          revision: 1,
          state: state,
          duration: const Duration(seconds: 10),
        );
        final frozenPosition = controller.value.position;
        now += const Duration(milliseconds: 500);
        expect(controller.projectedSnapshot.position, frozenPosition);
        expect(controller.isAdvancing, isFalse);
        expect(tickerFactory.activeCount, 0);
      }

      expect(controller.value.position, const Duration(seconds: 5));
      tickerFactory.tickAll(includeCancelled: true);
      expect(controller.value.position, const Duration(seconds: 5));
    });

    test('failed and stopped preserve the last valid sample', () {
      positions.add(const Duration(seconds: 4));
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );

      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.failed,
        duration: const Duration(seconds: 10),
      );
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.stopped,
        duration: const Duration(seconds: 10),
      );

      expect(controller.value.position, const Duration(seconds: 4));
      now = const Duration(seconds: 2);
      expect(controller.projectedSnapshot.position, const Duration(seconds: 4));
      expect(controller.isAdvancing, isFalse);
      expect(tickerFactory.activeCount, 0);
    });

    test('new revision resets and rejects a cancelled stale callback', () {
      positions.addAll([
        const Duration(seconds: 8),
        const Duration(seconds: 9),
      ]);
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );
      final staleTicker = tickerFactory.created.single;

      controller.synchronize(
        revision: 2,
        state: PlaybackBackendState.opening,
        duration: const Duration(seconds: 20),
      );
      staleTicker.tick(ignoreCancelled: true);

      expect(controller.value.position, Duration.zero);
      now = const Duration(seconds: 3);
      expect(controller.projectedSnapshot.position, Duration.zero);
      expect(controller.isAdvancing, isFalse);
      expect(controller.value.duration, const Duration(seconds: 20));
      expect(positions, [const Duration(seconds: 9)]);
      expect(tickerFactory.activeCount, 0);
    });

    test('duration updates clamp position without another native read', () {
      positions.add(const Duration(seconds: 8));
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );

      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 5),
      );

      expect(controller.value.position, const Duration(seconds: 5));
      expect(controller.value.duration, const Duration(seconds: 5));
      expect(positions, isEmpty);
      expect(tickerFactory.activeCount, 1);
    });

    test('inactive and dispose clear or cancel every active ticker', () {
      positions.add(const Duration(seconds: 2));
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );
      final staleTicker = tickerFactory.created.single;

      controller.synchronize(revision: 2, state: null, duration: Duration.zero);
      expect(controller.value, const RemotePlaybackTimelineSnapshot.unknown());
      expect(
        controller.projectedSnapshot,
        const RemotePlaybackTimelineSnapshot.unknown(),
      );
      expect(controller.isAdvancing, isFalse);
      expect(tickerFactory.activeCount, 0);

      controller.dispose();
      now = const Duration(seconds: 4);
      expect(controller.projectedSnapshot.position, isNull);
      expect(controller.isAdvancing, isFalse);
      staleTicker.tick(ignoreCancelled: true);
      expect(tickerFactory.activeCount, 0);
    });

    test('dispose freezes a known sample without another read', () {
      positions.add(const Duration(seconds: 2));
      controller.synchronize(
        revision: 1,
        state: PlaybackBackendState.playing,
        duration: const Duration(seconds: 10),
      );

      controller.dispose();
      now = const Duration(seconds: 4);

      expect(controller.projectedSnapshot.position, const Duration(seconds: 2));
      expect(controller.isAdvancing, isFalse);
      expect(positions, isEmpty);
    });
  });
}

final class _FakeTickerFactory {
  final created = <_FakeTicker>[];

  int get activeCount => created.where((ticker) => ticker.active).length;

  RemotePlaybackTimelineTicker create(
    Duration interval,
    void Function() callback,
  ) {
    final ticker = _FakeTicker(interval, callback);
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
  _FakeTicker(this.interval, this._callback);

  final Duration interval;
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
