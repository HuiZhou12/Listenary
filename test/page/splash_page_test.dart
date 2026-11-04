// 冷启动品牌页 + SplashGate 启动编排的定向测试。
//
// 钉住 2026-11-04 真机验收修正后的四组可观测行为：
// 1. D4/D5：品牌页渲染出 logo + 「Listenary」+「让每一首歌都有归处」，且三者是
//    **渐进式淡入**（各自的 FadeTransition 在入场结束时都到 1.0，且中间态小于 1.0）。
// 2. 可见时长：**从品牌页首帧起算**至少 1500ms（现取 1600ms），`alreadyElapsed`
//    不再抵扣可见窗口；入场 680ms 完整播完才允许淡出，淡出仍为 280ms。
// 3. D2：后置初始化在**品牌页首帧之后**才启动（不是 runApp 之前），
//    切换时刻 = max(首帧 + 可见窗口, warmUp 完成)。
// 4. D6：品牌页背景跟随主题（浅色 / 深色 / 跟随系统），解析失败回退深色不崩。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/page/splash_page.dart';

/// 测试用的确定色彩方案：不触发 `ThemeProvider`（它要 FRB 的 SystemTheme）。
const _scheme = ColorScheme.dark(
  primary: Color(0xFF8AB4F8),
  onSurface: Color(0xFFE6E6E6),
  onSurfaceVariant: Color(0xFFB0B0B0),
  surface: Color(0xFF1B1B1F),
  surfaceContainerLow: Color(0xFF141418),
);

/// D6 用的亮色夹具：`surfaceContainerLow` 是**浅色**值，用来证明品牌页跟着变浅。
const _lightScheme = ColorScheme.light(
  primary: Color(0xFF3F5F90),
  onSurface: Color(0xFF1B1B1F),
  onSurfaceVariant: Color(0xFF44474E),
  surface: Color(0xFFFFFBFF),
  surfaceContainerLow: Color(0xFFF7F2FA),
);

/// D6 用的暗色夹具：与 [_lightScheme] 明显不同，避免「两边一样」的假通过。
const _darkScheme = ColorScheme.dark(
  primary: Color(0xFF8AB4F8),
  onSurface: Color(0xFFE6E6E6),
  onSurfaceVariant: Color(0xFFB0B0B0),
  surface: Color(0xFF1B1B1F),
  surfaceContainerLow: Color(0xFF141418),
);

Widget _splash() => const SplashPage(colorScheme: _scheme);

/// D6 的解析夹具：显式给两个 scheme，避免 widget test 里没有 FRB 的 `ThemeProvider`。
Widget _themedSplash(ThemeMode mode) => SplashPage(
  themeMode: mode,
  lightScheme: _lightScheme,
  darkScheme: _darkScheme,
);

/// 读某个元素的 `FadeTransition` 当前透明度（D5 的可见证据）。
///
/// 直接按 key 找：key 挂在 `FadeTransition` 本身。**不能**用 `find.ancestor` ——
/// 外层 `MaterialApp` 的路由转场自己就带若干 `FadeTransition`，会命中一堆无关项。
double _opacityOf(WidgetTester tester, Key key) {
  final fade = find.byKey(key);
  expect(fade, findsOneWidget, reason: '品牌页元素 $key 应当是独立的 FadeTransition');
  return tester.widget<FadeTransition>(fade).opacity.value;
}

/// 品牌页实际铺的底色（Scaffold 的 backgroundColor）。
Color _splashBackground(WidgetTester tester) {
  final scaffold = find.descendant(
    of: find.byType(SplashPage),
    matching: find.byType(Scaffold),
  );
  expect(scaffold, findsOneWidget);
  return tester.widget<Scaffold>(scaffold).backgroundColor!;
}

