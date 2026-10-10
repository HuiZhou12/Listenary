import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';

void main() {
  test('group geometry is removed when collapsed', () {
    expect(sideNavGroupHeaderExtent(0), 0);
    expect(
      sideNavContentHeight(expandedT: 0),
      destinations.length * sideNavItemHeight,
    );
    for (var index = 0; index < destinations.length; index++) {
      expect(
        sideNavDestinationTop(index, expandedT: 0),
        index * sideNavItemHeight,
      );
    }
  });

  test('expanded geometry includes each preceding group header', () {
    expect(sideNavGroupHeaderExtent(1), sideNavGroupHeaderHeight);
    expect(
      sideNavContentHeight(expandedT: 1),
      destinations.length * sideNavItemHeight +
          destinationGroups.length * sideNavGroupHeaderHeight,
    );
    expect(sideNavDestinationTop(0, expandedT: 1), 28);
    expect(sideNavDestinationTop(1, expandedT: 1), 82);
    expect(sideNavDestinationTop(5, expandedT: 1), 326);
    // 新增「探索」（下标 1）后，本地曲库组整体后移一位：下标 7（文件夹）之前
    // 只剩两个组头（聚合、本地曲库），收藏与回顾组现在从下标 8 开始。
    // 这是**组边界真的移动了**，不是把断言放宽。
    expect(sideNavDestinationTop(7, expandedT: 1), 434);
    expect(sideNavDestinationTop(8, expandedT: 1), 516);
    expect(sideNavDestinationOffset(0.5, expandedT: 1), 55);
  });

  testWidgets('expanded sidebar shows four group headings without tooltips', (
    tester,
  ) async {
    await _pumpSideNav(tester, expanded: true);

    // 第一组现在叫「聚合」（主页 + 探索 + 在线音乐 + 我的收藏），组名与条目名不再同名。
    expect(find.text('聚合'), findsOneWidget);
    for (final label in [
      '主页',
      '探索',
      '在线音乐',
      '本地曲库',
      '收藏与回顾',
      '系统',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('collapsed sidebar removes headings and exposes tooltips', (
    tester,
  ) async {
    await _pumpSideNav(tester, expanded: false);

    expect(find.text('在线音乐'), findsOneWidget);
    for (final label in ['本地曲库', '收藏与回顾', '系统']) {
      expect(find.text(label), findsNothing);
    }
    for (final destination in destinations) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == destination.label,
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('drawer uses expanded grouped layout', (tester) async {
    await _pumpSideNav(tester, expanded: false, hasDrawer: true);

    expect(find.text('聚合'), findsOneWidget);
    for (final label in [
      '主页',
      '探索',
      '在线音乐',
      '本地曲库',
      '收藏与回顾',
      '系统',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(Tooltip), findsNothing);
  });
}

Future<void> _pumpSideNav(
  WidgetTester tester, {
  required bool expanded,
  bool hasDrawer = false,
}) async {
  final previousExpanded = AppPreference.instance.sidebarExpanded;
  AppPreference.instance.sidebarExpanded = expanded;
  addTearDown(() {
    AppPreference.instance.sidebarExpanded = previousExpanded;
  });

  final router = GoRouter(
    initialLocation: app_paths.ONLINE_MUSIC_PAGE,
    routes: [
      GoRoute(
        path: app_paths.ONLINE_MUSIC_PAGE,
        builder: (context, state) => Scaffold(
          drawer: hasDrawer ? const Drawer() : null,
          body: const SideNav(),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
}
