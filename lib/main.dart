// Listenary 冷启动入口（组合根）。
//
// ═══════════════════════════════════════════════════════════════════════════
// 已拍板的用户决策（2026-11-03）——见 `lib/page/splash_page.dart` 文件头
// ───────────────────────────────────────────────────────────────────────────
// D1 落地页 = 首页（HOME_PAGE）：非首启与首启（welcoming 选完目录）都落首页。
// D2 启动品牌页：与初始化并行；品牌页展示期间后台跑「可后置」的初始化，就绪后淡出进
//    主壳，**总启动时长不增加**；每次冷启动都显示，不加偏好键。
// D5 动画时序与最短展示窗口由 `SplashGate` 承担（`lib/page/splash_page.dart`）。
//
// 本文件因此分成两段：
//   ① `runApp` **之前**：不改的一条不动的初始化链（Rust / 单实例 / 版本守卫 / 热键 /
//      数据目录 / settings.json / 窗口 show）。
//   ② `runApp(SplashGate(warmUp: ...))`：品牌页首帧之后才跑的后置初始化，参见
//      [_deferredStartup]。`Entry` 的构造方式与参数**完全没有变化**。
//
// ⚠️ settings.json 的读取**留在 ①**：`initWindow()` 要用
// `AppSettings.instance.windowSize` / `isWindowMaximized` 才能按用户上次的窗口几何
// Show（main.dart 原第 33、58 行）。把它后置会让窗口尺寸回落到默认值 —— 所以它属于
// 「窗口 show 前的最小集」而不是可后置项；字体字节加载仍然后置。
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/setting_action_state.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/sqlite_version_guard.dart';
import 'package:pure_music/core/cache.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/entry.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/core/memory_monitor.dart';
import 'package:pure_music/native/rust/api/logger.dart';
import 'package:pure_music/native/rust/frb_generated.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/splash_page.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_access.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_single_instance/flutter_single_instance.dart';

Future<void> initWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  final minimumSize = Size(
    minimumWindowSizeSetting.width,
    minimumWindowSizeSetting.height,
  );
  Size targetSize = AppSettings.instance.windowSize;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final display = view.display;
  final displayW = display.size.width / display.devicePixelRatio;
  final displayH = display.size.height / display.devicePixelRatio;
  final maxW = (displayW - 16.0)
      .clamp(minimumSize.width, double.infinity)
      .toDouble();
  final maxH = (displayH - 16.0)
      .clamp(minimumSize.height, double.infinity)
      .toDouble();
  targetSize = Size(
    targetSize.width.clamp(minimumSize.width, maxW),
    targetSize.height.clamp(minimumSize.height, maxH),
  );

  WindowOptions windowOptions = WindowOptions(
    minimumSize: minimumSize,
    size: targetSize,
    center: true,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    if (AppSettings.instance.isWindowMaximized) {
      await windowManager.maximize();
    }
    await windowManager.focus();
  });
}

Future<void> loadPrefFont() async {
  final settings = AppSettings.instance;
  if (settings.fontFamily != null) {
    try {
      final fontLoader = FontLoader(settings.fontFamily!);

      fontLoader.addFont(
        File(settings.fontPath!).readAsBytes().then((value) {
          return ByteData.sublistView(value);
        }),
      );
      await fontLoader.load();
      ThemeProvider.instance.changeFontFamily(settings.fontFamily!);
    } catch (err, trace) {
      logger.e(err, stackTrace: trace);
    }
  }
}

/// 后置初始化的产物：主壳 `Entry` 需要的两个在线音乐依赖 + `welcome` 判定。
///
/// 之所以不直接返回 `Entry`：`SplashGate.warmUp` 的契约是「返回主壳 Widget」，
/// 而 `welcome` 必须在 `Entry` 构造时一并传入（构造方式与参数保持不变，见任务边界）。
Future<Widget> _deferredStartup({required bool welcome}) async {
  // —— 到这里为止，品牌页已经画出首帧，下面每一步都与入场动画并行进行（D2）——
  await loadPrefFont();
  await AppPreference.read();
  await AlbumColorCache.instance.init();

  MemoryMonitorService.instance.start();

  final activeOnlineMusicSettings = AppPreference.instance.onlineMusicSettings;
  // 同一个凭据出口同时给「装配」与「设置页/探测」用：portable 模式下写入与读取才是同一份。
  final onlineMusicCredentialAccess = ChkszCredentialAccess(
    portableBuild: portableBuild,
  );
  final onlineMusic = createOnlineMusicComposition(
    settings: activeOnlineMusicSettings,
    portableBuild: portableBuild,
    credentialAccess: onlineMusicCredentialAccess,
  );
  final onlineMusicSettingsController = OnlineMusicProviderSettingsController(
    activeSettings: activeOnlineMusicSettings,
    store: const AppPreferenceOnlineMusicSettingsStore(),
    fallbackCredentials: onlineMusicCredentialAccess,
    credentialReader: onlineMusicCredentialAccess,
    runningCredentials: onlineMusic.credentialControllers,
  );

  // Entry 的构造方式与参数与改造前完全一致。
  return Entry(
    welcome: welcome,
    onlineMusicService: onlineMusic.service,
    onlineMusicSettings: onlineMusicSettingsController,
  );
}

