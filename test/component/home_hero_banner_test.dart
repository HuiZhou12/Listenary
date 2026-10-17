import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/home_hero_banner.dart';

/// **主页横幅背景**（2026-10-17 ✓）。
///
/// 它**只负责背景**（不认任何业务区块 ✓），铺满调用方给的"名片带"。
/// 守四件事：
/// 1. 没填横幅 ⇒ **什么都不画**（页面底色露出来 ✓，不留空盒子 ✗）；
/// 2. 填了但文件不存在 ⇒ **不崩**、不抛错 ✓；
/// 3. 两层遮罩的**停靠点**是设计契约（左侧 25% 必须完全透明 —— 问候语要纯净 ✓）；
/// 4. 图片只占**右侧一段**（左侧留给问候语 ✓，不做全宽压暗 ✗）。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    String? bannerPath,
    Size size = const Size(600, 200),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.fromSize(
              size: size,
              child: HomeHeroBanner(bannerPath: bannerPath),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没填横幅 ⇒ 什么都不画（连图片都不建）', (tester) async {
    await pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsNothing);
    // 它仍占着父级给的盒子（父级是紧约束），但**什么都不画** ⇒ 页面底色露出来 ✓。
    expect(find.byType(HomeHeroBanner), findsOneWidget);
  });

  testWidgets('★ 填了但文件不存在 ⇒ 不崩（读不出来就当没有）', (tester) async {
    await pump(tester, bannerPath: r'C:\definitely\not\here\banner.png');

    expect(tester.takeException(), isNull);
  });

  test('遮罩是设计契约：左侧 25% 完全透明，底部 35% 收口', () {
    // 斜向：0~25% 全透明 ⇒ 问候语区域 100% 纯净 ✓（图片不参与遮挡 ✓）。
    expect(HomeHeroBanner.diagonalMask.stops, [0.0, 0.25, 0.9]);
    expect(HomeHeroBanner.diagonalMask.colors.first, Colors.transparent);
    expect(HomeHeroBanner.diagonalMask.colors[1], Colors.transparent);
    expect(HomeHeroBanner.diagonalMask.colors.last, Colors.black);

    // 底部收口：底部 35% 淡出 ⇒ 与下方区块无缝衔接 ✓。
    expect(HomeHeroBanner.bottomMask.stops, [0.0, 0.35]);
    expect(HomeHeroBanner.bottomMask.colors.first, Colors.transparent);
    expect(HomeHeroBanner.bottomMask.colors.last, Colors.black);
  });

  testWidgets('图片只占右侧一段（左侧留给问候语）', (tester) async {
    await pump(tester, bannerPath: r'C:\definitely\not\here\banner.png');

    final fraction = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(
      fraction.widthFactor,
      0.72,
      reason: '图片占名片带宽度的 72%，左边那条留给文字 ✓',
    );
    // 图片整体贴**右**：外层 Align 的对齐方式必须是 centerRight ✓。
    final align = tester.widget<Align>(
      find.ancestor(
        of: find.byType(FractionallySizedBox),
        matching: find.byType(Align),
      ).first,
    );
    expect(align.alignment, Alignment.centerRight);
  });
}
