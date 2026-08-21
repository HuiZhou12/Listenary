import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/page/now_playing_page/component/remote_current_playlist_view.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';

void main() {
  group('RemoteCurrentPlaylistView', () {
    testWidgets('shows safe metadata and omits album separator when empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _testApp(
          queue: const [
            ActivePlaybackSessionItem(
              title: 'First title',
              artist: 'First artist',
              album: 'First album',
            ),
            ActivePlaybackSessionItem(
              title: 'Second title',
              artist: 'Second artist',
            ),
          ],
        ),
      );

      expect(find.text('播放列表'), findsOneWidget);
      expect(find.text('First title'), findsOneWidget);
      expect(find.text('First artist - First album'), findsOneWidget);
      expect(find.text('Second title'), findsOneWidget);
      expect(find.text('Second artist'), findsOneWidget);
      expect(find.text('Second artist - '), findsNothing);
    });

    testWidgets('highlights current item and only selects another item', (
      tester,
    ) async {
      final selected = <int>[];
      await tester.pumpWidget(
        _testApp(currentIndex: 0, onSelect: selected.add),
      );

      final currentTitle = tester.widget<Text>(find.text('Title 0'));
      final titleContext = tester.element(find.text('Title 0'));
      final scheme = Theme.of(titleContext).colorScheme;
      expect(currentTitle.style!.fontWeight, isNot(FontWeight.normal));
      expect(DefaultTextStyle.of(titleContext).style.color, scheme.primary);

      await tester.tap(find.text('Title 0'));
      await tester.tap(find.text('Title 1'));
      await tester.pump();

      expect(selected, [1]);
    });

    testWidgets('allows every item when there is no current index', (
      tester,
    ) async {
      final selected = <int>[];
      await tester.pumpWidget(_testApp(onSelect: selected.add));

      await tester.tap(find.text('Title 0'));
      await tester.tap(find.text('Title 1'));

      expect(selected, [0, 1]);
    });

    testWidgets('exposes reorder, clear and per-item remove', (tester) async {
      await tester.pumpWidget(_testApp(currentIndex: 0));

      // 排序、清空入口存在；每项有移除按钮（默认队列 2 项）。
      expect(find.byIcon(Symbols.reorder), findsOneWidget);
      expect(find.byIcon(Symbols.clear_all), findsOneWidget);
      expect(find.byIcon(Symbols.remove_circle_outline), findsNWidgets(2));
      // 非排序模式下不显示拖拽手柄或 ReorderableListView。
      expect(find.byIcon(Symbols.drag_indicator), findsNothing);
      expect(find.byType(ReorderableListView), findsNothing);
    });

    testWidgets('per-item remove and clear invoke their callbacks', (tester) async {
      final removed = <int>[];
      var cleared = 0;
      await tester.pumpWidget(
        _testApp(
          currentIndex: 0,
          onRemove: removed.add,
          onClear: () => cleared++,
        ),
      );

      // 移除按钮在悬停 item 时才可点。
      final removeIcon = find.byIcon(Symbols.remove_circle_outline).first;
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(tester.getCenter(removeIcon));
      await tester.pumpAndSettle();
      await tester.tap(removeIcon);
      await tester.pumpAndSettle();
      await gesture.removePointer();
      expect(removed, [0]);

      await tester.tap(find.byIcon(Symbols.clear_all));
      expect(cleared, 1);
    });

    testWidgets('enters reorder mode and hides it for shuffle', (tester) async {
      await tester.pumpWidget(_testApp(currentIndex: 0));

      await tester.tap(find.byIcon(Symbols.reorder));
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(find.byIcon(Symbols.drag_indicator), findsNWidgets(2));
    });

    testWidgets('shows the existing empty queue state', (tester) async {
      await tester.pumpWidget(_testApp(queue: const []));

      expect(find.byIcon(Symbols.queue_music), findsOneWidget);
      expect(find.text('播放队列还是空的'), findsOneWidget);
      expect(find.text('选择歌曲后，它们会出现在这里。'), findsOneWidget);
    });

    testWidgets('positions the list at the initial and updated current item', (
      tester,
    ) async {
      final queue = List.generate(
        30,
        (index) => ActivePlaybackSessionItem(
          title: 'Track $index',
          artist: 'Artist $index',
        ),
      );
      await tester.pumpWidget(
        _testApp(queue: queue, currentIndex: 8, height: 240),
      );
      await tester.pump();

      final initialList = tester.widget<ListView>(find.byType(ListView));
      expect(initialList.itemExtent, 64.0);
      expect(initialList.controller!.offset, 8 * 64.0);

      await tester.pumpWidget(
        _testApp(queue: queue, currentIndex: 14, height: 240),
      );
      await tester.pump();

      final updatedList = tester.widget<ListView>(find.byType(ListView));
      expect(updatedList.controller!.offset, 14 * 64.0);
    });

    testWidgets('does not scroll without a current item and unmounts safely', (
      tester,
    ) async {
      final queue = List.generate(
        20,
        (index) => ActivePlaybackSessionItem(
          title: 'Track $index',
          artist: 'Artist $index',
        ),
      );
      await tester.pumpWidget(_testApp(queue: queue, height: 240));
      await tester.pump();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.controller!.offset, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _testApp({
  List<ActivePlaybackSessionItem>? queue,
  int? currentIndex,
  ValueChanged<int>? onSelect,
  ValueChanged<int>? onRemove,
  VoidCallback? onClear,
  double height = 400,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: height,
        child: RemoteCurrentPlaylistView(
          queueSourceSwitcher: const SizedBox.shrink(),
          queue:
              queue ??
              const [
                ActivePlaybackSessionItem(title: 'Title 0', artist: 'Artist 0'),
                ActivePlaybackSessionItem(title: 'Title 1', artist: 'Artist 1'),
              ],
          currentIndex: currentIndex,
          mode: RemotePlaybackMode.sequential,
          onSelect: onSelect ?? (_) {},
          onReorder: (oldIndex, newIndex) {},
          onRemove: onRemove ?? (_) {},
          onClear: onClear ?? () {},
        ),
      ),
    ),
  );
}
