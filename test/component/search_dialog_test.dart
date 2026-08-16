import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/search_dialog.dart';

void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  testWidgets('shows only the three local search categories', (tester) async {
    await _pumpDialog(tester);

    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('在线'), findsNothing);
    expect(find.byTooltip('在线搜索'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration?.hintText,
      '搜索歌曲、艺术家、专辑',
    );
  });

  testWidgets('launcher opens local search without a ChKSz provider', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => IconButton(
              onPressed: () => showApplicationSearch(context),
              icon: const Icon(Icons.search),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.byType(SearchDialog), findsOneWidget);
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('在线'), findsNothing);
  });

  testWidgets('local category switching and clear action remain available', (
    tester,
  ) async {
    await _pumpDialog(tester);

    await tester.tap(find.text('艺术家'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    await tester.enterText(field, 'local query');
    await tester.pump();
    expect(find.byTooltip('清除'), findsOneWidget);

    await tester.tap(find.byTooltip('清除'));
    await tester.pump();

    expect(tester.widget<TextField>(field).controller?.text, isEmpty);
    expect(find.text('输入关键词开始搜索'), findsOneWidget);
  });
}

Future<void> _pumpDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: SearchDialog())),
  );
  await tester.pump();
}

final class _FakeHotKeyManager extends HotKeyManagerPlatform {
  @override
  Stream<Map<Object?, Object?>> get onKeyEventReceiver => const Stream.empty();

  @override
  Future<void> register(HotKey hotKey) async {}

  @override
  Future<void> unregister(HotKey hotKey) async {}

  @override
  Future<void> unregisterAll() async {}
}
