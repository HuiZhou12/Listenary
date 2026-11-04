// Listenary 冷启动品牌页 + 启动编排（SplashGate）。
//
// ═══════════════════════════════════════════════════════════════════════════
// 已拍板的用户决策（2026-11-03，全部落地在本文件与 lib/main.dart）
// ───────────────────────────────────────────────────────────────────────────
// D1 落地页 = 首页（HOME_PAGE）：**非首启**与**首启（welcoming 选完目录）**都落首页。
//    改动点：`lib/page/updating_page.dart` 与 `lib/page/welcoming_page.dart` 里的
//    `AUDIOS_PAGE` 硬编码 → `HOME_PAGE`；**不动** `AppPreference.startPage` 机制
//    （它只服务 `/` 重定向，启动流程不访问 `/`）。
// D2 启动品牌页形态：与初始化**并行**——初始化在品牌页展示期间后台进行，就绪后淡出进主壳；
//    **总启动时长不增加**（最短展示窗口从 `main()` 起算，扣掉进入 `runApp` 前已花掉的时间，
//    见 [SplashGate.alreadyElapsed]）；**每次冷启动都显示**，不加偏好键。
// D3 logo 素材：复用 `pubspec.yaml` 已声明的 `app_icon.ico`
//    （先例：`welcoming_page.dart:360`、`component/title_bar.dart:190` 的 `Image.asset`），
//    **不改 pubspec**。
// D4 理念文本：「让每一首歌都有归处」+ 品牌名「Listenary」。
// D5 动画：渐进式淡入——logo 淡入 + 轻微缩放 → 文本延迟浮现 → 初始化完成且最短展示
//    600-800ms（本文件取 650ms）后整体淡出切主壳。时长与曲线复用
//    `lib/component/motion.dart` 的 `MotionDuration` / `MotionCurve`，不另造一套。
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';

/// 品牌页最短展示窗口（D2/D5 的 600-800ms 区间取中值）。
///
/// 从 `main()` 起算、由 [SplashGate.alreadyElapsed] 抵扣 ⇒ 这段品牌动画与
/// `RustLib.init` / 窗口初始化等**必须前置**的初始化重叠，不额外拉长启动。
const Duration splashMinimumVisible = Duration(milliseconds: 650);

/// 冷启动品牌页：全屏 logo + 「Listenary」+ 理念文本，渐进式淡入（D4/D5）。
///
/// 这里**自带一个最小 MaterialApp**（深色、无路由）而不是靠外层主题：
/// - 启动阶段主壳 `Entry` 还没构建，没有可继承的 `MaterialApp` / `ThemeProvider` 上下文；
/// - 它与主壳在 [SplashGate] 里是 `AnimatedSwitcher` 的**兄弟节点**，不是嵌套，
///   切换时不会出现两个 `Navigator` 互相套娃。
///
/// 背景色取 `core/theme.dart` 里 `ThemeProvider.darkScheme` 的 `surfaceContainerLow`
/// ——与 `entry.dart` 给 `MaterialApp.router` 的 `scaffoldBackgroundColor` 同源（见
/// `entry.dart:530-531`），所以品牌页淡出时底色与主壳一致、不闪色（D5）。
class SplashPage extends StatefulWidget {
  const SplashPage({super.key, this.colorScheme});

  /// 仅测试 / 嵌入用：不传时取 [ThemeProvider.instance] 的深色方案（生产路径）。
  ///
  /// 为什么要这个注入点：`ThemeProvider` 的构造会调 `SystemTheme.getSystemTheme()`
  /// （FRB，需要 `RustLib.init()`），widget test 里没有它。
  final ColorScheme? colorScheme;

  static const ValueKey<String> logoKey = ValueKey<String>('splash-logo');
  static const ValueKey<String> brandKey = ValueKey<String>('splash-brand');
  static const ValueKey<String> taglineKey = ValueKey<String>('splash-tagline');
  static const ValueKey<String> logoFadeKey = ValueKey<String>(
    'splash-logo-fade',
  );
  static const ValueKey<String> brandFadeKey = ValueKey<String>(
    'splash-brand-fade',
  );
  static const ValueKey<String> taglineFadeKey = ValueKey<String>(
    'splash-tagline-fade',
  );

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  /// 文本比 logo 晚一步浮现（D5 的「文本延迟浮现」）。
  static const Duration _brandDelay = Duration(milliseconds: 90);
  static const Duration _taglineDelay = Duration(milliseconds: 200);

