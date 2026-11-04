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
//    品牌页**可见时长从品牌页首帧起算**固定为 [splashMinimumVisible]（2026-11-04 真机验收修正：
//    旧口径从 `main()` 起算、用 [SplashGate.alreadyElapsed] 抵扣首帧前的耗时，真机上几乎把
//    窗口吃光 ⇒ 完全没看清）；**每次冷启动都显示**，不加偏好键。
// D3 logo 素材：复用 `pubspec.yaml` 已声明的 `app_icon.ico`
//    （先例：`welcoming_page.dart:360`、`component/title_bar.dart:190` 的 `Image.asset`），
//    **不改 pubspec**。
// D4 理念文本：「让每一首歌都有归处」+ 品牌名「Listenary」。
// D5 动画：渐进式淡入——logo 淡入 + 轻微缩放 → 文本延迟浮现 → 初始化完成且**可见时长**
//    达标（[splashMinimumVisible]，2026-11-04 真机验收从 650ms 上调到 1600ms）后整体
//    淡出切主壳。时长与曲线复用 `lib/component/motion.dart` 的 `MotionDuration` /
//    `MotionCurve`，不另造一套。
// D6 背景跟随主题（2026-11-04 真机验收修正）：settings.json 在 `runApp` 之前就读完了
//    （`main.dart:194-196`），因此品牌页**首帧**即可按「主题模式 + 系统亮度」解析出与
//    主壳同源的 `ThemeProvider` scheme；背景仍取 `surfaceContainerLow`（与
//    `entry.dart:530-531` 的 `scaffoldBackgroundColor` 同源）；解析失败回退深色不崩。
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';

/// 品牌页最短可见时长：**从品牌页首帧起算**，不抵扣 `main()` 到 `runApp` 的耗时。
///
/// 2026-11-04 真机验收把这里从 650ms 提到 1600ms：旧口径从 `main()` 起算再用
/// [SplashGate.alreadyElapsed] 抵扣首帧前的耗时，真机上窗口几乎被吃光 ⇒ 用户
/// 「完全没看清」。现在首帧之前花掉的时间**不再抵扣可见窗口**。
///
/// 必须 ≥ [splashEntranceDuration]（680ms），入场动画才可能完整播完再淡出。
const Duration splashMinimumVisible = Duration(milliseconds: 1600);

/// 入场动画总时长 = 慢段 + 快段（D5：复用 `MotionDuration` 刻度，不另造毫秒数）。
///
/// 抽成顶层常量是为了让「最短可见窗口 ≥ 入场时长」这条约束可以被测试钉住。
final Duration splashEntranceDuration =
    MotionDuration.xSlow + MotionDuration.xFast;

/// 兜底深色方案的种子色（`RustLib.init` 失败时 `SystemTheme` 会抛）。
const Color splashFallbackSeedColor = Color(0xFF8AB4F8);

/// 冷启动品牌页：全屏 logo + 「Listenary」+ 理念文本，渐进式淡入（D4/D5）。
///
/// 这里**自带一个最小 MaterialApp**（无路由）而不是靠外层主题：
/// - 启动阶段主壳 `Entry` 还没构建，没有可继承的 `MaterialApp` / `ThemeProvider` 上下文；
/// - 它与主壳在 [SplashGate] 里是 `AnimatedSwitcher` 的**兄弟节点**，不是嵌套，
///   切换时不会出现两个 `Navigator` 互相套娃。
///
/// 背景色取所解析 scheme 的 `surfaceContainerLow` ——与 `entry.dart` 给
/// `MaterialApp.router` 的 `scaffoldBackgroundColor` 同源（见 `entry.dart:530-531`），
/// 所以品牌页淡出时底色与主壳一致、不闪色（D5/D6）。
class SplashPage extends StatefulWidget {
  const SplashPage({
    super.key,
    this.colorScheme,
    this.themeMode,
    this.lightScheme,
    this.darkScheme,
  });

  /// 仅测试 / 嵌入用：不传时按 [themeMode] + 系统亮度走 [resolveSplashColorScheme]
  /// （生产路径）。
  ///
  /// 为什么要这个注入点：`ThemeProvider` 的构造会调 `SystemTheme.getSystemTheme()`
  /// （FRB，需要 `RustLib.init()`），widget test 里没有它。
  final ColorScheme? colorScheme;

