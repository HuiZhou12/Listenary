import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart';
import 'package:flutter/physics.dart';
import 'package:provider/provider.dart';

import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_tile.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_stagger_motion.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/play_service/play_service.dart';

/// 1 s 原生回读阶跃的平滑窗口（§5.2.2）：纠正量在该窗口内被完全吸收。
const lyricNativeCorrectionWindowMs = 150.0;

/// 只有小于这个量的回读纠正量才走平滑；更大则直接对齐（seek/大幅跳转）。
const lyricNativeCorrectionMaxMs = 32.0;

/// 行尾前强制对齐窗口（防滞后，R4 / M3）。
const lyricNativeCorrectionFlushLeadMs = 200.0;

/// 在线页外部锚点外推上限 = 1.5 × 50 ms 快照间隔（Grill Q3）。
const lyricExternalExtrapolationLimitMs = 75.0;

/// 新快照与当前渲染值之差超过此值就直接对齐（否则平滑）。
const lyricExternalSnapshotSnapMs = 32.0;

/// 帧间隔（60 Hz），用于把回读纠正量摊平到 [lyricNativeCorrectionWindowMs]。
const lyricCorrectionFrameMs = 1000.0 / 60.0;

/// 吸收一帧回读纠正量，返回本帧应推进的毫秒数（§5.2.2）。
///
/// - [residualMs]：剩余待吸收的纠正量（正 = 渲染进度落后原生位置）。
/// - [scheduledMs]：本次回读要吸收的总量，用于反推每帧步长
///   （`|scheduled| * frameMs / windowMs` ⇒ 恰好 150 ms 吸收完）。
/// - [flush]：为 true 时一次性吸收全部（行尾前 200 ms / pending seek）。
///
/// 不变量：单帧吸收量 ≤ |residual|，方向一致，且在
/// [lyricNativeCorrectionWindowMs] 内收敛。
double absorbLyricNativeCorrection({
  required double residualMs,
  required double scheduledMs,
  required bool flush,
}) {
  if (residualMs.abs() <= 0.001) return 0.0;
  if (flush) return residualMs;
  final scheduled = scheduledMs.abs() <= 0.001
      ? residualMs.abs()
      : scheduledMs.abs();
  // 线性分摊：每帧固定步长，窗口结束时正好吸收完（避免指数衰减拖尾）。
  final step =
      scheduled * (lyricCorrectionFrameMs / lyricNativeCorrectionWindowMs);
  if (residualMs.abs() <= step) return residualMs;
  return residualMs.sign * step;
}

class LyricsLineWidget extends StatefulWidget {
  const LyricsLineWidget({
    super.key,
    required this.line,
    required this.opacity,
    this.distance,
    this.positionMs,
    this.usesExternalPosition = false,
    this.isHighlightActive = false,
    this.accelerateTailHighlight = false,
    this.lineOffsetY = 0.0,
    this.lineOffsetProgressListenable,
    this.staggerDelay = Duration.zero,
    this.jumpTriggerId = 0,
    this.jumpDeltaY = 0.0,
    this.isUserScrolling = false,
    this.freezeHeight = false,
    this.reserveBackgroundVocalHeight = false,
    this.highlightDeadlineMs,
    this.backgroundVocalVisibilityListenable,
    this.onTap,
  });

  final LyricLine line;
  final double opacity;
  final int? distance;
  final double? positionMs;
  final bool usesExternalPosition;
  final bool isHighlightActive;
  final bool accelerateTailHighlight;
  final double lineOffsetY;
  final ValueListenable<double>? lineOffsetProgressListenable;
  final Duration staggerDelay;
  final int jumpTriggerId;
  final double jumpDeltaY;
  final bool isUserScrolling;
  final bool freezeHeight;
  final bool reserveBackgroundVocalHeight;
  final double? highlightDeadlineMs;
  final ValueListenable<double>? backgroundVocalVisibilityListenable;
  final VoidCallback? onTap;

  /// 保留给内存监控调用；歌词模糊已改为 painter 内绘制。
  static void clearBlurFilterCache() {}

  /// 测试缝（`@visibleForTesting`）：单元测试用它驱动进度 ticker，避免在
  /// 测试进程里初始化 play_service / BASS。生产路径两者均为 `null`，
  /// 行为与改动前逐值一致。
  @visibleForTesting
  static bool Function()? debugIsPlayingOverride;

  @visibleForTesting
  static double Function()? debugPositionOverride;

  @override
  State<LyricsLineWidget> createState() => _LyricsLineWidgetState();
}

