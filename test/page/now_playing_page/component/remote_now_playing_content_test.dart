import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/now_playing_page/component/remote_now_playing_content.dart';
import 'package:pure_music/play_service/active_playback_session.dart';

void main() {
  testWidgets('shows remote item and neutral presentation without timeline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(snapshot: _snapshot(), queue: const Text('remote queue')),
    );

    expect(find.text('Remote title'), findsOneWidget);
    expect(find.text('Remote artist'), findsOneWidget);
    expect(find.text('Local album'), findsNothing);
    expect(find.text('remote queue'), findsOneWidget);
    expect(find.byKey(const Key('remote-now-playing-placeholder')), findsOne);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('0:00'), findsNothing);
  });

  testWidgets('updates title and artist when the active item changes', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(snapshot: _snapshot()));

    await tester.pumpWidget(
      _testApp(
        snapshot: _snapshot(
          revision: 2,
          title: 'Next title',
          artist: 'Next artist',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remote title'), findsNothing);
    expect(find.text('Remote artist'), findsNothing);
    expect(find.text('Next title'), findsOneWidget);
    expect(find.text('Next artist'), findsOneWidget);
  });

  testWidgets('routes enabled remote controls and respects queue boundaries', (
    tester,
  ) async {
    var previousCount = 0;
    var pauseCount = 0;
    var nextCount = 0;
    await tester.pumpWidget(
      _testApp(
        snapshot: _snapshot(canPrevious: false),
        onPrevious: () => previousCount++,
        onPause: () => pauseCount++,
        onNext: () => nextCount++,
      ),
    );

    final previous = tester.widget<IconButton>(
      find.byKey(const Key('remote-now-playing-previous')),
    );
    expect(previous.onPressed, isNull);
    await tester.tap(find.byKey(const Key('remote-now-playing-toggle')));
    await tester.tap(find.byKey(const Key('remote-now-playing-next')));

    expect(previousCount, 0);
    expect(pauseCount, 1);
    expect(nextCount, 1);
  });

  testWidgets('compact layout keeps the remote queue visible', (tester) async {
    await tester.pumpWidget(
      _testApp(
        snapshot: _snapshot(),
        width: 480,
        height: 760,
        queue: const Text('compact remote queue'),
      ),
    );

    expect(find.text('Remote title'), findsOneWidget);
    expect(find.text('compact remote queue'), findsOneWidget);
  });
}

Widget _testApp({
  required ActivePlaybackSessionSnapshot snapshot,
  double width = 1000,
  double height = 700,
  Widget queue = const SizedBox.shrink(),
  VoidCallback? onPrevious,
  VoidCallback? onPlay,
  VoidCallback? onPause,
  VoidCallback? onNext,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: RemoteNowPlayingContent(
            snapshot: snapshot,
            queue: queue,
            immersive: false,
            onPrevious: onPrevious ?? () {},
            onPlay: onPlay ?? () {},
            onPause: onPause ?? () {},
            onNext: onNext ?? () {},
          ),
        ),
      ),
    ),
  );
}

ActivePlaybackSessionSnapshot _snapshot({
  int revision = 1,
  String title = 'Remote title',
  String artist = 'Remote artist',
  bool canPrevious = true,
}) {
  return ActivePlaybackSessionSnapshot.active(
    revision: revision,
    source: ActivePlaybackSessionSource.remote,
    queue: [
      ActivePlaybackSessionItem(
        title: title,
        artist: artist,
        album: 'Local album',
      ),
      const ActivePlaybackSessionItem(
        title: 'Queue title',
        artist: 'Queue artist',
      ),
    ],
    currentIndex: 0,
    state: ActivePlaybackSessionState.playing,
    controlInFlight: false,
    capabilities: ActivePlaybackSessionCapabilities(
      canPlay: false,
      canPause: true,
      canPrevious: canPrevious,
      canNext: true,
      canSeek: false,
    ),
  );
}