Future<void> main() async {
  // 品牌页最短展示窗口从 `main()` 起算（D2：总启动时长不增加），
  // 因此这里记录起点，稍后当作 `SplashGate.alreadyElapsed` 抵扣掉已花掉的时间。
  final startupClock = Stopwatch()..start();

  WidgetsFlutterBinding.ensureInitialized();

  // 覆盖多屏缩略图，避免滚动回来时反复解码；内存监控仍会分级回收。
  PaintingBinding.instance.imageCache.maximumSize = 96;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 32 << 20;

  final singleInstance = FlutterSingleInstance();
  if (!await singleInstance.isFirstInstance()) {
    await singleInstance.focus();
    exit(0);
  }

  try {
    await RustLib.init();
  } catch (e, s) {
    logger.e('RustLib.init failed: $e\n$s');
  }

  // Spec §4.3 步骤 3：版本守卫必须在**首次 sqlite3.open 之前**（下面
  // AlbumColorCache.init 就会打开 app.sqlite）。不足则进入三段式降级态，
  // 提示推迟到窗口就绪后再弹（此刻还没有可用的 overlay）。AlbumColorCache.init
  // 已后移到品牌页阶段，但守卫仍然留在最前面 —— 那段窗口里品牌页正在播动画，
  // 降级提示挂到主壳首帧之后（见下面的 `onReady`）。
  final sqliteProbe = SqliteVersionGuard.instance.probeOnce();
  if (!sqliteProbe.isWritable) {
    logger.w(
      'SQLite 版本低于下限，进入禁写降级态：'
      '${sqliteProbe.libVersion} (${sqliteProbe.versionNumber}) '
      '< $minimumSupportedSqliteVersion',
    );
  }

  _rustLoggerSub = initRustLogger().listen((msg) {
    logger.i('[rs]: $msg');
  });

  // For hot reload, `unregisterAll()` needs to be called.
  await HotkeysHelper.unregisterAll();
  HotkeysHelper.registerHotKeys();

  final supportPath = (await getAppDataDir()).path;
  CoverImageCache.instance.configure(indexPath: supportPath);
  final settingsDir = await getSettingsDir();
  // settings.json 必须在 initWindow 之前读：窗口几何（size / maximized）来自它。
  if (File(path.join(settingsDir.path, 'settings.json')).existsSync()) {
    await AppSettings.readFromJson();
  }

  final welcome = !File(path.join(supportPath, 'index.json')).existsSync();

  await initWindow();
  await ImmersiveModeController.instance.init();

  // 品牌页成为窗口的首帧内容 ⇒ 天然没有「空壳」闪烁；`initWindow` 的
  // waitUntilReadyToShow → show/focus 时机保持原样。
  // `startupClock` 只用于日志诊断：品牌页的可见时长从**首帧**起算，不再抵扣这段耗时
  // （2026-11-04 真机验收：旧口径把可见窗口吃光，用户完全没看清）。
  // 主题不在主壳之前显式解析：品牌页由 `SplashPage`/`resolveSplashColorScheme` 在
  // build 里读 `ThemeProvider`（带兜底）——它需要 FRB，而 `RustLib.init` 失败是被
  // `main()` 吞掉后继续的，在这里直接摸 `ThemeProvider.instance` 会新增一条崩溃路径。
  runApp(
    SplashGate(
      alreadyElapsed: startupClock.elapsed,
      warmUp: () => _deferredStartup(welcome: welcome),
      onReady: _afterShellReady,
    ),
  );
}

/// 主壳首帧之后的一次性收尾（与改造前 `runApp` 之后的代码等价）。
void _afterShellReady() {
  // 三段式降级的第②段：一次性提示。放在主壳首帧之后，等 overlay/messenger
  // 装好再弹；`takeDegradedNotice()` 自带「每进程一次」。
  final degradedNotice = SqliteVersionGuard.instance.takeDegradedNotice();
  if (degradedNotice != null) {
    showTextOnSnackBar(
      degradedNotice,
      icon: Icons.info_outline,
      variant: ToastVariant.error,
    );
  }
}

StreamSubscription<String>? _rustLoggerSub;

void disposeMemoryMonitor() {
  MemoryMonitorService.instance.stop();
  _rustLoggerSub?.cancel();
  _rustLoggerSub = null;
}