  /// 入场总时长 = 慢段 + 快段（D5：复用 MotionDuration 的刻度，不另造一套毫秒数）。
  static final Duration _entranceDuration =
      MotionDuration.xSlow + MotionDuration.xFast;

  late final AnimationController _entrance =
      AnimationController(vsync: this, duration: _entranceDuration)..forward();

  double _fractionOf(Duration offset) =>
      (offset.inMicroseconds / _entranceDuration.inMicroseconds).clamp(
        0.0,
        1.0,
      );

  late final Animation<double> _logoFade = CurvedAnimation(
    parent: _entrance,
    curve: Interval(
      0.0,
      _fractionOf(MotionDuration.slow),
      curve: MotionCurve.entrance,
    ),
  );

  late final Animation<double> _logoScale = Tween<double>(
    begin: 0.92,
    end: 1.0,
  ).animate(
    CurvedAnimation(
      parent: _entrance,
      curve: Interval(
        0.0,
        _fractionOf(MotionDuration.slow),
        curve: MotionCurve.entrance,
      ),
    ),
  );

  late final Animation<double> _brandFade = CurvedAnimation(
    parent: _entrance,
    curve: Interval(
      _fractionOf(_brandDelay),
      _fractionOf(_brandDelay + MotionDuration.slow),
      curve: MotionCurve.entrance,
    ),
  );

