import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/online_source_label.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 远端内容卡片：来源标记与曲目行用**同一种形态**（行尾小圆点 + 低对比小字），
/// 且卡片的实际高度必须精确等于它对外声明的高度 —— 货架照抄这个高度，
/// 两者一旦不一致就会溢出。定高盒子让"各行之和 == 声明高度"是构造出来的。
void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    double width = 140,
    String title = '标题',
    String details = '创建者 · 12 首',
    String? sourceLabel = '网易云',
    Widget? footer,
    List<RemoteMediaCardAction> actions = const [],
    VoidCallback? onTap,
    Size surface = const Size(600, 600),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: RemoteMediaCard(
              width: width,
              title: title,
              coverUri: null,
              details: details,
              sourceLabel: sourceLabel,
              footer: footer,
              actions: actions,
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('extentFor 是卡片高度的唯一来源（数值即契约）', () {
    // ⚠️ 2026-10-16 更新两次 ✓：①元信息行由一行改成两行（用户裁定 ✓）；
    // ②两行在中文默认行高下装不下（30 ✗）⇒ 文字钉了 `height: 1.2` ✓ 且该格加到 **32** ✓。
    // 140 封面 + 6 间距 + 18 标题 + 2 间距 + **32 元信息行（两行）**
    expect(RemoteMediaCard.extentFor(width: 140), 198);
    // 再加页脚：4 + 36
    expect(RemoteMediaCard.extentFor(width: 140, hasFooter: true), 238);
    // 没有元信息行时只留封面 + 标题
    expect(RemoteMediaCard.extentFor(width: 140, hasMeta: false), 164);
  });

  test('★ 两行文字必须真的装得进它们的定高盒子（防"被盖住"）', () {
    // 为什么要有这条：卡片内部是**定高盒子** ✓（`各行高度之和 == 声明高度` 的构造 ✓），
    // 但中文字体的默认行高（≈1.4 ✗）比拉丁字体大 ⇒ 盒子按"一行"算就会**裁掉**文字 ✓
    //（用户实测报过"字一多就被盖住" ✗）。
    // ⇒ 这里用**真实的 TextPainter** 量一次：文字实际高度不得大于盒子高度 ✓。
    double measure({
      required String text,
      required double fontSize,
      required double? height,
      required double maxWidth,
      int maxLines = 1,
    }) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: fontSize, height: height),
        ),
        textDirection: TextDirection.ltr,
        maxLines: maxLines,
      )..layout(maxWidth: maxWidth);
      return painter.height;
    }

    // 标题：14px × 1.2 = 16.8 ✓ 必须 ≤ 18（一次性中文长标题也要成立 ✓）。
    expect(
      measure(
        text: '2026年超火超爆超热门30首',
        fontSize: AppType.body,
        height: 1.2,
        maxWidth: 160,
      ),
      lessThanOrEqualTo(18),
    );
    // 元信息：两行 12px × 1.2 = 28.8 ✓ 必须 ≤ 32 ✓（放长一点的"歌单 · 作者 · 平台" ✓）。
    expect(
      measure(
        text: '歌单 · 云音乐私人雷达 · 网易云',
        fontSize: AppType.caption,
        height: 1.2,
        maxWidth: 160,
        maxLines: 2,
      ),
      lessThanOrEqualTo(32),
    );
  });

  group('widthFor：三档宽度与 ResponsiveBuilder 同一套阈值', () {
    test('≤640 → 124（small）', () {
      expect(RemoteMediaCard.widthFor(const Size(420, 900)), 124);
      expect(RemoteMediaCard.widthFor(const Size(640, 900)), 124);
    });

    test('640 与 1100 之间 → 140（medium）', () {
      expect(RemoteMediaCard.widthFor(const Size(641, 900)), 140);
      expect(RemoteMediaCard.widthFor(const Size(1099, 900)), 140);
    });

    test('≥1100 → 156（large）', () {
      expect(RemoteMediaCard.widthFor(const Size(1100, 900)), 156);
      expect(RemoteMediaCard.widthFor(const Size(1920, 1080)), 156);
    });

    test('只取决于宽度（高度不参与）', () {
      expect(
        RemoteMediaCard.widthFor(const Size(1200, 400)),
        RemoteMediaCard.widthFor(const Size(1200, 3000)),
      );
    });
  });

  testWidgets('渲染高度 == 声明高度，且详情/来源都显示', (tester) async {
    await pumpCard(tester);

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      RemoteMediaCard.extentFor(width: 140),
    );
    expect(find.text('标题'), findsOneWidget);
    expect(find.text('创建者 · 12 首'), findsOneWidget);
    // 来源用既有的轻量形态（小圆点 + 小字），不是徽章。
    expect(find.byType(OnlineSourceLabel), findsOneWidget);
    expect(find.text('网易云'), findsOneWidget);
  });

  testWidgets('没有来源时不渲染来源标记（单平台场景保持既有观感）', (tester) async {
    await pumpCard(tester, sourceLabel: null);

    expect(find.byType(OnlineSourceLabel), findsNothing);
    // 详情还在 ⇒ 元信息行仍然占高度。
    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      RemoteMediaCard.extentFor(width: 140),
    );
  });

  testWidgets('详情与来源都没有时不占元信息行的高度', (tester) async {
    await pumpCard(tester, details: '', sourceLabel: null);

    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      RemoteMediaCard.extentFor(width: 140, hasMeta: false),
    );
    expect(find.byType(OnlineSourceLabel), findsNothing);
  });

  testWidgets('只有来源没有详情时，来源标记仍在', (tester) async {
    await pumpCard(tester, details: '');

    expect(find.byType(OnlineSourceLabel), findsOneWidget);
    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      RemoteMediaCard.extentFor(width: 140),
    );
  });

  testWidgets('页脚计入高度', (tester) async {
    await pumpCard(
      tester,
      footer: TextButton(onPressed: () {}, child: const Text('订阅')),
    );

    expect(find.text('订阅'), findsOneWidget);
    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      RemoteMediaCard.extentFor(width: 140, hasFooter: true),
    );
  });

  testWidgets('悬停才显示操作，且覆盖层不影响静态布局', (tester) async {
    await pumpCard(
      tester,
      actions: [
        RemoteMediaCardAction(
          icon: Symbols.favorite,
          tooltip: '收藏',
          onPressed: () {},
        ),
      ],
    );

    AnimatedOpacity opacityOf() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));

    expect(opacityOf().opacity, 0, reason: '未悬停时操作不可见');
    final heightBefore = tester.getSize(find.byType(RemoteMediaCard)).height;

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(RemoteMediaCard)));
    await tester.pumpAndSettle();

    expect(opacityOf().opacity, 1, reason: '悬停后操作可见');
    expect(
      tester.getSize(find.byType(RemoteMediaCard)).height,
      heightBefore,
      reason: '悬停操作是覆盖层，不能让卡片高度变化',
    );
  });

  testWidgets('窄宽度 + 超长文案不溢出', (tester) async {
    await pumpCard(
      tester,
      width: 110,
      title: '一个非常非常长的歌单标题用来挤压布局看看会不会溢出',
      details: '一个同样非常长的创建者名字 · 1261 首',
      footer: TextButton(onPressed: () {}, child: const Text('订阅')),
    );

    expect(tester.takeException(), isNull);
  });
}
