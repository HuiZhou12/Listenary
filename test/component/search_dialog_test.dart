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

  testWidgets('defaults to local source with three categories', (tester) async {
    await _pumpDialog(tester);

    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    // 来源切换：两个来源都可见（D1）。
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    // 在线分支的提交按钮只在在线来源出现。
    expect(find.byTooltip('在线搜索'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration?.hintText,
      // 本地来源的提示文案保持不变：它描述的是**本地分支**的范围。
      '搜索本地曲库（歌曲、艺术家、专辑）',
    );
  });

  testWidgets('launcher opens local search without any online provider', (
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
    // 没有可搜索平台 ⇒「在线」仍可见（视觉置灰），但点击**不切换来源**（I3）。
    expect(find.text('在线'), findsOneWidget);
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

/// 打开弹窗（本地来源，无在线平台 provider）。
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
