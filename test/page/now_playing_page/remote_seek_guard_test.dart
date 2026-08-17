import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';

void main() {
  test('remote activation cancels an active seek drag only', () {
    expect(
      shouldCancelNowPlayingSeekDrag(canSeekFromUi: false, isDragging: true),
      isTrue,
    );
    expect(
      shouldCancelNowPlayingSeekDrag(canSeekFromUi: false, isDragging: false),
      isFalse,
    );
    expect(
      shouldCancelNowPlayingSeekDrag(canSeekFromUi: true, isDragging: true),
      isFalse,
    );
  });

  test('remote activation publishes disabled seek state', () async {
    final binding = RemotePlaybackControlBinding();
    final source = StreamController<RemotePlaybackControlState>.broadcast();
    final enabledStates = <bool>[];
    final subscription = binding.stateStream.listen(
      (_) => enabledStates.add(binding.canSeekFromUi),
    );

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

    expect(enabledStates, [false, false, true]);

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