class _LyricsLineWidgetState extends State<LyricsLineWidget>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late final LyricRenderConfig _config;
  bool _isHovered = false;
  Ticker? _ticker;
  double _currentTimeMs = 0;
  final ValueNotifier<double> _currentTimeNotifier = ValueNotifier(0);
  late final VoidCallback _playerStateListener;
  Duration _lastTickElapsed = Duration.zero;
  Duration _lastNativeSyncElapsed = Duration.zero;
  Duration _lastProgressPaintElapsed = Duration.zero;

  /// seek 后用于过滤旧进度回调的临时目标
  double? _pendingSeekMs;
  DateTime? _pendingSeekAt;
  static const _seekGuardWindowMs = 200;
  static const _nativePositionSyncInterval = Duration(seconds: 1);

  /// **数据节拍**（D3 / I2）：只在渲染节拍之外做"贵"的派生量
  /// （和声行高度因子等）。渲染节拍已改为每 vsync，因此这个常量不再限制
  /// 重绘频率。
  static const _progressPaintInterval = Duration(milliseconds: 33);

  /// 只有小于这个量的回读纠正量才走平滑；更大则直接对齐（seek/大幅跳转）。
  static const _nativeCorrectionMaxMs = lyricNativeCorrectionMaxMs;

  /// 行尾前强制对齐窗口（防滞后，R4 / M3）。
  static const _nativeCorrectionFlushLeadMs = lyricNativeCorrectionFlushLeadMs;

  /// 在线页外部锚点外推上限 = 1.5 × 50 ms 快照间隔（Grill Q3）。
  static const _externalExtrapolationLimitMs = lyricExternalExtrapolationLimitMs;

  /// 新快照与当前渲染值之差超过此值就直接对齐（否则平滑）。
  static const _externalSnapshotSnapMs = lyricExternalSnapshotSnapMs;

  late final AnimationController _scaleController;
  late final AnimationController _floatController;

  // 缓存 Painter，避免每帧重建
  LyricsLinePainter? _cachedPainter;
  double? _cachedLineHeight;
  double _cachedLineWidth = 0.0;
  LyricLine? _heightLine;
  LyricRenderConfig? _heightConfig;
  bool? _heightIsMainLine;
  bool? _heightUseMaterialYouColor;
  bool? _heightReservesBackgroundVocal;
  String? _heightFontFamily;
  String? _heightAgent;
  LyricLine? _effectTimingLine;
  Duration _effectLineMedian = Duration.zero;
  final ValueNotifier<double> _heightNotifier = ValueNotifier(0.0);
  double? _frozenHeight;
  double? _departingPaintHeight;
  double _lastBgHeightUpdateMs = -1e9;
  double _lastBackgroundVocalHeightFactor = -1.0;

  /// 1 s 回读平滑的残余纠正量（§5.2.2）。正值表示渲染进度还落后原生位置。
  double _nativeCorrectionResidualMs = 0.0;

  /// 本次回读要吸收的纠正总量（用于反推每帧步长，保证 150 ms 收敛）。
  double _nativeCorrectionScheduledMs = 0.0;

  /// 在线页外部锚点（§5.3）：收到快照时的位置与外推基准 elapsed（毫秒）。
  /// 用"快照之间的 elapsed 差"做外推，绝对时间不入公式（V4）。
  double _externalAnchorMs = 0.0;
  double? _externalAnchorElapsedMs;

  /// 在线页外部位置的渲染 ticker（仅在需要进度的行启用，到达外推上限即停）。
  Ticker? _externalTicker;

  void _clearHeightCache() {
    _cachedLineHeight = null;
    _cachedLineWidth = 0.0;
    _heightLine = null;
    _heightConfig = null;
    _heightIsMainLine = null;
    _heightUseMaterialYouColor = null;
    _heightReservesBackgroundVocal = null;
    _heightFontFamily = null;
    _heightAgent = null;
  }

  void _applyMeasuredHeight(double measuredHeight) {
    final resolvedHeight = widget.freezeHeight
        ? max(_frozenHeight ?? _heightNotifier.value, measuredHeight)
        : measuredHeight;
    if (widget.freezeHeight) {
      _frozenHeight = resolvedHeight;
    }
    if ((resolvedHeight - _heightNotifier.value).abs() <= 0.01) return;
    _cachedLineHeight = resolvedHeight;
    _heightNotifier.value = resolvedHeight;
  }

  /// 是否处于"和声预留"状态（当前行/高亮行且该行确有和声内容）。
  bool get _reservesBackgroundVocal {
    final line = widget.line;
    if (!widget.reserveBackgroundVocalHeight || line is! SyncLyricLine) {
      return false;
    }
    return line.bgText?.isNotEmpty == true ||
        line.bgWords.isNotEmpty ||
        line.bgTranslation?.isNotEmpty == true ||
        line.bg?.romanLyric?.isNotEmpty == true;
  }

  /// D5：**布局**高度（恒定值）。
  ///
  /// 处于和声预留状态时取"和声块满额"（因子 1.0）的高度；否则就是普通行高。
  /// 它只由 `(line, width, config, fontFamily, agent)` 决定，因此在同一行
  /// 生命周期内恒定 ⇒ 和声行入场时下方行全程不下移（D5 / D4-1）。
  ///
  /// 生长动画只发生在绘制层：`SizedBox(height: 恒定布局高度)` +
  /// `OverflowBox(paintHeight: 生长高度)`。
  double _measureLayoutHeight(double lineWidth) {
    final painter = _cachedPainter;
    if (painter == null) return 0.0;
    if (!_reservesBackgroundVocal) {
      return painter.measureHeight(
        lineWidth,
        reserveBackgroundVocalHeight: widget.reserveBackgroundVocalHeight,
      );
    }
    final full = painter.measureHeight(
      lineWidth,
      reserveBackgroundVocalHeight: true,
      backgroundVocalHeightFactor: 1.0,
    );
    return widget.freezeHeight ? max(_frozenHeight ?? full, full) : full;
  }

  Duration _lineMedianWordDuration(LyricLine line) {
    if (identical(_effectTimingLine, line)) return _effectLineMedian;
    _effectTimingLine = line;
    _effectLineMedian = line is SyncLyricLine
        ? lyricMedianWordDuration(line.words)
        : Duration.zero;
    return _effectLineMedian;
  }

  @override
  bool get wantKeepAlive {
    // 只保留当前行附近的 Widget（前后各 2 行），远离的可以销毁以节省内存
    final dist = (widget.distance ?? 999).abs();
    final shouldKeep = dist <= 2;

    // 如果从 keepAlive 变为不 keepAlive，主动清理缓存
    if (!shouldKeep && _cachedPainter != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _cachedPainter = null;
          _clearHeightCache();
        }
      });
    }

    return shouldKeep;
  }

  @override
  void initState() {
    super.initState();
    _currentTimeMs = widget.positionMs ?? _readNativePositionMs();
    _currentTimeNotifier.value = _currentTimeMs;
    if (widget.usesExternalPosition) {
      _externalAnchorMs = _currentTimeMs;
      _externalAnchorElapsedMs = null;
    }
    _config = context.read<LyricViewController>().renderConfig;
    _scaleController = AnimationController.unbounded(vsync: this);
    _scaleController.value = widget.distance == 0
        ? _config.mainLineScale * _config.activeLineScaleMultiplier
        : _config.subLineScale * _config.inactiveLineScaleMultiplier;
    _floatController = AnimationController.unbounded(vsync: this);
    _floatController.value = widget.distance == 0 ? 1.0 : 0.0;
    widget.backgroundVocalVisibilityListenable?.addListener(
      _updateBackgroundVocalHeight,
    );
    _playerStateListener = _syncProgressTicker;
    PlayService.instance.playbackService.playerStateNotifier.addListener(
      _playerStateListener,
    );
    _syncProgressTicker();
  }

  void _updateBackgroundVocalHeight() {
    if (!widget.reserveBackgroundVocalHeight) return;
    if (!mounted || _cachedPainter == null || _cachedLineWidth <= 0) return;
    final factor = widget.backgroundVocalVisibilityListenable?.value;
    if (factor != null) {
      if ((factor - _lastBackgroundVocalHeightFactor).abs() <= 0.002) return;
      _lastBackgroundVocalHeightFactor = factor;
    }
    final height = _cachedPainter!.measureHeight(
      _cachedLineWidth,
      reserveBackgroundVocalHeight: true,
    );
    _applyMeasuredHeight(height);
  }

  void _animateScale() {
    final target = widget.distance == 0
        ? _config.mainLineScale * _config.activeLineScaleMultiplier
        : _config.subLineScale * _config.inactiveLineScaleMultiplier;
    final style = context.read<LyricViewController>().renderConfig.staggerStyle;
    if (style == LyricStaggerStyle.smooth) {
      _scaleController.animateTo(
        target,
        duration: lyricSmoothTransitionDuration,
        curve: lyricSmoothTransitionCurve,
      );
      return;
    }
    final simulation = SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 100, damping: 17),
      _scaleController.value,
      target,
      0,
    );
    _scaleController.animateWith(simulation);
  }

  void _animateFloat() {
    final target = widget.distance == 0 ? 1.0 : 0.0;
    if ((_floatController.value - target).abs() < 0.001) return;
    final style = context.read<LyricViewController>().renderConfig.staggerStyle;
    if (style == LyricStaggerStyle.smooth) {
      _floatController.animateTo(
        target,
        duration: lyricSmoothTransitionDuration,
        curve: lyricSmoothTransitionCurve,
      );
      return;
    }

    _floatController.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 100, damping: 17),
        _floatController.value,
        target,
        0,
      ),
    );
  }

  bool get _needsProgressTicker =>
      !widget.usesExternalPosition &&
      (widget.distance == 0 || widget.isHighlightActive) &&
      widget.line is SyncLyricLine &&
      (widget.line as SyncLyricLine).words.isNotEmpty &&
      _config.displayMode == LyricDisplayMode.wordByWord;

  /// 在线页（`usesExternalPosition`）是否需要用本地外推推进进度（§5.3 / D4）。
  ///
  /// 门控与本地 `_needsProgressTicker` 同源（只让"确有逐字进度"的行外推），
  /// 因此不新增常驻 Ticker（I1 / `dev/index.md:87`）。
  bool get _needsExternalExtrapolation =>
      widget.usesExternalPosition &&
      (widget.distance == 0 || widget.isHighlightActive) &&
      widget.line is SyncLyricLine &&
      (widget.line as SyncLyricLine).words.isNotEmpty &&
      _config.displayMode == LyricDisplayMode.wordByWord;

  /// 外部锚点 + 本地外推（§5.3）。
  ///
  /// 只用"快照之间的 elapsed 差"做外推，绝对时间不入公式（V4）。
  /// 外推上限 [_externalExtrapolationLimitMs]（=1.5 × 50 ms 快照间隔），
  /// 到达上限即停止推进并停掉 ticker，避免漂移与空转。
  void _onExternalTick(Duration elapsed) {
    if (!mounted || !_needsExternalExtrapolation) return;
    final elapsedMs = elapsed.inMicroseconds / 1000.0;
    final anchorElapsedMs = _externalAnchorElapsedMs;
    if (anchorElapsedMs == null) {
      // 第一帧只记录外推基准，不推进（保证首帧不跳）。
      _externalAnchorElapsedMs = elapsedMs;
      return;
    }
    var extrapolated = elapsedMs - anchorElapsedMs;
    if (extrapolated < 0) extrapolated = 0;
    if (extrapolated > _externalExtrapolationLimitMs) {
      extrapolated = _externalExtrapolationLimitMs;
      _externalTicker?.stop();
    }
    final target = _externalAnchorMs + extrapolated;
    if ((target - _currentTimeMs).abs() <= 0.001) return;
    _setCurrentTimeMs(target);
  }

  /// 收到新的外部快照（§5.3）：记锚点；差异小则继续外推，大则直接对齐。
  void _applyExternalPosition(double positionMs) {
    final delta = positionMs - _currentTimeMs;
    if (delta.abs() > _externalSnapshotSnapMs) {
      // 差异较大：直接对齐（同 §5.2.2 的大跳转分支）。
      _setCurrentTimeMs(positionMs);
    }
    _externalAnchorMs = positionMs;
    // 收到快照即重置外推基准：外推只从"这一帧"开始算。
    _externalAnchorElapsedMs = null;
    _ensureExternalTicker();
  }

  void _ensureExternalTicker() {
    if (!_needsExternalExtrapolation) {
      _externalTicker?.stop();
      return;
    }
    final ticker = _externalTicker ??= createTicker(_onExternalTick);
    if (!ticker.isActive) ticker.start();
  }

  void _syncProgressTicker() {
    if (_needsProgressTicker) {
      _syncToNativePosition();
      _lastTickElapsed = Duration.zero;
      _lastNativeSyncElapsed = Duration.zero;
      _lastProgressPaintElapsed = Duration.zero;
      _pendingSeekMs = null;
      _pendingSeekAt = null;
      final isPlaying =
          LyricsLineWidget.debugIsPlayingOverride?.call() ??
          PlayService.instance.playbackService.playerState ==
              PlayerState.playing;
      if (!isPlaying) {
        _ticker?.stop();
        return;
      }
      final ticker = _ticker ??= createTicker(_onTick);
      if (!ticker.isActive) ticker.start();
    } else {
      _ticker?.stop();
    }
    // 在线页外推 ticker 与本地进度 ticker 互斥（二者都只在需要进度时启用）。
    if (_needsExternalExtrapolation) {
      _ensureExternalTicker();
    } else {
      _externalTicker?.stop();
    }
  }

  double _readNativePositionMs() {
    final override = LyricsLineWidget.debugPositionOverride;
    if (override != null) return override();
    return PlayService.instance.playbackService.position * 1000.0;
  }

  void _syncToNativePosition() {
    _setCurrentTimeMs(_readNativePositionMs());
  }

  void _setCurrentTimeMs(double value, {bool notify = true}) {
    _currentTimeMs = value;
    if (notify && _currentTimeNotifier.value != value) {
      _currentTimeNotifier.value = value;
    }
  }

  bool _visualProgressChangedBetween(
    SyncLyricLine line,
    double fromMs,
    double toMs,
  ) {
    if (toMs < fromMs) return true;

    bool overlapsProgress(Iterable<SyncLyricWord> words) {
      for (final word in words) {
        final start = word.start.inMilliseconds.toDouble();
        final end = start + word.length.inMilliseconds;
        if (toMs >= start && fromMs <= end) return true;
      }
      return false;
    }

    if (overlapsProgress(line.words) || overlapsProgress(line.bgWords)) {
      return true;
    }
    final bgStart = (line.bgStart ?? line.bg?.start)?.inMilliseconds.toDouble();
    return bgStart != null &&
        toMs >= bgStart &&
        fromMs <= bgStart + lyricBackgroundVocalEntryDuration.inMilliseconds;
  }

  double _backgroundVocalHeightFactor(
    SyncLyricLine line,
    double currentTimeMs,
  ) {
    final start = (line.bgStart ?? line.bg?.start ?? line.start).inMilliseconds
        .toDouble();
    if (currentTimeMs < start) return 0.0;
    final progress =
        ((currentTimeMs - start) /
                lyricBackgroundVocalEntryDuration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();
    return Curves.easeOutBack.transform(progress);
  }

  double _targetOpacity() {
    final dist = (widget.distance ?? 0).abs();
    if (dist == 0) return 1.0;
    return (widget.opacity).clamp(0.0, 1.0);
  }

  void _onTick(Duration elapsed) {
    final previousTimeMs = _currentTimeMs;
    final elapsedDelta = _lastTickElapsed == Duration.zero
        ? Duration.zero
        : elapsed - _lastTickElapsed;
    _lastTickElapsed = elapsed;

    final shouldSyncNative =
        _lastNativeSyncElapsed == Duration.zero ||
        elapsed - _lastNativeSyncElapsed >= _nativePositionSyncInterval;
    final rawMs = shouldSyncNative
        ? _readNativePositionMs()
        : _currentTimeMs + elapsedDelta.inMicroseconds / 1000.0;
    if (shouldSyncNative) {
      _lastNativeSyncElapsed = elapsed;
    }

    final delta = rawMs - _currentTimeMs;
    var forceRepaint = false;

    // seek 保护：大幅跳转后的短窗口内，忽略与跳转方向相反的旧进度回调
    if (_pendingSeekMs != null && _pendingSeekAt != null) {
      final age = DateTime.now().difference(_pendingSeekAt!).inMilliseconds;
      if (age > _seekGuardWindowMs || (rawMs - _pendingSeekMs!).abs() <= 50) {
        _pendingSeekMs = null;
        _pendingSeekAt = null;
      } else if ((rawMs > _currentTimeMs) !=
          (_pendingSeekMs! > _currentTimeMs)) {
        // 方向相反，跳过本次回调
        if (mounted) _currentTimeNotifier.value = _currentTimeMs;
        return;
      }
    }

    if (delta.abs() >= 100) {
      // Seek 或大幅跳转：记录目标并直接同步（平滑不得吞掉 seek，D2-2）
      _pendingSeekMs = rawMs;
      _pendingSeekAt = DateTime.now();
      _nativeCorrectionResidualMs = 0.0;
      _nativeCorrectionScheduledMs = 0.0;
      _setCurrentTimeMs(rawMs, notify: false);
      forceRepaint = true;
    } else if (delta > 0.5) {
      if (shouldSyncNative && delta < _nativeCorrectionMaxMs) {
        // 1 s 原生回读的阶跃（§5.2.2）：把纠正量摊到
        // lyricNativeCorrectionWindowMs 内逐步吸收，而不是一帧覆盖。
        _nativeCorrectionResidualMs = delta;
        _nativeCorrectionScheduledMs = delta;
        _setCurrentTimeMs(
          _currentTimeMs + _absorbNativeCorrection(previousTimeMs),
          notify: false,
        );
      } else {
        // 常规插值推进，或纠正量过大（≥32 ms）⇒ 直接同步，避免滞后
        _nativeCorrectionResidualMs = 0.0;
        _nativeCorrectionScheduledMs = 0.0;
        _setCurrentTimeMs(rawMs, notify: false);
      }
    } else if (delta < -32) {
      // 暂停或倒带：回退到 raw
      _nativeCorrectionResidualMs = 0.0;
      _nativeCorrectionScheduledMs = 0.0;
      _setCurrentTimeMs(rawMs, notify: false);
      forceRepaint = true;
    } else if (_nativeCorrectionResidualMs.abs() > 0.01) {
      // 上一帧未吸收完的残余继续吸收（回读只发生在 1 s 节拍上）
      _setCurrentTimeMs(
        _currentTimeMs + _absorbNativeCorrection(previousTimeMs),
        notify: false,
      );
    } else {
      // 无可推进的差值（暂停、或原生位置没变）
      return;
    }

    if (!mounted) return;

    // ── 渲染节拍（每 vsync，§5.2.1）──────────────────────────────────────
    // 只有"本行确有可视化进度"的行才推渲染通知；非活动行仍走 33 ms 门控，
    // 不放大总重绘量（R8 / D1-3）。
    if (widget.line is SyncLyricLine) {
      final syncLine = widget.line as SyncLyricLine;
      if (!forceRepaint &&
          !_visualProgressChangedBetween(
            syncLine,
            previousTimeMs,
            _currentTimeMs,
          )) {
        if (_currentTimeNotifier.value != _currentTimeMs) {
          _currentTimeNotifier.value = _currentTimeMs;
        }
        return;
      }
      _publishRenderProgress();
      _runDataBeat(elapsed, syncLine);
    } else {
      _publishRenderProgress();
    }
  }

  /// 吸收一份 1 s 回读纠正量，返回本帧应当推进的毫秒数（§5.2.2）。
  double _absorbNativeCorrection(double previousTimeMs) {
    final residual = _nativeCorrectionResidualMs;
    if (residual.abs() <= 0.001) return 0.0;
    final absorbed = absorbLyricNativeCorrection(
      residualMs: residual,
      scheduledMs: _nativeCorrectionScheduledMs,
      flush: _shouldFlushNativeCorrection(),
    );
    _nativeCorrectionResidualMs = residual - absorbed;
    if (_nativeCorrectionResidualMs.abs() <= 0.001) {
      _nativeCorrectionResidualMs = 0.0;
      _nativeCorrectionScheduledMs = 0.0;
    }
    return absorbed;
  }

  /// 行尾前 [_nativeCorrectionFlushLeadMs] / 有 pending seek 时一次性吸收全部，
  /// 防止"平滑导致歌词末尾覆盖不全"（M3 / R4）。
  bool _shouldFlushNativeCorrection() {
    if (_pendingSeekMs != null) return true;
    final line = widget.line;
    if (line is! SyncLyricLine) return true;
    final endMs = _bgEndMs(line);
    final words = line.words;
    final wordEndMs = words.isEmpty
        ? endMs
        : (words.last.start.inMilliseconds +
                  words.last.length.inMilliseconds)
              .toDouble();
    final lineEndMs = wordEndMs > endMs ? wordEndMs : endMs;
    return _currentTimeMs >= lineEndMs - _nativeCorrectionFlushLeadMs;
  }

  /// 渲染节拍：只推进 painter 的 `ValueNotifier`，不做测量/求解/分配。
  void _publishRenderProgress() {
    if (_currentTimeNotifier.value != _currentTimeMs) {
      _currentTimeNotifier.value = _currentTimeMs;
    }
  }

  /// 数据节拍（33 ms 门控）：和声行因子等"贵"的派生量留在这里。
  ///
  /// D5 之后这里**不再改布局高度**（布局高度由 `_measureLayoutHeight` 恒定），
  /// 因此也不再每帧重算 `measureHeight`。
  void _runDataBeat(Duration elapsed, SyncLyricLine syncLine) {
    if (_lastProgressPaintElapsed != Duration.zero &&
        elapsed - _lastProgressPaintElapsed < _progressPaintInterval) {
      return;
    }
    _lastProgressPaintElapsed = elapsed;

    if (syncLine.bg != null || (syncLine.bgText?.isNotEmpty == true)) {
      final bgStart =
          (syncLine.bgStart ?? syncLine.bg?.start ?? syncLine.start)
              .inMilliseconds
              .toDouble();
      final bgEnd = _bgEndMs(syncLine);
      if (_currentTimeMs >= bgStart - 400 && _currentTimeMs < bgEnd + 5000) {
        final factor = _backgroundVocalHeightFactor(syncLine, _currentTimeMs);
        if ((factor - _lastBackgroundVocalHeightFactor).abs() > 0.002 &&
            (_currentTimeMs - _lastBgHeightUpdateMs).abs() > 8) {
          _lastBgHeightUpdateMs = _currentTimeMs;
          _lastBackgroundVocalHeightFactor = factor;
        }
      }
    }
  }

  double _bgEndMs(SyncLyricLine syncLine) {
    var end =
        (syncLine.bgEnd ??
                syncLine.bg?.end ??
                (syncLine.start + syncLine.length))
            .inMilliseconds
            .toDouble();
    if (syncLine.bgWords.isNotEmpty) {
      final last = syncLine.bgWords.last;
      final lastEnd = (last.start.inMilliseconds + last.length.inMilliseconds)
          .toDouble();
      if (lastEnd > end) end = lastEnd;
    }
    return end;
  }

  @override
  void didUpdateWidget(covariant LyricsLineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.positionMs != oldWidget.positionMs &&
        widget.positionMs != null) {
      if (widget.usesExternalPosition) {
        // 在线页：外部锚点 + 本地外推（§5.3 / D4）。50 ms 快照节奏与来源不变。
        _pendingSeekMs = null;
        _pendingSeekAt = null;
        _applyExternalPosition(widget.positionMs!);
      } else if ((widget.positionMs! - _currentTimeMs).abs() > 0.5) {
        _pendingSeekMs = null;
        _pendingSeekAt = null;
        _setCurrentTimeMs(widget.positionMs!);
      }
    }

    if (widget.backgroundVocalVisibilityListenable != null &&
        oldWidget.backgroundVocalVisibilityListenable == null &&
        _heightNotifier.value > 0) {
      _departingPaintHeight = _heightNotifier.value;
    } else if (widget.backgroundVocalVisibilityListenable == null) {
      _departingPaintHeight = null;
    }

    if (widget.freezeHeight && !oldWidget.freezeHeight) {
      if (_heightNotifier.value > 0) {
        _frozenHeight = _heightNotifier.value;
      }
    } else if (!widget.freezeHeight) {
      _frozenHeight = null;
    }

    final isActive = widget.distance == 0;
    final wasActive = oldWidget.distance == 0;
    final isHighlightActive = isActive || widget.isHighlightActive;
    final wasHighlightActive = wasActive || oldWidget.isHighlightActive;

    if (isHighlightActive != wasHighlightActive ||
        widget.line != oldWidget.line) {
      _syncProgressTicker();
    }

    if (isActive != wasActive) {
      _animateScale();
      _animateFloat();

      if (!isActive) {
        _cachedPainter = null;
        _clearHeightCache();
      }
    }

    if (widget.backgroundVocalVisibilityListenable !=
        oldWidget.backgroundVocalVisibilityListenable) {
      oldWidget.backgroundVocalVisibilityListenable?.removeListener(
        _updateBackgroundVocalHeight,
      );
      widget.backgroundVocalVisibilityListenable?.addListener(
        _updateBackgroundVocalHeight,
      );
    }

    final oldKeepAlive = (oldWidget.distance ?? 999).abs() <= 2;
    final newKeepAlive = (widget.distance ?? 999).abs() <= 2;
    if (oldKeepAlive != newKeepAlive) {
      updateKeepAlive();
    }

    if (widget.line != oldWidget.line) {
      _cachedPainter = null;
      _clearHeightCache();
      _frozenHeight = null;
      _pendingSeekMs = null;
      _pendingSeekAt = null;
      _lastBackgroundVocalHeightFactor = -1.0;
    }
  }

  @override
  void dispose() {
    PlayService.instance.playbackService.playerStateNotifier.removeListener(
      _playerStateListener,
    );
    _ticker?.dispose();
    _externalTicker?.dispose();
    _scaleController.dispose();
    _floatController.dispose();
    widget.backgroundVocalVisibilityListenable?.removeListener(
      _updateBackgroundVocalHeight,
    );
    _currentTimeNotifier.dispose();
    _heightNotifier.dispose();
    _cachedPainter = null;
    _cachedLineHeight = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必需

    final dist = (widget.distance ?? 0).abs();
    final isCurrentLine = widget.distance == 0;
    final isHighlightActive = isCurrentLine || widget.isHighlightActive;

    final renderConfig = context.watch<LyricViewController>().renderConfig;

    final effectiveTextAlign =
        renderConfig.hasMultipleAgents && widget.line is SyncLyricLine
        ? switch ((widget.line as SyncLyricLine).agent) {
            'v2' => LyricTextAlign.right,
            'v1' => LyricTextAlign.left,
            _ => renderConfig.textAlign,
          }
        : renderConfig.textAlign;

    final scaleAlignment = switch (effectiveTextAlign) {
      LyricTextAlign.left => Alignment.centerLeft,
      LyricTextAlign.center => Alignment.center,
      LyricTextAlign.right => Alignment.centerRight,
    };
    final scheme = Theme.of(context).colorScheme;
    final blurSigma = widget.isUserScrolling
        ? 0.0
        : (isCurrentLine ? 0.0 : renderConfig.blurSigmaForDistance(dist));

    final isTransitionLine = _isTransitionLine(widget.line, isCurrentLine);
    if (isTransitionLine) {
      if (!isCurrentLine) {
        return const SizedBox.shrink();
      }

      final verticalPad = widget.line is SyncLyricLine
          ? renderConfig.syncVerticalPadding(isMainLine: true)
          : renderConfig.lrcVerticalPadding();

      final transitionContent = SizedBox(
        height: transitionTileHeight,
        child: widget.line is SyncLyricLine
            ? LyricTransitionTile(
                key: ValueKey(widget.line),
                syncLine: widget.line as SyncLyricLine,
                alignment: effectiveTextAlign,
                useMaterialYouColor:
                    AppSettings.instance.useMaterialYouForTransition,
              )
            : LyricTransitionTile(
                key: ValueKey(widget.line),
                lrcLine: widget.line as LrcLine,
                alignment: effectiveTextAlign,
                useMaterialYouColor:
                    AppSettings.instance.useMaterialYouForTransition,
              ),
      );

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: transitionTileMargin),
        child: _LocalHoverMask(
          onTap: widget.onTap,
          color: scheme.onSurface.withValues(alpha: 0.08),
          child: Padding(
            padding: EdgeInsets.only(
              left: transitionTileMargin,
              right: transitionTileMargin,
              top: verticalPad,
              bottom: verticalPad,
            ),
            child: Align(alignment: scaleAlignment, child: transitionContent),
          ),
        ),
      );
    }

    final isShortBlank = widget.line is SyncLyricLine
        ? (widget.line as SyncLyricLine).words.isEmpty
        : widget.line is LrcLine && (widget.line as LrcLine).isBlank;
    if (isShortBlank) {
      return const SizedBox.shrink();
    }

    final effectiveOpacity = _isHovered ? 1.0 : _targetOpacity();
    final isSmoothTransition =
        renderConfig.staggerStyle == LyricStaggerStyle.smooth;
    final visualTransitionDuration = isSmoothTransition
        ? lyricSmoothTransitionDuration
        : const Duration(milliseconds: 600);
    final visualTransitionCurve = isSmoothTransition
        ? lyricSmoothTransitionCurve
        : Curves.easeOutCubic;

    Widget inner = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: effectiveOpacity),
      duration: visualTransitionDuration,
      curve: visualTransitionCurve,
      builder: (context, animatedOpacity, _) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: blurSigma),
          duration: visualTransitionDuration,
          curve: visualTransitionCurve,
          builder: (context, animatedBlurSigma, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final theme = Theme.of(context);
                final fontFamily =
                    theme.textTheme.bodyMedium?.fontFamily ??
                    theme.textTheme.bodySmall?.fontFamily;

                final lineWidth = constraints.maxWidth;
                // device pixel ratio 只用于 baseline(y) 的亚像素对齐（§5.1.4）。
                // 在 build 内取一次并注入 painter，不让 painter 每帧读 MediaQuery。
                final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
                final agent = widget.line is SyncLyricLine
                    ? (widget.line as SyncLyricLine).agent
                    : null;
                final useMaterialYouColor =
                    AppSettings.instance.useMaterialYouForLyrics;
                // 本地：每 vsync 的渲染 ticker；
                // 在线（§5.3）：同一 notifier 由外部锚点外推 ticker 推进 ⇒
                // 两条链路共用同一个 painter 重绘通道（D4）。
                final currentTimeListenable =
                    (_needsProgressTicker || _needsExternalExtrapolation)
                    ? _currentTimeNotifier
                    : null;
                final backgroundVocalVisibilityListenable =
                    widget.backgroundVocalVisibilityListenable;
                final lineMedianWordDuration = _lineMedianWordDuration(
                  widget.line,
                );

                if (_cachedPainter == null ||
                    _cachedPainter!.line != widget.line ||
                    _cachedPainter!.currentTimeListenable !=
                        currentTimeListenable ||
                    _cachedPainter!.backgroundVocalVisibilityListenable !=
                        backgroundVocalVisibilityListenable ||
                    (currentTimeListenable == null &&
                        _cachedPainter!.currentTimeMs != _currentTimeMs) ||
                    _cachedPainter!.blurSigma != animatedBlurSigma ||
                    _cachedPainter!.config != renderConfig ||
                    _cachedPainter!.isMainLine != isCurrentLine ||
                    _cachedPainter!.isHighlightActive != isHighlightActive ||
                    _cachedPainter!.accelerateTailHighlight !=
                        widget.accelerateTailHighlight ||
                    _cachedPainter!.useMaterialYouColor !=
                        useMaterialYouColor ||
                    _cachedPainter!.opacity != animatedOpacity ||
                    _cachedPainter!.fontFamily != fontFamily ||
                    _cachedPainter!.agent != agent ||
                    _cachedPainter!.highlightDeadlineMs !=
                        widget.highlightDeadlineMs ||
                    _cachedPainter!.devicePixelRatio != devicePixelRatio ||
                    _cachedPainter!.lineMedianWordDuration !=
                        lineMedianWordDuration) {
                  _cachedPainter = LyricsLinePainter(
                    line: widget.line,
                    currentTimeMs: _currentTimeMs,
                    currentTimeListenable: currentTimeListenable,
                    backgroundVocalVisibilityListenable:
                        backgroundVocalVisibilityListenable,
                    blurSigma: animatedBlurSigma,
                    config: renderConfig,
                    scheme: scheme,
                    isMainLine: isCurrentLine,
                    isHighlightActive: isHighlightActive,
                    accelerateTailHighlight: widget.accelerateTailHighlight,
                    useMaterialYouColor: useMaterialYouColor,
                    opacity: animatedOpacity,
                    fontFamily: fontFamily,
                    agent: agent,
                    highlightDeadlineMs: widget.highlightDeadlineMs,
                    devicePixelRatio: devicePixelRatio,
                    lineMedianWordDuration: lineMedianWordDuration,
                  );
                }

                final heightCacheValid =
                    _cachedLineHeight != null &&
                    _cachedLineWidth == lineWidth &&
                    identical(_heightLine, widget.line) &&
                    _heightConfig == renderConfig &&
                    _heightIsMainLine == isCurrentLine &&
                    _heightUseMaterialYouColor == useMaterialYouColor &&
                    _heightReservesBackgroundVocal ==
                        widget.reserveBackgroundVocalHeight &&
                    _heightFontFamily == fontFamily &&
                    _heightAgent == agent;
                // D5：布局高度取"和声满额"高度，与和声因子无关 ⇒ 生命周期内恒定。
                final lineHeight = heightCacheValid
                    ? _cachedLineHeight!
                    : _measureLayoutHeight(lineWidth);
                if (!heightCacheValid) {
                  if (widget.freezeHeight) _frozenHeight = null;
                  _cachedLineHeight = lineHeight;
                  _cachedLineWidth = lineWidth;
                  _heightLine = widget.line;
                  _heightConfig = renderConfig;
                  _heightIsMainLine = isCurrentLine;
                  _heightUseMaterialYouColor = useMaterialYouColor;
                  _heightReservesBackgroundVocal =
                      widget.reserveBackgroundVocalHeight;
                  _heightFontFamily = fontFamily;
                  _heightAgent = agent;
                }
                // ── D5：布局高度恒定 / 绘制高度按因子生长 ───────────────────
                // `SizedBox.height` = 恒定的布局高度（下方行不被推挤）；
                // `OverflowBox.paintHeight` = 随和声因子增长的绘制高度
                // （内容从顶部向下展开，超出布局高度的部分照常绘制）。
                final layoutHeight = widget.freezeHeight
                    ? _frozenHeight ??= lineHeight
                    : lineHeight;
                final bgBaseHeight = _reservesBackgroundVocal
                    ? _cachedPainter!.measureHeight(
                        lineWidth,
                        reserveBackgroundVocalHeight: false,
                      )
                    : null;
                final bgFactor =
                    (widget.backgroundVocalVisibilityListenable?.value ?? 1.0)
                        .clamp(0.0, 1.0)
                        .toDouble();
                final grownHeight = bgBaseHeight == null
                    ? layoutHeight
                    : bgBaseHeight + (layoutHeight - bgBaseHeight) * bgFactor;
                final paintHeight = max(
                  grownHeight,
                  _departingPaintHeight ?? grownHeight,
                );
                _heightNotifier.value = paintHeight;

                return ValueListenableBuilder<double>(
                  valueListenable: _heightNotifier,
                  builder: (context, h, _) {
                    return SizedBox(
                      height: layoutHeight,
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: h,
                        maxHeight: h,
                        child: SizedBox(
                          width: lineWidth,
                          height: h,
                          child: CustomPaint(
                            painter: _cachedPainter,
                            size: Size(lineWidth, h),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );

    inner = AnimatedBuilder(
      animation: _scaleController,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleController.value,
          alignment: scaleAlignment,
          child: child!,
        );
      },
      child: inner,
    );

    inner = AnimatedBuilder(
      animation: _floatController,
      builder: (context, child) {
        final offsetY = _floatController.value * -4.0;
        return Transform.translate(offset: Offset(0, offsetY), child: child!);
      },
      child: inner,
    );

    final lineOffsetProgress = widget.lineOffsetProgressListenable;
    if (lineOffsetProgress != null && widget.lineOffsetY != 0.0) {
      inner = AnimatedBuilder(
        animation: lineOffsetProgress,
        builder: (context, child) => Transform.translate(
          offset: Offset(0.0, widget.lineOffsetY * lineOffsetProgress.value),
          child: child,
        ),
        child: inner,
      );
    }

    if (_isHovered && widget.onTap != null) {
      inner = Container(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.08),
          borderRadius: AppRadius.mdCircular,
        ),
        child: inner,
      );
    }

    inner = LyricStaggerTransition(
      key: ValueKey('stagger_${widget.jumpTriggerId}'),
      enabled:
          renderConfig.enableStaggeredAnimation &&
          renderConfig.staggerStyle == LyricStaggerStyle.spring,
      generation: widget.jumpTriggerId,
      shiftY: widget.jumpDeltaY,
      delay: widget.staggerDelay,
      child: inner,
    );

    inner = GestureDetector(onTap: widget.onTap, child: inner);

    if (widget.onTap != null) {
      inner = MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: inner,
      );
    }

    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: transitionTileMargin),
        child: inner,
      ),
    );
  }

  bool _isTransitionLine(LyricLine line, bool isMainLine) {
    if (!isMainLine) return false;
    if (line is SyncLyricLine) {
      return line.words.isEmpty && line.length > const Duration(seconds: 3);
    } else if (line is LrcLine) {
      return line.isBlank &&
          line.length > const Duration(seconds: 3) &&
          line.start == Duration.zero;
    }
    return false;
  }
}

class _LocalHoverMask extends StatefulWidget {
  const _LocalHoverMask({required this.child, required this.color, this.onTap});

  final Widget child;
  final Color color;
  final VoidCallback? onTap;

  @override
  State<_LocalHoverMask> createState() => _LocalHoverMaskState();
}

class _LocalHoverMaskState extends State<_LocalHoverMask> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: _hovered && widget.onTap != null ? widget.color : null,
            borderRadius: AppRadius.mdCircular,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
