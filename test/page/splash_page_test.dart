// 冷启动品牌页 + SplashGate 启动编排的定向测试。
//
// 钉住 2026-11-03 已拍板的三条可观测行为：
// 1. D4/D5：品牌页渲染出 logo + 「Listenary」+「让每一首歌都有归处」，且三者是
//    **渐进式淡入**（各自的 FadeTransition 在入场结束时都到 1.0，且中间态小于 1.0）。
// 2. D2：后置初始化在**品牌页首帧之后**才启动（不是 runApp 之前），完成后切主壳。
// 3. D2/D5：最短展示窗口 + `alreadyElapsed` 抵扣 —— 初始化瞬间完成时也不会秒切，
//    窗口已过则立即切（**总启动时长不增加**）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/splash_page.dart';

/// 测试用的确定色彩方案：不触发 `ThemeProvider`（它要 FRB 的 SystemTheme）。
const _scheme = ColorScheme.dark(
  primary: Color(0xFF8AB4F8),
  onSurface: Color(0xFFE6E6E6),
  onSurfaceVariant: Color(0xFFB0B0B0),
  surface: Color(0xFF1B1B1F),
  surfaceContainerLow: Color(0xFF141418),
);

Widget _splash() => const SplashPage(colorScheme: _scheme);

/// 读某个元素的 `FadeTransition` 当前透明度（D5 的可见证据）。
///
/// 直接按 key 找：key 挂在 `FadeTransition` 本身。**不能**用 `find.ancestor` ——
/// 外层 `MaterialApp` 的路由转场自己就带若干 `FadeTransition`，会命中一堆无关项。
double _opacityOf(WidgetTester tester, Key key) {
  final fade = find.byKey(key);
  expect(fade, findsOneWidget, reason: '品牌页元素 $key 应当是独立的 FadeTransition');
  return tester.widget<FadeTransition>(fade).opacity.value;
}

void main() {
  group('SplashPage（D4/D5：素材与渐进式淡入）', () {
    testWidgets('渲染 logo、品牌名与理念文本', (tester) async {
      await tester.pumpWidget(_splash());

      expect(find.byKey(SplashPage.logoKey), findsOneWidget);
      expect(find.text('Listenary'), findsOneWidget);
      expect(find.text('让每一首歌都有归处'), findsOneWidget);
    });

    testWidgets('渐进式淡入：起始透明，入场结束后全部显现', (tester) async {
      await tester.pumpWidget(_splash());
      // 首帧：入场刚开始。
      expect(_opacityOf(tester, SplashPage.logoFadeKey), lessThan(0.5));
      expect(_opacityOf(tester, SplashPage.brandFadeKey), lessThan(0.5));
      expect(_opacityOf(tester, SplashPage.taglineFadeKey), lessThan(0.5));
      // logo 先起、文本后浮现 ⇒ 中途 logo 的透明度严格领先 tagline。
      await tester.pump(const Duration(milliseconds: 260));
      expect(
        _opacityOf(tester, SplashPage.logoFadeKey),
        greaterThan(_opacityOf(tester, SplashPage.taglineFadeKey)),
        reason: 'D5 要求「logo 淡入 → 文本延迟浮现」的顺序',
      );
      // 入场结束：三者都到 1.0。
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, SplashPage.logoFadeKey), 1.0);
      expect(_opacityOf(tester, SplashPage.brandFadeKey), 1.0);
      expect(_opacityOf(tester, SplashPage.taglineFadeKey), 1.0);
    });

    testWidgets('logo 有轻微缩放（0.92 → 1.0）', (tester) async {
      await tester.pumpWidget(_splash());
      final scale = find.ancestor(
        of: find.byKey(SplashPage.logoKey),
        matching: find.byType(ScaleTransition),
      );
      expect(scale, findsOneWidget);
      await tester.pumpAndSettle();
      expect(tester.widget<ScaleTransition>(scale).scale.value, 1.0);
    });
  });

  group('SplashGate（D2：并行初始化 / 最短展示 / 不拖慢启动）', () {
    testWidgets('后置初始化在品牌页首帧之后才启动，完成后切换到主壳', (tester) async {
      var warmUpCalls = 0;
      Widget? shell;

      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: Duration.zero,
            colorScheme: _scheme,
            warmUp: () async {
              warmUpCalls++;
              // warmUp 执行时品牌页**已经画出过首帧** ⇒ 它不是在构建期跑起来的。
              expect(find.byType(SplashPage), findsOneWidget);
              shell = const Scaffold(body: Text('主壳'));
              return shell!;
            },
          ),
        ),
      );

      // 品牌页首帧已渲染，主壳尚未接管。
      expect(find.byType(SplashPage), findsOneWidget);
      expect(find.text('主壳'), findsNothing);

      await tester.pump();
      await tester.pumpAndSettle();

      // 后置初始化确实跑过（跑一次即止），且主壳已接管。
      expect(warmUpCalls, 1);
      expect(shell, isNotNull);
      expect(find.text('主壳'), findsOneWidget);
      expect(find.byType(SplashPage), findsNothing);
    });

    testWidgets('初始化瞬间完成也要等满最短展示窗口', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: const Duration(milliseconds: 650),
            colorScheme: _scheme,
            warmUp: () async => const Scaffold(body: Text('主壳')),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('主壳'), findsNothing, reason: '最短窗口未到，仍应显示品牌页');
      expect(find.byType(SplashPage), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('主壳'), findsOneWidget);
    });

    testWidgets('alreadyElapsed 抵扣最短窗口：启动已花掉的时间不再重复等待', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: const Duration(milliseconds: 650),
            // main() 到 runApp 已花掉 620ms ⇒ 只剩 30ms 要等。
            alreadyElapsed: const Duration(milliseconds: 620),
            colorScheme: _scheme,
            warmUp: () async => const Scaffold(body: Text('主壳')),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();

      expect(
        find.text('主壳'),
        findsOneWidget,
        reason: 'D2：品牌动画吃的是已经花掉的启动预算，不得再额外等待整段窗口',
      );
    });

    testWidgets('alreadyElapsed 超过最短窗口时立即切换', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: const Duration(milliseconds: 650),
            alreadyElapsed: const Duration(seconds: 2),
            colorScheme: _scheme,
            warmUp: () async => const Scaffold(body: Text('主壳')),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('主壳'), findsOneWidget);
    });

    testWidgets('作为 runApp 根（外层无 MaterialApp）也能正常渲染与切换', (tester) async {
      // 生产路径就是这样：`main.dart` 里 runApp 的直接子树就是 SplashGate，
      // 上面没有 MaterialApp ⇒ 没有 MediaQuery / Directionality。
      await tester.pumpWidget(
        SplashGate(
          minimumVisible: Duration.zero,
          colorScheme: _scheme,
          warmUp: () async => const MaterialApp(
            home: Scaffold(body: Text('主壳')),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(SplashPage), findsOneWidget);

      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('主壳'), findsOneWidget);
    });

    testWidgets('warmUp 抛错时保持品牌页且不崩溃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: Duration.zero,
            colorScheme: _scheme,
            warmUp: () async => throw StateError('boom'),
          ),
        ),
      );

      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(SplashPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
