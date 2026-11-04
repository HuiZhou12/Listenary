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

  test('progress gate opens for remote while the lyric gate stays shut', () async {
    final binding = RemotePlaybackControlBinding();
    final source = StreamController<RemotePlaybackControlState>.broadcast();
    final progressStates = <bool>[];
    final lyricStates = <bool>[];
    final subscription = binding.stateStream.listen((_) {
      progressStates.add(binding.canSeekProgressFromUi);
      lyricStates.add(binding.canSeekFromUi);
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
    // 歌词行点击：远程期间始终关闭，清除远程后恢复。
    expect(lyricStates, [false, false, true]);

    await subscription.cancel();
    await binding.dispose();
    await source.close();
  });
}

final class _State implements RemotePlaybackControlState {
  const _State(this.state);

  @override
  final PlaybackBackendState state;

  @override
  bool get controlInFlight => false;

  @override
  bool get isActive => true;
}
