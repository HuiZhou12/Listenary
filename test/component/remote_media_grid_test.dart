import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/remote_media_grid.dart';

/// 自适应卡片网格：**"列数 → 卡宽 → 卡高"这条链不能有第二个人再算一次**。
/// 网格的 `mainAxisExtent` 若与卡片实际高度不一致，就会裁切或溢出 ——
/// 这里用"渲染高度 == 声明高度"把它钉住。
void main() {
  test('★ 网格几何同源：榜单页与平台歌单页的卡宽由同一个函数决定', () {
    // 2026-10-17（用户指出封面尺寸不一致）：此前榜单页用本组件（上限 168），
    // 平台歌单页自己写 `SliverGridDelegateWithMaxCrossAxisExtent(260)` ✗ ⇒
    // 同一个 `RemoteMediaCard` 在两页差 ~80px。现在两边都走 `mediaGridGeometry`。
    const width = 1496.0; // 约等于 1568 宽窗口减去页壳与右侧留白
    final geometry = mediaGridGeometry(availableWidth: width);

    // `maxCardWidth` 是**偏好上限**：列数向下取整后，均分出来的卡宽最多到
    // `上限 + 间距` 以内（例：1496 宽 → 8 列 → 176.5）✓ —— 关键是**不会再出现
    // 旧那套 260 上限导致的 240+ 大卡** ✓。
    expect(geometry.cardWidth, lessThan(168 + 12));
    expect(geometry.columns, greaterThanOrEqualTo(2));
    // 列数与卡宽必须**恰好铺满**可用宽度（否则页面上会莫名多出一条缝）。
    expect(
      geometry.cardWidth * geometry.columns + 12 * (geometry.columns - 1),
      closeTo(width, 0.01),
    );

    // 更宽的窗口 ⇒ 只会更多列，卡宽不会跟着无限变大（上限仍在起作用）。
    final wider = mediaGridGeometry(availableWidth: width + 600);
    expect(wider.columns, greaterThan(geometry.columns));
    expect(wider.cardWidth, lessThan(168 + 12));
  });

  Future<void> pumpGrid(
    WidgetTester tester, {
    required int itemCount,
    Size surface = const Size(900, 800),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RemoteMediaGrid(
              itemCount: itemCount,
              itemBuilder: (context, index, cardWidth) => RemoteMediaCard(
                width: cardWidth,
                title: '条目 $index 一个很长的标题用来挤压网格布局',
                coverUri: null,
                details: '创建者名字也很长 · 1261 首',
                sourceLabel: '网易云',
                placeholderIcon: Symbols.leaderboard,
                footer: TextButton(onPressed: () {}, child: const Text('订阅')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按数量渲染，且每张卡的实际高度都等于它声明的高度', (tester) async {
    await pumpGrid(tester, itemCount: 5);

    expect(find.byType(RemoteMediaCard), findsNWidgets(5));
    expect(tester.takeException(), isNull);

    final finder = find.byType(RemoteMediaCard);
    final cards = tester.widgetList<RemoteMediaCard>(finder).toList();
    for (var index = 0; index < cards.length; index++) {
      final card = cards[index];
      expect(
        tester.getSize(finder.at(index)).height,
        RemoteMediaCard.extentFor(width: card.width, hasFooter: true),
        reason: '第 $index 张卡的高度必须等于它自己声明的高度（否则网格会裁切/溢出）',
      );
    }
    // 同一网格里所有单元格等宽（否则高度链就断了）。
    expect(cards.map((card) => card.width).toSet(), hasLength(1));
  });

  testWidgets('窄窗口仍然至少 2 列、且不溢出', (tester) async {
    await pumpGrid(
      tester,
      itemCount: 4,
      surface: const Size(300, 800),
    );

    expect(tester.takeException(), isNull);
    final cards = tester
        .widgetList<RemoteMediaCard>(find.byType(RemoteMediaCard))
        .toList(growable: false);
    // 前两张在同一行（2 列），因此 y 相同。
    expect(
      tester.getTopLeft(find.byType(RemoteMediaCard).at(0)).dy,
      tester.getTopLeft(find.byType(RemoteMediaCard).at(1)).dy,
    );
    expect(cards, hasLength(4));
  });

  testWidgets('零条目时不渲染任何卡片', (tester) async {
    await pumpGrid(tester, itemCount: 0);

    expect(find.byType(RemoteMediaCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
