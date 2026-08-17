import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/page/now_playing_page/component/active_lyric_region.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

void main() {
  testWidgets('remote lyric region hides the local lyric child', (tester) async {
    final session = ActivePlaybackSession();
    session.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: const [
        ActivePlaybackSessionItem(title: 'Remote', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(
          home: ActiveNowPlayingLyricRegion(
            localChild: Text('local lyric must stay hidden'),
          ),
        ),
      ),
    );

    expect(find.text('暂无歌词'), findsOneWidget);
    expect(find.text('local lyric must stay hidden'), findsNothing);
  });

  test('local-only actions reject remote and inactive sessions', () {
    expect(
      shouldShowLocalNowPlayingActions(
        ActivePlaybackSessionSnapshot.inactive(revision: 1),
      ),
      isFalse,
    );
    expect(
      shouldShowLocalNowPlayingActions(
        _snapshot(ActivePlaybackSessionSource.remote),
      ),
      isFalse,
    );
    expect(
      shouldShowLocalNowPlayingActions(
        _snapshot(ActivePlaybackSessionSource.local),
      ),
      isTrue,
    );
  });
}

ActivePlaybackSessionSnapshot _snapshot(ActivePlaybackSessionSource source) =>
    ActivePlaybackSessionSnapshot.active(
      revision: 1,
      source: source,
      queue: const [
        ActivePlaybackSessionItem(title: 'Track', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );
