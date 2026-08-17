import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/native/rust/api/smtc_flutter.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/active_session_smtc_publisher.dart';
import 'package:pure_music/play_service/local_smtc_input.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

void main() {
  test('remote snapshot publishes safe metadata and mapped state', () async {
    final backend = _FakeSmtcBackend();
    final publisher = ActiveSessionSmtcPublisher(
      SmtcBridge.withBackend(backend),
    );

    await publisher.publish(
      _snapshot(
        source: ActivePlaybackSessionSource.remote,
        state: ActivePlaybackSessionState.playing,
      ),
      localInput: const LocalSmtcInput(
        title: 'Local title',
        artist: 'Local artist',
        album: 'Local album',
        durationMs: 180000,
        path: r'C:\Music\local.mp3',
        state: SMTCState.paused,
        positionMs: 12000,
      ),
    );

    expect(backend.displays, [
      const _Display(title: 'Remote title', artist: 'Remote artist'),
    ]);
    expect(backend.states, [SMTCState.playing]);
    expect(backend.timelines, isEmpty);
  });

  test(
    'local snapshot uses local display mode without remote fields',
    () async {
      final backend = _FakeSmtcBackend();
      final publisher = ActiveSessionSmtcPublisher(
        SmtcBridge.withBackend(backend),
      );

      await publisher.publish(
        _snapshot(
          source: ActivePlaybackSessionSource.local,
          state: ActivePlaybackSessionState.paused,
        ),
      );

      expect(backend.displays, [
        const _Display(
          title: 'Local title',
          artist: 'Local artist',
          album: 'Album',
        ),
      ]);
      expect(backend.states, [SMTCState.paused]);
    },
  );

  test('local input publishes duration, path, state and timeline', () async {
    final backend = _FakeSmtcBackend();
    final publisher = ActiveSessionSmtcPublisher(
      SmtcBridge.withBackend(backend),
    );

    await publisher.publish(
      _snapshot(
        source: ActivePlaybackSessionSource.local,
        state: ActivePlaybackSessionState.playing,
      ),
      localInput: const LocalSmtcInput(
        title: 'Input title',
        artist: 'Input artist',
        album: 'Input album',
        durationMs: 180000,
        path: r'C:\Music\input.mp3',
        state: SMTCState.playing,
        positionMs: 12000,
      ),
    );

    expect(backend.displays, [
      const _Display(
        title: 'Input title',
        artist: 'Input artist',
        album: 'Input album',
        duration: 180000,
        path: r'C:\Music\input.mp3',
      ),
    ]);
    expect(backend.states, [SMTCState.playing]);
    expect(backend.timelines, [12000]);
  });

  test(
    'local position updates timeline without republishing metadata',
    () async {
      final backend = _FakeSmtcBackend();
      final publisher = ActiveSessionSmtcPublisher(
        SmtcBridge.withBackend(backend),
      );
      final snapshot = _snapshot(
        source: ActivePlaybackSessionSource.local,
        state: ActivePlaybackSessionState.playing,
      );

      final metadataPublish = publisher.publish(
        snapshot,
        localInput: const LocalSmtcInput(
          title: 'Input title',
          artist: 'Input artist',
          album: 'Input album',
          durationMs: 180000,
          path: r'C:\Music\input.mp3',
          state: SMTCState.playing,
          positionMs: 12000,
        ),
      );
      final positionPublish = publisher.publishLocalPosition(snapshot, 24000);
      await Future.wait([metadataPublish, positionPublish]);

      expect(backend.displays, hasLength(1));
      expect(backend.states, [SMTCState.playing]);
      expect(backend.timelines, [12000, 24000]);
    },
  );

  test('remote position update is ignored', () async {
    final backend = _FakeSmtcBackend();
    final publisher = ActiveSessionSmtcPublisher(
      SmtcBridge.withBackend(backend),
    );
    final snapshot = _snapshot(
      source: ActivePlaybackSessionSource.remote,
      state: ActivePlaybackSessionState.playing,
    );

    await publisher.publish(snapshot);
    await publisher.publishLocalPosition(snapshot, 24000);

    expect(backend.timelines, isEmpty);
  });

  test('inactive snapshot clears the active display', () async {
    final backend = _FakeSmtcBackend();
    final publisher = ActiveSessionSmtcPublisher(
      SmtcBridge.withBackend(backend),
    );

    await publisher.publish(
      _snapshot(source: ActivePlaybackSessionSource.remote),
    );
    await publisher.publish(
      ActivePlaybackSessionSnapshot.inactive(revision: 2),
    );

    expect(backend.clears, 1);
  });

  test('a newer snapshot suppresses stale state publication', () async {
    final backend = _FakeSmtcBackend()..blockDisplay = true;
    final publisher = ActiveSessionSmtcPublisher(
      SmtcBridge.withBackend(backend),
    );

    final first = publisher.publish(
      _snapshot(
        source: ActivePlaybackSessionSource.remote,
        state: ActivePlaybackSessionState.playing,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final second = publisher.publish(
      _snapshot(
        source: ActivePlaybackSessionSource.remote,
        state: ActivePlaybackSessionState.paused,
      ),
    );
    backend.releaseDisplay();
    await Future.wait([first, second]);

    expect(backend.states, [SMTCState.paused]);
  });

  test('dispose is idempotent and clears the display', () async {
    final backend = _FakeSmtcBackend();
    final publisher = ActiveSessionSmtcPublisher(
      SmtcBridge.withBackend(backend),
    );
    await publisher.publish(
      _snapshot(source: ActivePlaybackSessionSource.remote),
    );

    await publisher.dispose();
    await publisher.dispose();
    await publisher.publish(
      _snapshot(source: ActivePlaybackSessionSource.remote),
    );

    expect(backend.clears, 1);
    expect(backend.displays, hasLength(1));
  });
}

ActivePlaybackSessionSnapshot _snapshot({
  required ActivePlaybackSessionSource source,
  ActivePlaybackSessionState state = ActivePlaybackSessionState.paused,
}) => ActivePlaybackSessionSnapshot.active(
  revision: 1,
  source: source,
  queue: [
    ActivePlaybackSessionItem(
      title: source == ActivePlaybackSessionSource.remote
          ? 'Remote title'
          : 'Local title',
      artist: source == ActivePlaybackSessionSource.remote
          ? 'Remote artist'
          : 'Local artist',
      album: source == ActivePlaybackSessionSource.local ? 'Album' : 'Hidden',
      coverUri: source == ActivePlaybackSessionSource.remote
          ? Uri.parse('https://cover.invalid/remote')
          : null,
      duration: source == ActivePlaybackSessionSource.remote
          ? const Duration(minutes: 3)
          : Duration.zero,
    ),
  ],
  currentIndex: 0,
  state: state,
  controlInFlight: false,
  capabilities: ActivePlaybackSessionCapabilities.none,
);

final class _FakeSmtcBackend implements SmtcBackend {
  final displays = <_Display>[];
  final states = <SMTCState>[];
  final timelines = <int>[];
  int clears = 0;
  bool blockDisplay = false;
  Future<void>? _displayGate;
  void Function()? _releaseDisplay;

  @override
  Stream<SMTCControlEvent> get controlEvents => const Stream.empty();

  @override
  Stream<int> get positionChangeEvents => const Stream.empty();

  @override
  Future<void> updateDisplay({
    required String title,
    required String artist,
    required String album,
    required int duration,
    required String path,
  }) async {
    if (blockDisplay) {
      final gate = Completer<void>();
      _displayGate = gate.future;
      _releaseDisplay = gate.complete;
      await _displayGate;
      blockDisplay = false;
    }
    displays.add(
      _Display(
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        path: path,
      ),
    );
  }

  @override
  Future<void> updateState(SMTCState state) async {
    states.add(state);
  }

  @override
  Future<void> updateTimeProperties(int progress) async {
    timelines.add(progress);
  }

  @override
  Future<void> refreshDisplay() async {}

  @override
  Future<void> clearDisplay() async {
    clears++;
  }

  @override
  Future<void> close() async {}

  void releaseDisplay() => _releaseDisplay?.call();
}

final class _Display {
  const _Display({
    required this.title,
    required this.artist,
    this.album = '',
    this.duration = 0,
    this.path = '',
  });

  final String title;
  final String artist;
  final String album;
  final int duration;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is _Display &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      duration == other.duration &&
      path == other.path;

  @override
  int get hashCode => Object.hash(title, artist, album, duration, path);
}
