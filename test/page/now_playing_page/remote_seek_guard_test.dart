import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';

void main() {
  test('seek drag is cancelled only when seeking is unavailable', () {
    expect(
      shouldCancelNowPlayingSeekDrag(canSeekFromUi: false, isDragging: true),
      isTrue,
    );
    expect(
      shouldCancelNowPlayingSeekDrag(canSeekFromUi: false, isDragging: false),
      isFalse,
    );
    // 远程播放中进度条可跳 ⇒ 状态推送不应打断拖拽。
    expect(
      shouldCancelNowPlayingSeekDrag(canSeekFromUi: true, isDragging: true),
      isFalse,
    );
  });

  test('progress gate opens for remote while the local lyric gate stays shut', () async {
    final binding = RemotePlaybackControlBinding();
    final source = StreamController<RemotePlaybackControlState>.broadcast();
    final progressStates = <bool>[];
    final lyricStates = <bool>[];
    final remoteLyricStates = <bool>[];
    final subscription = binding.stateStream.listen((_) {
      progressStates.add(binding.canSeekProgressFromUi);
      lyricStates.add(binding.canSeekFromUi);
      remoteLyricStates.add(binding.canSeekLyricLineFromUi);
    });

    binding.bind(
      initialState: const _State(PlaybackBackendState.playing),
      stateStream: source.stream,
      isActive: () => true,
      pause: () => true,
      resume: () => true,
    );
    source.add(const _State(PlaybackBackendState.paused));
    await pumpEventQueue();
    binding.clear();
    await pumpEventQueue();

    // 远程播放/暂停时进度条可跳；清除远程后恢复本地可跳。
    expect(progressStates, [true, true, true]);
    // 本地歌词行的门禁（`canSeekFromUi`）：远程期间始终关闭，清除远程后恢复。
    // 在线歌词行走的是**另一个**门禁，所以这里必须保持不变。
    expect(lyricStates, [false, false, true]);
    // 在线歌词行的门禁：远程期间放开（远程歌词点击已解锁），清除远程后关闭。
    // 「本地也 true」是因为 remoteProgressSeekAllowed 在非远程刻意返回 true，
    // 该 getter 显式叠加了 isActive 才是远程专用门禁。
    expect(remoteLyricStates, [true, true, false]);

    await subscription.cancel();
    await binding.dispose();
    await source.close();
  });

  test('remote lyric gate follows seekability of the remote state', () async {
    final binding = RemotePlaybackControlBinding();
    final source = StreamController<RemotePlaybackControlState>.broadcast();
    binding.bind(
      initialState: const _State(PlaybackBackendState.opening),
      stateStream: source.stream,
      isActive: () => true,
      pause: () => true,
      resume: () => true,
    );

    // opening / failed / controlInFlight：流还不能跳，歌词行也不可点。
    expect(binding.canSeekLyricLineFromUi, isFalse);
    for (final state in const [
      PlaybackBackendState.failed,
      PlaybackBackendState.stopped,
    ]) {
      source.add(_State(state));
      await pumpEventQueue();
      expect(binding.canSeekLyricLineFromUi, isFalse);
    }
    source.add(
      const _State(PlaybackBackendState.playing, controlInFlight: true),
    );
    await pumpEventQueue();
    expect(binding.canSeekLyricLineFromUi, isFalse);

    // 可跳状态：歌词行放开。
    for (final state in const [
      PlaybackBackendState.playing,
      PlaybackBackendState.paused,
      PlaybackBackendState.stalled,
      PlaybackBackendState.completed,
    ]) {
      source.add(_State(state));
      await pumpEventQueue();
      expect(binding.canSeekLyricLineFromUi, isTrue);
      // 本地门禁不受影响：远程期间恒 false。
      expect(binding.canSeekFromUi, isFalse);
    }

    // 无远程会话：歌词行门禁关闭（本地走旧的 canSeekFromUi 路径）。
    binding.clear();
    await pumpEventQueue();
    expect(binding.canSeekLyricLineFromUi, isFalse);
    expect(binding.canSeekFromUi, isTrue);

    await binding.dispose();
    await source.close();
  });
}

final class _State implements RemotePlaybackControlState {
  const _State(this.state, {this.controlInFlight = false});

  @override
  final PlaybackBackendState state;

  @override
  final bool controlInFlight;

  @override
  bool get isActive => true;
}
