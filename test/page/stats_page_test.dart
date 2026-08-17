import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/stats_page/page.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late OnlineHistoryController controller;

  setUp(() async {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    repository.recordPlaybackStarted(
      _track('1'),
      lastQuality: 'lossless',
      playedAt: DateTime.utc(2026, 8, 18, 10),
    );
    repository.incrementPlayCount(_ref('1'));
    repository.incrementPlayCount(_ref('1'));
    repository.recordPlaybackStarted(
      _track('2'),
      lastQuality: 'standard',
      playedAt: DateTime.utc(2026, 8, 18, 11),
    );
    repository.incrementPlayCount(_ref('2'));
    controller = OnlineHistoryController(repository: Future.value(repository));
    await controller.refresh();
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  testWidgets('shows online recent and top played history in statistics', (
    tester,
  ) async {
    await _pumpStats(tester, controller);

    expect(find.text('本地'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('累计播放'), findsOneWidget);
    expect(find.text('听过的曲目'), findsOneWidget);
    expect(find.text('Track 1'), findsOneWidget);
    expect(find.text('Track 2'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Track 2')).dy,
      lessThan(tester.getTopLeft(find.text('Track 1')).dy),
    );

    await tester.tap(find.text('最常播放'));
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('Track 1')).dy,
      lessThan(tester.getTopLeft(find.text('Track 2')).dy),
    );
    expect(find.text('2 次'), findsOneWidget);
  });

  testWidgets('loads online history safely on the first visit', (tester) async {
    controller.dispose();
    controller = OnlineHistoryController(repository: Future.value(repository));

    await _pumpStats(tester, controller);
    await tester.pumpAndSettle();

    expect(controller.snapshot.status, OnlineHistoryLoadStatus.ready);
    expect(find.text('Track 1'), findsOneWidget);
    expect(find.text('Track 2'), findsOneWidget);
  });

  testWidgets('clears all online history only after confirmation', (
    tester,
  ) async {
    await _pumpStats(tester, controller);

    await tester.tap(find.byTooltip('清空在线播放历史'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除任何在线歌单'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('confirm-clear-online-history')),
    );
    await tester.pumpAndSettle();

    expect(controller.snapshot.hasData, isFalse);
    expect(find.text('暂无在线播放历史'), findsOneWidget);
    expect(repository.recentHistory(), isEmpty);
  });
}

Future<void> _pumpStats(
  WidgetTester tester,
  OnlineHistoryController controller,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider<OnlineHistoryController>.value(
      value: controller,
      child: const MaterialApp(
        home: Scaffold(body: StatsPage(initialSource: StatsSource.online)),
      ),
    ),
  );
  await tester.pump();
}

PlatformTrackRef _ref(String id) =>
    PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

MusicTrack _track(String id) => MusicTrack(
  ref: _ref(id),
  title: 'Track $id',
  artists: ['Artist $id'],
  album: 'Album $id',
  duration: const Duration(minutes: 3),
  availability: TrackAvailability.playable,
);
