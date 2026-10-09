import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/remote_media_grid.dart';

/// 自适应卡片网格：**"列数 → 卡宽 → 卡高"这条链不能有第二个人再算一次**。
/// 网格的 `mainAxisExtent` 若与卡片实际高度不一致，就会裁切或溢出 ——
/// 这里用"渲染高度 == 声明高度"把它钉住。
void main() {
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