  late final Animation<double> _taglineFade = CurvedAnimation(
    parent: _entrance,
    curve: Interval(
      _fractionOf(_taglineDelay),
      1.0,
      curve: MotionCurve.standard,
    ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统开了「减少动态效果」时直接落到终态（与 component/motion.dart 的口径一致）。
    if (MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = 1.0;
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  ThemeData _theme(ColorScheme scheme) {
    // 不写 `brightness:`：ThemeData 会从 colorScheme 推导，避免与传入的亮色方案互相断言。
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLow,
      canvasColor: scheme.surfaceContainerLow,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.colorScheme ?? _configuredDarkScheme();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(scheme),
      home: Scaffold(
        backgroundColor: scheme.surfaceContainerLow,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _logoScale,
                child: FadeTransition(
                  key: SplashPage.logoFadeKey,
                  opacity: _logoFade,
                  child: Image.asset(
                    // D3：复用已声明的 app_icon.ico（welcoming_page.dart:360 先例），
                    // 不改 pubspec、不新增素材。
                    'app_icon.ico',
                    key: SplashPage.logoKey,
                    width: 96.0,
                    height: 96.0,
                    filterQuality: FilterQuality.medium,
                    // 素材缺失（含 widget test 的无资产环境）时退化为图标，绝不让启动页报错。
                    errorBuilder: (context, error, stackTrace) => Icon(
                      Icons.graphic_eq,
                      size: 96.0,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Spacing.lg),
              FadeTransition(
                key: SplashPage.brandFadeKey,
                opacity: _brandFade,
                child: Text(
                  // D4：品牌名。
                  'Listenary',
                  key: SplashPage.brandKey,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: AppType.display,
                    fontWeight: AppType.weightBold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: Spacing.sm),
              FadeTransition(
                key: SplashPage.taglineFadeKey,
                opacity: _taglineFade,
                child: Text(
                  // D4：理念文本。
                  '让每一首歌都有归处',
                  key: SplashPage.taglineKey,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 品牌页的兜底深色方案：能读到 `ThemeProvider` 就用它与主壳同源的深色 scheme，
/// 读不到（`RustLib.init` 失败时 `SystemTheme.getSystemTheme()` 会抛）就退回纯深色。
///
/// 为什么必须兜底：`main()` 对 `RustLib.init` 失败是**吞掉并继续**的（改造前第 97-101 行），
/// 品牌页若在 `build` 里直接摸 `ThemeProvider.instance`，就会把「Rust 初始化失败」
/// 升级成「启动页 build 抛异常」—— 那是比原行为更差的失败面。
ColorScheme _configuredDarkScheme() {
  try {
    return ThemeProvider.instance.darkScheme;
  } catch (err, trace) {
    logger.w('读取主题失败，品牌页使用兜底深色方案', error: err, stackTrace: trace);
    return ColorScheme.fromSeed(
      seedColor: const Color(0xFF8AB4F8),
      brightness: Brightness.dark,
    );
  }
}

/// 冷启动编排：先显示 [SplashPage]，[warmUp] 完成后（且最短展示窗口已过）切主壳。
///
/// 时序（D2/D5）：
/// 1. 首帧 = 品牌页，**没有空壳闪烁**（窗口原生首帧即 Show，见
///    `windows/runner/flutter_window.cpp`）；
/// 2. 品牌页**首帧之后**才启动 [warmUp]（`addPostFrameCallback`）⇒ 初始化与入场动画并行；
/// 3. `warmUp` 完成 **且** 最短窗口已过 → `AnimatedSwitcher` 交叉淡出到主壳；
/// 4. 主壳首帧后回调 [onReady]（三段式降级的提示挂在这里，等 overlay/messenger 装好）。
class SplashGate extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.warmUp,
    this.minimumVisible = splashMinimumVisible,
    this.alreadyElapsed = Duration.zero,
    this.colorScheme,
    this.onReady,
  });

  /// 后台初始化，返回主壳（`Entry`）。推迟到品牌页首帧之后才调用。
  final Future<Widget> Function() warmUp;

  /// 品牌页最短展示窗口（默认 650ms，D2/D5 的 600-800ms 区间）。
  final Duration minimumVisible;

  /// 从 `main()` 起算、到 `runApp` 已经花掉的时间；从最短窗口里扣掉
  /// ⇒ 品牌动画吃的是**已经花掉的启动预算**，总启动时长不增加（D2）。
  final Duration alreadyElapsed;

  /// 仅测试 / 嵌入用，透传给 [SplashPage.colorScheme]。
  final ColorScheme? colorScheme;

  /// 主壳首帧之后的回调（只会触发一次）。
  final VoidCallback? onReady;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  Widget? _shell;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startDeferredStartup());
    });
  }

  Future<void> _startDeferredStartup() async {
    if (_started || !mounted) return;
    _started = true;

    final remaining = widget.minimumVisible - widget.alreadyElapsed;
    final minimumWindow = Future<void>.delayed(
      remaining.isNegative ? Duration.zero : remaining,
    );

    Widget? shell;
    try {
      shell = await widget.warmUp();
    } catch (err, trace) {
      // 与改造前同口径：初始化失败时没有可用的主壳（改造前是直接崩在 runApp 之前）。
      // 这里保留品牌页并把错误写进日志，不把半初始化的主壳交给用户。
      logger.e('启动初始化失败，品牌页保持展示', error: err, stackTrace: trace);
    }

    await minimumWindow;
    if (!mounted || shell == null) return;

    setState(() => _shell = shell);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onReady?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    // `SplashGate` 是 `runApp` 的**根**：它上面没有 `MaterialApp`，因此既没有
    // `MediaQuery` 也没有 `Directionality`（`Stack` 默认对齐需要后者）。这里补一个
    // **最小 shim**，而不是再套一层 `MaterialApp` —— 套 MaterialApp 会让主壳的
    // `MaterialApp.router` 变成内层 App，`Navigator.of(rootNavigator: true)` 会穿过
    // 主壳的 Navigator 找外层，弹窗/路由语义会被悄悄改掉。
    return MediaQuery.fromView(
      view: View.of(context),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: _buildSwitcher),
      ),
    );
  }

  Widget _buildSwitcher(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final shell = _shell;

    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : MotionDuration.base,
      switchInCurve: MotionCurve.emphasized,
      switchOutCurve: MotionCurve.standard,
      // 全屏交叉淡出：默认 layoutBuilder 只居中排布，主壳不会铺满窗口。
      // 退出的品牌页套 IgnorePointer，避免淡出期间抢走主壳的指针事件。
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [
          for (final child in previousChildren) IgnorePointer(child: child),
          ?currentChild,
        ],
      ),
      child: shell == null
          ? SplashPage(
              key: const ValueKey<String>('splash'),
              colorScheme: widget.colorScheme,
            )
          : KeyedSubtree(
              key: const ValueKey<String>('shell'),
              child: shell,
            ),
    );
  }
}