  /// 主题模式。不传时读 `ThemeProvider.instance.themeMode`（它由 `AppSettings.themeOption`
  /// 在构造时初始化，而 `settings.json` 在 `runApp` 之前已读完 ⇒ 品牌页首帧可得，D6）。
  final ThemeMode? themeMode;

  /// 仅测试 / 嵌入用：主题解析夹具（不传时取 [ThemeProvider] 的 light/dark）。
  ///
  /// widget test 里没有 FRB，`ThemeProvider` 构造会抛（`SystemTheme`），因此要验证
  /// 「浅色 / 跟随系统」这两条解析分支就必须能把两个 scheme 注入进来。
  final ColorScheme? lightScheme;
  final ColorScheme? darkScheme;

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
  static final Duration _entranceDuration = splashEntranceDuration;

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
    // D6：按「主题模式 + 系统亮度」解析实际生效 scheme；解析失败回退深色不崩。
    final scheme =
        widget.colorScheme ??
        resolveSplashColorScheme(
          themeMode: widget.themeMode,
          // `maybe` 版本：SplashPage 自带 MaterialApp，但在直接嵌入（widget test）时
          // 上面**没有** MediaQuery；缺失时 [resolveSplashColorScheme] 回落到
          // platformDispatcher，与 `ThemeProvider.effectiveBrightness` 同源。
          systemBrightness: MediaQuery.maybePlatformBrightnessOf(context),
          lightScheme: widget.lightScheme,
          darkScheme: widget.darkScheme,
        );

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

/// 解析品牌页实际生效的 scheme，口径与主壳 `entry.dart` / `ThemeProvider` 完全一致（D6）：
///
/// 1. **模式**：`ThemeProvider.themeMode`（构造时由 `AppSettings.themeOption` 初始化，
///    `settings.json` 在 `runApp` 之前已读完 ⇒ 品牌页首帧可得）；
/// 2. **亮度**：`ThemeMode.system` 时取平台 brightness —— 与
///    `ThemeProvider.effectiveBrightness` 同一个来源
///    （`platformDispatcher.platformBrightness`；生产路径传
///    `MediaQuery.maybePlatformBrightnessOf(context)`，它同样由 `FlutterView` 派生），
///    不另造判断；
/// 3. **scheme**：亮/暗分别取 `ThemeProvider.lightScheme` / `darkScheme` ——
///    `entry.dart:758-768` 就是把这两个交给 `MaterialApp.router` 的
///    `theme` / `darkTheme`，种子色已由 `theme.dart` 的 `_configuredThemeSeedColor()`
///    （Windows 强调色 / 用户自定色 / 封面取色）烘焙进方案里。
///
/// 背景仍取该方案的 `surfaceContainerLow`，与 `entry.dart:530-531` 的
/// `scaffoldBackgroundColor` 同源 ⇒ 淡出到主壳不闪色。
///
/// 任一步失败（`RustLib.init` 失败时 `SystemTheme.getSystemTheme()` 会抛，
/// `ThemeProvider` 的构造随之抛）→ 兜底深色，绝不把「Rust 失败」升级成「启动页崩溃」。
ColorScheme resolveSplashColorScheme({
  ThemeMode? themeMode,
  Brightness? systemBrightness,
  ColorScheme? lightScheme,
  ColorScheme? darkScheme,
}) {
  try {
    final mode = themeMode ?? ThemeProvider.instance.themeMode;
    final effectiveBrightness = switch (mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system =>
        systemBrightness ??
            WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    return switch (effectiveBrightness) {
      Brightness.light => lightScheme ?? ThemeProvider.instance.lightScheme,
      Brightness.dark => darkScheme ?? ThemeProvider.instance.darkScheme,
    };
  } catch (err, trace) {
    logger.w('读取主题失败，品牌页使用兜底深色方案', error: err, stackTrace: trace);
    return splashFallbackDarkScheme;
  }
}

/// 兜底深色方案（`ThemeProvider` 不可用时）：与主壳无关，只保证品牌页可读且不崩。
final ColorScheme splashFallbackDarkScheme = ColorScheme.fromSeed(
  seedColor: splashFallbackSeedColor,
  brightness: Brightness.dark,
);

/// 冷启动编排：先显示 [SplashPage]，**首帧起算的可见窗口**走完且 [warmUp] 完成后切主壳。
///
/// 时序（D2/D5，2026-11-04 真机验收修正）：
/// 1. 首帧 = 品牌页，**没有空壳闪烁**（窗口原生首帧即 Show，见
///    `windows/runner/flutter_window.cpp`）；
/// 2. 品牌页**首帧之后**才启动 [warmUp]（`addPostFrameCallback`）⇒ 初始化与入场动画并行；
/// 3. 截止时刻 = **品牌页首帧时刻 + [minimumVisible]** 与 `warmUp` 完成时刻取较晚者
///    → `AnimatedSwitcher` 交叉淡出到主壳；
/// 4. 主壳首帧后回调 [onReady]（三段式降级的提示挂在这里，等 overlay/messenger 装好）。
///
/// 与旧口径的区别：旧实现从 `main()` 起算再用 [alreadyElapsed] 抵扣，真机上
/// 首帧之前的初始化（Rust / 单实例 / 窗口 show）几乎把窗口吃光，用户「完全没看清」。
/// 现在**可见窗口从品牌页首帧起算**，[alreadyElapsed] 只作为首帧前耗时的诊断信息，
/// 不参与长度计算。
class SplashGate extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.warmUp,
    this.minimumVisible = splashMinimumVisible,
    this.alreadyElapsed = Duration.zero,
    this.colorScheme,
    this.themeMode,
    this.lightScheme,
    this.darkScheme,
    this.onReady,
  });

  /// 后台初始化，返回主壳（`Entry`）。推迟到品牌页首帧之后才调用。
  final Future<Widget> Function() warmUp;

  /// 品牌页最短**可见**时长（默认 [splashMinimumVisible] = 1600ms，从首帧起算）。
  final Duration minimumVisible;

  /// `main()` 起点到 `runApp` 之间已经花掉的时间。
  ///
  /// **仅用于日志诊断**：可见窗口从品牌页首帧起算，这段耗时不再从窗口里抵扣，
  /// 否则首帧前的初始化会把用户的可见时长吃光（2026-11-04 真机问题 1）。
  final Duration alreadyElapsed;

  /// 仅测试 / 嵌入用，透传给 [SplashPage.colorScheme]。
  final ColorScheme? colorScheme;

  /// 仅测试 / 嵌入用，透传给 [SplashPage.themeMode]（不传时走 `ThemeProvider`）。
  final ThemeMode? themeMode;

  /// 仅测试 / 嵌入用，透传给 [SplashPage.lightScheme] / [SplashPage.darkScheme]。
  final ColorScheme? lightScheme;
  final ColorScheme? darkScheme;

  /// 主壳首帧之后的回调（只会触发一次）。
  final VoidCallback? onReady;

  /// 交叉淡出器（测试用定位点；淡出时长必须保持 [MotionDuration.base]）。
  static const ValueKey<String> switcherKey = ValueKey<String>(
    'splash-switcher',
  );

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
      // 这个回调在**品牌页首帧**画完之后才跑 ⇒ 可见窗口从这里起算：
      // 首帧之前花掉的时间（[SplashGate.alreadyElapsed]）不再抵扣可见时长。
      logger.d(
        '[splash] 首帧已渲染：runApp 前耗时 '
        '${widget.alreadyElapsed.inMilliseconds}ms（不抵扣），'
        '首帧起可见 ${widget.minimumVisible.inMilliseconds}ms',
      );
      unawaited(_startDeferredStartup());
    });
  }

  Future<void> _startDeferredStartup() async {
    if (_started || !mounted) return;
    _started = true;

    // 可见窗口与 warmUp **并行**计时；截止 = max(首帧 + minimumVisible, warmUp 完成)。
    final visibleWindow = Future<void>.delayed(
      widget.minimumVisible.isNegative ? Duration.zero : widget.minimumVisible,
    );

    Widget? shell;
    try {
      shell = await widget.warmUp();
    } catch (err, trace) {
      // 与改造前同口径：初始化失败时没有可用的主壳（改造前是直接崩在 runApp 之前）。
      // 这里保留品牌页并把错误写进日志，不把半初始化的主壳交给用户。
      logger.e('启动初始化失败，品牌页保持展示', error: err, stackTrace: trace);
    }

    await visibleWindow;
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
      key: SplashGate.switcherKey,
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
              themeMode: widget.themeMode,
              lightScheme: widget.lightScheme,
              darkScheme: widget.darkScheme,
            )
          : KeyedSubtree(
              key: const ValueKey<String>('shell'),
              child: shell,
            ),
    );
  }
}
