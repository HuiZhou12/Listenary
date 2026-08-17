import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/rectangle_progress_indicator.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';

void main() {
  testWidgets('remote progress reads projection without creating local player', (
    tester,
  ) async {
    var now = Duration.zero;
    var nativePosition = const Duration(seconds: 2);
    final timeline = RemotePlaybackTimelineController(
      readPosition: () => nativePosition,
      tickerFactory: (_, _) => const _NoopTicker(),
      clock: () => now,
    );
    addTearDown(timeline.dispose);
    timeline.synchronize(
      revision: 1,
      state: PlaybackBackendState.playing,
      duration: const Duration(seconds: 10),
    );

    await tester.pumpWidget(_testApp(timeline: timeline, advancing: true));

    expect(PlayService.instance.existingPlaybackService, isNull);
    expect(_progressValue(tester), 0.2);

    now = const Duration(milliseconds: 500);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_progressValue(tester), closeTo(0.25, 0.0001));

    nativePosition = const Duration(seconds: 3);
    timeline.synchronize(
      revision: 1,
      state: PlaybackBackendState.paused,
      duration: const Duration(seconds: 10),
    );
    await tester.pumpWidget(_testApp(timeline: timeline, advancing: false));
    expect(_progressValue(tester), 0.3);

    now = const Duration(seconds: 4);
    await tester.pump(const Duration(seconds: 1));
    expect(_progressValue(tester), 0.3);
    expect(PlayService.instance.existingPlaybackService, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unknown remote duration paints zero progress', (tester) async {
    final timeline = RemotePlaybackTimelineController(
      readPosition: () => const Duration(seconds: 2),
      tickerFactory: (_, _) => const _NoopTicker(),
      clock: () => Duration.zero,
    );
    addTearDown(timeline.dispose);
    timeline.synchronize(
      revision: 1,
      state: PlaybackBackendState.playing,
      duration: Duration.zero,
    );

    await tester.pumpWidget(_testApp(timeline: timeline, advancing: true));

    expect(_progressValue(tester), 0);
    expect(PlayService.instance.existingPlaybackService, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Widget _testApp({
  required RemotePlaybackTimelineController timeline,
  required bool advancing,
}) => MaterialApp(
  home: Center(
    child: RectangleProgressIndicator(
      key: const ValueKey('remote-progress'),
      size: const Size(100, 20),
      remoteTimeline: timeline,
      remoteTimelineAdvancing: advancing,
      child: const SizedBox(width: 100, height: 20),
    ),
  ),
);

double _progressValue(WidgetTester tester) {
  final paintFinder = find.descendant(
    of: find.byKey(const ValueKey('remote-progress')),
    matching: find.byType(CustomPaint),
  );
  final paint = tester.widget<CustomPaint>(paintFinder);
  final painter = paint.painter! as RectangleProgressPainter;
  return painter.progress.value;
}

final class _NoopTicker implements RemotePlaybackTimelineTicker {
  const _NoopTicker();

  @override
  void cancel() {}
}
