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
    // 2026-11-03 删除「在线音乐」（Spec D2）后下标整体前移一位 ⇒
    // 「收藏与回顾」组从下标 **7**（歌单）开始（此前是 8）：
    // 下标 7 之前有三个组头（聚合 / 本地曲库 / 收藏与回顾）⇒ 7*54 + 3*28 = 462。
    // 这是**组边界真的移动了**，不是把断言放宽。
    expect(sideNavDestinationTop(7, expandedT: 1), 462);
    // 下标 8（统计）仍在本组内，组头数量不变 ⇒ 与前值一致。
    expect(sideNavDestinationTop(8, expandedT: 1), 516);
    expect(sideNavDestinationOffset(0.5, expandedT: 1), 55);
  });

  testWidgets('expanded sidebar shows four group headings without tooltips', (
    tester,
  ) async {
    await _pumpSideNav(tester, expanded: true);

    // 第一组叫「聚合」（主页 + 探索 + 我的收藏），组名与条目名不再同名。
    // 2026-11-03：删除「在线音乐」目的地（Spec D2）⇒ 聚合组 3 项。
    expect(find.text('聚合'), findsOneWidget);
    for (final label in [
      '主页',
      '探索',
      '我的收藏',
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

    // 「我的收藏」是删掉「在线音乐」后聚合组的第 3 项（仍是聚合入口）。
    expect(find.text('我的收藏'), findsOneWidget);
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
      '我的收藏',
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
    // 侧栏是壳的一部分：这里用探索页当宿主（`/online` 已撤销，Spec D2）。
    initialLocation: app_paths.EXPLORE_PAGE,
    routes: [
      GoRoute(
        path: app_paths.EXPLORE_PAGE,
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
