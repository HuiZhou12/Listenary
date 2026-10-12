import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/remote_media_card.dart';

/// 横向货架的三态必须是**三种不同的表现**：
/// 加载 = 占位块；失败 = 错误文案 + 重试；空 = 中性说明（不给重试）。
/// 把失败渲染成"空"是这一块最容易犯的错 —— 用户会把网络抖动读成"平台没有内容"。
void main() {
  Future<void> pumpShelf(
    WidgetTester tester, {
    required int itemCount,
    bool loading = false,
    String? errorMessage,
    String? emptyMessage,
    VoidCallback? onRetry,
    double itemHeight = 200,
  }) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HorizontalShelf(
            loading: loading,
            errorMessage: errorMessage,
            onRetry: onRetry,
            emptyMessage: emptyMessage,
            itemCount: itemCount,
            itemWidth: 140,
            itemHeight: itemHeight,
            itemBuilder: (context, index) => SizedBox(
              width: 140,
              child: Text('item-$index'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('加载中渲染占位块，不渲染空文案', (tester) async {
    await pumpShelf(
      tester,
      itemCount: 0,
      loading: true,
      emptyMessage: '这里暂时没有内容。',
    );

    expect(find.bySemanticsLabel('正在加载'), findsWidgets);
    expect(find.text('这里暂时没有内容。'), findsNothing);
  });

  testWidgets('失败渲染错误文案与重试，且不渲染空文案', (tester) async {
    var retried = 0;
    await pumpShelf(
      tester,
      itemCount: 0,
      errorMessage: '网易云 平台歌单读取失败',
      emptyMessage: '该平台没有返回歌单。',
      onRetry: () => retried++,
    );

    expect(find.text('网易云 平台歌单读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 关键：失败时**不允许**同时说"没有内容"。
    expect(find.text('该平台没有返回歌单。'), findsNothing);

    await tester.tap(find.text('重试'));
    expect(retried, 1);
  });

  testWidgets('失败优先于空：两者都给时显示失败', (tester) async {
    await pumpShelf(
      tester,
      itemCount: 0,
      errorMessage: '读取失败',
      emptyMessage: '没有内容',
    );

    expect(find.text('读取失败'), findsOneWidget);
    expect(find.text('没有内容'), findsNothing);
  });

  testWidgets('空结果渲染中性说明，且没有重试按钮', (tester) async {
    await pumpShelf(
      tester,
      itemCount: 0,
      emptyMessage: '该平台没有返回歌单。',
      onRetry: () {},
    );

    expect(find.text('该平台没有返回歌单。'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('有条目时按数量渲染，并采用调用方给的高度', (tester) async {
    await pumpShelf(tester, itemCount: 3, itemHeight: 180);

    expect(find.text('item-0'), findsOneWidget);
    expect(find.text('item-2'), findsOneWidget);
    expect(
      tester.getSize(find.byType(HorizontalShelf)).height,
      180,
      reason: '货架高度必须等于调用方声明的高度，否则卡片会被裁掉',
    );
  });

  testWidgets('货架高度与卡片声明一致时，卡片不会被裁剪', (tester) async {
    const width = 140.0;
    final height = RemoteMediaCard.extentFor(width: width, hasFooter: true);

    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HorizontalShelf(
            itemCount: 1,
            itemWidth: width,
            itemHeight: height,
            itemBuilder: (context, index) => RemoteMediaCard(
              width: width,
              title: '一个很长的平台歌单标题用来挤压布局',
              coverUri: null,
              details: '创建者名字也很长 · 1261 首',
              sourceLabel: '网易云',
              footer: TextButton(onPressed: () {}, child: const Text('订阅')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      height,
      reason: '卡片实际高度必须等于它自己声明的高度',
    );
  });

  // ---- V2-6（2026-10-12）：货架左右箭头 --------------------------------------
  // 规则：**只在"那一侧确实还能滚"时才渲染该箭头** —— 禁用态若仍渲染，
  // 就会遮住第一张/最后一张卡片的点击（所以"到边界"必须是"不出现"，而不是"灰掉"）。

  double shelfOffset(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

  testWidgets('V2-6：内容溢出时出现「下一个」，起始位置没有「上一个」', (tester) async {
    // 12 张 × 140 + 11 × 12 间距 = 1812 > 900 视口 ⇒ 可滚。
    await pumpShelf(tester, itemCount: 12);

    expect(find.byTooltip('下一个'), findsOneWidget);
    expect(find.byTooltip('上一个'), findsNothing);
    expect(shelfOffset(tester), 0);
  });

  testWidgets('V2-6：点「下一个」往右翻，之后「上一个」出现（可翻回去）', (tester) async {
    await pumpShelf(tester, itemCount: 12);
    final before = shelfOffset(tester);

    await tester.tap(find.byTooltip('下一个'));
    await tester.pumpAndSettle();

    expect(shelfOffset(tester), greaterThan(before));
    expect(find.byTooltip('上一个'), findsOneWidget);

    await tester.tap(find.byTooltip('上一个'));
    await tester.pumpAndSettle();
    expect(shelfOffset(tester), lessThan(before + 1));
  });

  testWidgets('V2-6：滚到末尾后「下一个」消失（不遮挡最后一张卡）', (tester) async {
    await pumpShelf(tester, itemCount: 12);

    for (var i = 0; i < 8; i++) {
      final next = find.byTooltip('下一个');
      if (next.evaluate().isEmpty) break;
      await tester.tap(next);
      await tester.pumpAndSettle();
    }

    expect(find.byTooltip('下一个'), findsNothing, reason: '到底就不该再有可点的箭头');
    expect(find.byTooltip('上一个'), findsOneWidget);
  });

  testWidgets('V2-6：内容放得下时不出现任何箭头', (tester) async {
    // 2 张 × 140 + 12 = 292 < 900 ⇒ 不可滚。
    await pumpShelf(tester, itemCount: 2);

    expect(find.byTooltip('下一个'), findsNothing);
    expect(find.byTooltip('上一个'), findsNothing);
  });
}
