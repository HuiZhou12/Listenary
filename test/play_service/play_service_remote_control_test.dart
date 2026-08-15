import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';

void main() {
  late RemotePlaybackControlBinding binding;
  late StreamController<RemotePlaybackControlState> source;

  setUp(() {
    binding = RemotePlaybackControlBinding();
    source = StreamController<RemotePlaybackControlState>.broadcast();
  });

  tearDown(() async {
    await binding.dispose();
    await source.close();
  });

  test('bind exposes the initial state and forwards later states', () async {
    var pauseCount = 0;
    var resumeCount = 0;
    final states = <RemotePlaybackControlState>[];
    final subscription = binding.stateStream.listen(states.add);

    binding.bind(
      initialState: const _State(PlaybackBackendState.paused),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () {
        pauseCount++;
        return true;
      },
      resume: () {
        resumeCount++;
        return true;
      },
    );

    expect(binding.state.state, PlaybackBackendState.paused);
    expect(binding.resume(), isTrue);
    expect(resumeCount, 1);

    source.add(const _State(PlaybackBackendState.playing));
    await pumpEventQueue();
    expect(binding.state.state, PlaybackBackendState.playing);
    expect(binding.pause(), isTrue);
    expect(pauseCount, 1);
    expect(states.map((state) => state.state), [
      PlaybackBackendState.paused,
      PlaybackBackendState.playing,
    ]);

    await subscription.cancel();
  });

  test(
    'active non-actionable states consume without calling handlers',
    () async {
      var pauseCount = 0;
      var resumeCount = 0;
      binding.bind(
        initialState: const _State(PlaybackBackendState.opening),
        stateStream: source.stream,
        isActive: () => binding.state.isActive,
        pause: () {
          pauseCount++;
          return true;
        },
        resume: () {
          resumeCount++;
          return true;
        },
      );

      expect(binding.pause(), isTrue);
      expect(binding.resume(), isTrue);

      for (final state in const [
        PlaybackBackendState.stalled,
        PlaybackBackendState.completed,
        PlaybackBackendState.failed,
      ]) {
        source.add(_State(state));
        await pumpEventQueue();
        expect(binding.pause(), isTrue);
        expect(binding.resume(), isTrue);
      }

      source.add(
        const _State(PlaybackBackendState.playing, controlInFlight: true),
      );
      await pumpEventQueue();
      expect(binding.pause(), isTrue);
      expect(binding.resume(), isTrue);
      expect(pauseCount, 0);
      expect(resumeCount, 0);
    },
  );

  test('inactive state does not consume local fallback operations', () {
    expect(binding.state.isActive, isFalse);
    expect(binding.pause(), isFalse);
    expect(binding.resume(), isFalse);
    expect(binding.canSeekFromUi, isTrue);
  });

  test('active state blocks UI seek without invoking local seek', () async {
    var seekCount = 0;
    binding.bind(
      initialState: const _State(PlaybackBackendState.opening),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
    );

    expect(binding.canSeekFromUi, isFalse);
    expect(binding.seekFromUi(() => seekCount++), isFalse);

    for (final state in const [
      PlaybackBackendState.playing,
      PlaybackBackendState.paused,
      PlaybackBackendState.stalled,
      PlaybackBackendState.completed,
      PlaybackBackendState.failed,
    ]) {
      source.add(_State(state));
      await pumpEventQueue();
      expect(binding.canSeekFromUi, isFalse);
      expect(binding.seekFromUi(() => seekCount++), isFalse);
    }

    expect(seekCount, 0);
  });

  test('clearing active state restores UI seek', () {
    var seekCount = 0;
    binding.bind(
      initialState: const _State(PlaybackBackendState.playing),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
    );

    binding.clear();

    expect(binding.canSeekFromUi, isTrue);
    expect(binding.seekFromUi(() => seekCount++), isTrue);
    expect(seekCount, 1);
  });

  test('clear resets inactive and ignores stale source states', () async {
    binding.bind(
      initialState: const _State(PlaybackBackendState.playing),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
    );

    binding.clear();
    expect(binding.state.isActive, isFalse);
    source.add(const _State(PlaybackBackendState.paused));
    await pumpEventQueue();

    expect(binding.state.isActive, isFalse);
    expect(binding.pause(), isFalse);
    expect(binding.resume(), isFalse);
  });

  test('synchronous active reader prevents stale local fallback', () async {
    var active = true;
    var pauseCount = 0;
    binding.bind(
      initialState: const _State.inactive(),
      stateStream: source.stream,
      isActive: () => active,
      pause: () {
        pauseCount++;
        return true;
      },
      resume: () => true,
    );

    expect(binding.pause(), isTrue);
    expect(pauseCount, 0);

    source.add(const _State(PlaybackBackendState.playing));
    await pumpEventQueue();
    active = false;

    expect(binding.pause(), isFalse);
    expect(pauseCount, 0);
  });
}

final class _State implements RemotePlaybackControlState {
  const _State(this.state, {this.controlInFlight = false});
  const _State.inactive() : state = null, controlInFlight = false;

  @override
  final PlaybackBackendState? state;

  @override
  final bool controlInFlight;

  @override
  bool get isActive => state != null;
}
