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
    expect(binding.canSeekProgressFromUi, isTrue);
    // 在线歌词行门禁是远程专用：无远程会话时关闭，本地走 canSeekFromUi。
    expect(binding.canSeekLyricLineFromUi, isFalse);
  });

  test(
    'remote seek routes to the remote backend while the local lyric gate stays shut',
    () async {
      final seekCalls = <Duration>[];
      binding.bind(
        initialState: const _State(PlaybackBackendState.opening),
        stateStream: source.stream,
        isActive: () => binding.state.isActive,
        pause: () => true,
        resume: () => true,
        seek: (position) async {
          seekCalls.add(position);
          return true;
        },
      );

      // opening：进度条与本地歌词门禁都不可跳。
      expect(binding.canSeekProgressFromUi, isFalse);
      expect(binding.canSeekFromUi, isFalse);
      expect(binding.canSeekLyricLineFromUi, isFalse);

      for (final state in const [
        PlaybackBackendState.playing,
        PlaybackBackendState.paused,
        PlaybackBackendState.stalled,
        PlaybackBackendState.completed,
      ]) {
        source.add(_State(state));
        await pumpEventQueue();
        // 进度条放开；本地歌词门的禁保持关闭（与在线歌词门禁是两回事）。
        expect(binding.canSeekProgressFromUi, isTrue);
        expect(binding.canSeekFromUi, isFalse);
        // 同步的本地歌词路径仍拒绝，且不触发远程 handler。
        expect(binding.seekFromUi(() => fail('local seek must not run')), isFalse);
        expect(await binding.seekRemoteProgress(12.5), isTrue);
      }

      expect(seekCalls, [
        const Duration(milliseconds: 12500),
        const Duration(milliseconds: 12500),
        const Duration(milliseconds: 12500),
        const Duration(milliseconds: 12500),
      ]);
    },
  );

  test('failed state keeps the progress gate closed', () async {
    binding.bind(
      initialState: const _State(PlaybackBackendState.failed),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
      seek: (_) async => false,
    );

    expect(binding.canSeekProgressFromUi, isFalse);
    expect(binding.canSeekFromUi, isFalse);
    expect(binding.canSeekLyricLineFromUi, isFalse);
    expect(await binding.seekRemoteProgress(1), isFalse);
  });

  test('control-in-flight keeps the progress gate closed', () {
    binding.bind(
      initialState: const _State(
        PlaybackBackendState.playing,
        controlInFlight: true,
      ),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
      seek: (_) async => true,
    );

    expect(binding.canSeekProgressFromUi, isFalse);
  });

  test('remote seek failure surfaces false and never throws', () async {
    binding.bind(
      initialState: const _State(PlaybackBackendState.playing),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
      seek: (_) async => throw StateError('backend rejected seek'),
    );

    expect(await binding.seekRemoteProgress(3), isFalse);
  });

  test('remote lyric-line seek opens only for seekable remote states', () async {
    final seekCalls = <Duration>[];
    binding.bind(
      initialState: const _State(PlaybackBackendState.opening),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
      seek: (position) async {
        seekCalls.add(position);
        return true;
      },
    );

    // opening：流还不能跳，歌词行也不可点（且不得触碰 handler）。
    expect(binding.canSeekLyricLineFromUi, isFalse);
    expect(await binding.seekLyricLine(1.0), isFalse);
    expect(seekCalls, isEmpty);

    // 可跳状态：歌词行放开，跳转落到远程 handler。
    for (final state in const [
      PlaybackBackendState.playing,
      PlaybackBackendState.paused,
      PlaybackBackendState.stalled,
      PlaybackBackendState.completed,
    ]) {
      source.add(_State(state));
      await pumpEventQueue();
      expect(binding.canSeekLyricLineFromUi, isTrue);
      // 本地门禁仍关闭（两者不共用一个开关）。
      expect(binding.canSeekFromUi, isFalse);
      expect(await binding.seekLyricLine(42.0), isTrue);
    }
    expect(seekCalls, List.filled(4, const Duration(seconds: 42)));

    // failed / controlInFlight：门禁关闭且拒绝跳转。
    source.add(const _State(PlaybackBackendState.failed));
    await pumpEventQueue();
    expect(binding.canSeekLyricLineFromUi, isFalse);
    expect(await binding.seekLyricLine(7.0), isFalse);
    source.add(
      const _State(PlaybackBackendState.playing, controlInFlight: true),
    );
    await pumpEventQueue();
    expect(binding.canSeekLyricLineFromUi, isFalse);
    expect(await binding.seekLyricLine(7.0), isFalse);
    expect(seekCalls, List.filled(4, const Duration(seconds: 42)));
  });

  test('lyric-line seek never degrades to the local player', () async {
    final seekCalls = <Duration>[];
    binding.bind(
      initialState: const _State.inactive(),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
      seek: (position) async {
        seekCalls.add(position);
        return true;
      },
    );

    // 无远程会话：门禁关闭 ⇒ 拒绝，不落到任何 handler。
    expect(binding.canSeekLyricLineFromUi, isFalse);
    expect(await binding.seekLyricLine(9.5), isFalse);
    expect(seekCalls, isEmpty);
    // 本地门禁此时是开的（本地链路照旧）。
    expect(binding.canSeekFromUi, isTrue);
  });

  test('lyric-line seek without a bound handler degrades to false', () async {
    binding.bind(
      initialState: const _State(PlaybackBackendState.playing),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
    );

    expect(binding.canSeekLyricLineFromUi, isTrue);
    expect(await binding.seekLyricLine(3), isFalse);
  });

  test('lyric-line seek failure surfaces false and never throws', () async {
    binding.bind(
      initialState: const _State(PlaybackBackendState.playing),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
      seek: (_) async => throw StateError('backend rejected lyric seek'),
    );

    expect(await binding.seekLyricLine(5), isFalse);
  });

  test('remote seek without a bound handler degrades to false', () async {
    binding.bind(
      initialState: const _State(PlaybackBackendState.playing),
      stateStream: source.stream,
      isActive: () => binding.state.isActive,
      pause: () => true,
      resume: () => true,
    );

    expect(binding.canSeekProgressFromUi, isTrue);
    expect(await binding.seekRemoteProgress(3), isFalse);
  });

  test('clearing active state restores local UI seek', () {
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
    expect(binding.canSeekProgressFromUi, isTrue);
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