/// 品牌页 `MaterialApp` 的 theme（证明底色与 `scaffoldBackgroundColor` 同源）。
ThemeData _splashTheme(WidgetTester tester) {
  final app = find.descendant(
    of: find.byType(SplashPage),
    matching: find.byType(MaterialApp),
  );
  expect(app, findsOneWidget);
  return tester.widget<MaterialApp>(app).theme!;
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

    testWidgets('入场仍为 680ms，且可见窗口不短于入场、不短于 1500ms', (tester) async {
      // 真机验收：「完全没看清」⇒ 可见时长下限从 650ms 提到 ≥1500ms（现取 1600ms）。
      expect(
        splashEntranceDuration,
        MotionDuration.xSlow + MotionDuration.xFast,
        reason: '入场动画时长保持不变（560 + 120 = 680ms）',
      );
      expect(splashEntranceDuration, const Duration(milliseconds: 680));
      expect(
        splashMinimumVisible.inMilliseconds,
        greaterThanOrEqualTo(1500),
        reason: '品牌页可见时长（从首帧起算）必须 ≥1500ms',
      );
      expect(
        splashMinimumVisible,
        greaterThanOrEqualTo(splashEntranceDuration),
        reason: '入场必须能完整播完才允许淡出',
      );
    });

    testWidgets('减少动效：入场直接落终态（静态品牌页），不残留半透明', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

      await tester.pumpWidget(_splash());

      // 首帧即终态：减动效用户看到的是完整静态品牌页（可见窗口照常生效，见下组）。
      expect(_opacityOf(tester, SplashPage.logoFadeKey), 1.0);
      expect(_opacityOf(tester, SplashPage.brandFadeKey), 1.0);
      expect(_opacityOf(tester, SplashPage.taglineFadeKey), 1.0);
    });
  });

  group('SplashGate（D2：并行初始化 / 可见时长 / 不拖慢启动）', () {
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

    testWidgets('初始化瞬间完成也要等满「首帧起算」的可见窗口', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            colorScheme: _scheme,
            warmUp: () async => const Scaffold(body: Text('主壳')),
          ),
        ),
      );

      await tester.pump();
      // 用生产默认窗口（1600ms）钉住真机问题 1：800ms 时还必须在。
      expect(
        splashMinimumVisible,
        greaterThan(const Duration(milliseconds: 800)),
        reason: '旧口径 650ms 会被首帧前的初始化吃光，真机看不见',
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('主壳'), findsNothing, reason: '可见窗口未到，仍应显示品牌页');
      expect(find.byType(SplashPage), findsOneWidget);

      await tester.pump(
        splashMinimumVisible - const Duration(milliseconds: 800),
      );
      await tester.pumpAndSettle();
      expect(find.text('主壳'), findsOneWidget);
    });

    testWidgets('alreadyElapsed 不再抵扣可见窗口：首帧前的耗时吃不掉可见时长', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: const Duration(milliseconds: 800),
            // 旧口径：`minimumVisible - alreadyElapsed` < 0 ⇒ 立即切（真机 bug）。
            // 新口径：可见窗口从首帧起算，这段耗时只进日志。
            alreadyElapsed: const Duration(seconds: 5),
            colorScheme: _scheme,
            warmUp: () async => const Scaffold(body: Text('主壳')),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('主壳'),
        findsNothing,
        reason: '可见窗口只有 800ms，400ms 时不能已经切走',
      );

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('主壳'), findsOneWidget);
    });

    testWidgets('可见窗口已过但 warmUp 更慢时，等 warmUp 完成才切（取较晚者）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: const Duration(milliseconds: 800),
            colorScheme: _scheme,
            warmUp: () async {
              await Future<void>.delayed(const Duration(milliseconds: 1000));
              return const Scaffold(body: Text('主壳'));
            },
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(
        find.text('主壳'),
        findsNothing,
        reason: '截止时刻 = max(首帧 + 800ms, warmUp 完成=1000ms)',
      );

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('主壳'), findsOneWidget);
    });

    testWidgets('淡出时长仍是 MotionDuration.base（280ms）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: Duration.zero,
            colorScheme: _scheme,
            warmUp: () async => const Scaffold(body: Text('主壳')),
          ),
        ),
      );

      final switcher = find.byKey(SplashGate.switcherKey);
      expect(switcher, findsOneWidget);
      expect(
        tester.widget<AnimatedSwitcher>(switcher).duration,
        MotionDuration.base,
        reason: '真机验收要求淡出 280ms 不变',
      );
      // 收尾：让零时长计时器与切换动画跑完，避免留下 pending timer。
      await tester.pump();
      await tester.pumpAndSettle();
    });

    testWidgets('减少动效时淡出为零时长，但可见窗口照常生效', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

      await tester.pumpWidget(
        MaterialApp(
          home: SplashGate(
            minimumVisible: const Duration(milliseconds: 600),
            colorScheme: _scheme,
            warmUp: () async => const Scaffold(body: Text('主壳')),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byType(SplashPage),
        findsOneWidget,
        reason: '减动效用户也至少要看到静态品牌页的完整窗口',
      );

      await tester.pump(const Duration(milliseconds: 300));
      // 无动画 ⇒ 一帧内完成切换，不需要额外过渡时长。
      expect(find.text('主壳'), findsOneWidget);
      expect(find.byType(SplashPage), findsNothing);
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

  group('SplashPage（D6：背景跟随主题）', () {
    testWidgets('浅色模式：品牌页背景 = 浅色 scheme 的 surfaceContainerLow（与主壳同源）', (
      tester,
    ) async {
      await tester.pumpWidget(_themedSplash(ThemeMode.light));

      expect(_splashBackground(tester), _lightScheme.surfaceContainerLow);
      expect(
        _splashTheme(tester).scaffoldBackgroundColor,
        _lightScheme.surfaceContainerLow,
        reason: '与 entry.dart:530-531 同源：scaffoldBackgroundColor 取 surfaceContainerLow',
      );
      expect(_splashTheme(tester).colorScheme.brightness, Brightness.light);
    });

    testWidgets('深色模式：品牌页背景 = 深色 scheme 的 surfaceContainerLow', (tester) async {
      await tester.pumpWidget(_themedSplash(ThemeMode.dark));

      expect(_splashBackground(tester), _darkScheme.surfaceContainerLow);
      expect(_splashTheme(tester).colorScheme.brightness, Brightness.dark);
    });

    testWidgets('跟随系统 × 系统亮：品牌页用浅色', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.light),
          child: _themedSplash(ThemeMode.system),
        ),
      );

      expect(_splashBackground(tester), _lightScheme.surfaceContainerLow);
    });

    testWidgets('跟随系统 × 系统暗：品牌页用深色', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.dark),
          child: _themedSplash(ThemeMode.system),
        ),
      );

      expect(_splashBackground(tester), _darkScheme.surfaceContainerLow);
    });

    testWidgets('跟随系统且无 MediaQuery：回落 platformDispatcher（与 ThemeProvider 同源）', (
      tester,
    ) async {
      // `ThemeProvider.effectiveBrightness` 读的就是 platformDispatcher.platformBrightness；
      // 这里直接钉住「同一个来源」，而不是另造一套亮度判断。
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      final resolved = resolveSplashColorScheme(
        themeMode: ThemeMode.system,
        lightScheme: _lightScheme,
        darkScheme: _darkScheme,
      );

      expect(resolved, _darkScheme);
    });

    testWidgets('主题解析失败（ThemeProvider 不可用）→ 兜底深色且不崩', (tester) async {
      // 不给 light/dark 夹具：`ThemeProvider.instance` 在 widget test 里会抛
      // （`SystemTheme` 需要 FRB），正对应生产里 `RustLib.init` 失败的那一刻。
      await tester.pumpWidget(const SplashPage(themeMode: ThemeMode.light));

      expect(tester.takeException(), isNull);
      expect(find.text('Listenary'), findsOneWidget);
      expect(_splashBackground(tester), splashFallbackDarkScheme.surfaceContainerLow);
      expect(
        _splashTheme(tester).colorScheme.brightness,
        Brightness.dark,
        reason: '解析失败必须回退深色，不能把 Rust 失败升级成启动页崩溃',
      );
    });
  });
}
