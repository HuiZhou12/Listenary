import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';

/// Spec §7.3：帧/数据解耦（D1-1/D1-2/D1-3）、回读平滑（D2-1/D2-2）、
/// 在线外推（D3-1）、D5 布局高度恒定（D4-1）。
///
/// 这些断言尽量只通过**公开可观察量**表达（Widget 树里的 `SizedBox.height`、
/// `OverflowBox` 的 `paintHeight`、painter 收到的 progress notifier 值），
/// 不依赖私有字段名，避免把测试钉在实现细节上。
void main() {
  SyncLyricLine buildLine() {
    return SyncLyricLine(
      Duration.zero,
      const Duration(seconds: 4),
      <SyncLyricWord>[
        SyncLyricWord(Duration.zero, const Duration(milliseconds: 900), 'Hello '),
        SyncLyricWord(
          const Duration(milliseconds: 900),
          const Duration(milliseconds: 1800),
          'world ',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 2700),
          const Duration(milliseconds: 1300),
          'end',
        ),
      ],
      '你好世界',
      'Ni hao shi jie',
    );
  }

  Widget host(Widget child) {
    return ChangeNotifierProvider<LyricViewController>.value(
      value: LyricViewController.instance,
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 600, height: 400, child: child),
        ),
      ),
    );
  }

  setUp(() {
    _resetPainterCaches();
    // 注入测试缝：不初始化 play_service / BASS（测试进程没有音频设备）。
    LyricsLineWidget.debugIsPlayingOverride = () => true;
    LyricsLineWidget.debugPositionOverride = () => 0.0;
    // 让 renderConfig 稳定：显式写入尺寸/显示模式。
    final controller = LyricViewController.instance;
    controller.lyricFontSize = 24;
    controller.translationFontSize = 20;
    controller.showLyricTranslation = true;
    controller.showLyricRoman = false;
    controller.enableLyricGlow = false;
    controller.lyricTextAlign = LyricTextAlign.left;
    controller.rubyPosition = RubyPosition.below;
  });

  tearDown(() {
    LyricsLineWidget.debugIsPlayingOverride = null;
    LyricsLineWidget.debugPositionOverride = null;
  });

  testWidgets('D1-1 渲染节拍跟随 vsync：一帧一次渲染通知（节流前 ≤ N/2）', (
    tester,
  ) async {
    // 模拟播放中的原生位置：随测试时钟推进，让 ticker 每帧都能推进进度。
    var fakePositionMs = 0.0;
    LyricsLineWidget.debugPositionOverride = () => fakePositionMs;

    final line = buildLine();
    await tester.pumpWidget(
      host(
        LyricsLineWidget(
          line: line,
          opacity: 1.0,
          distance: 0,
          positionMs: 0,
          isHighlightActive: true,
        ),
      ),
    );

    final painter =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(LyricsLineWidget),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as dynamic;
    expect(
      painter.currentTimeListenable,
      isNotNull,
      reason: '活动行必须挂上每帧进度 notifier',
    );

    var notifications = 0;
    void listener() => notifications++;
    painter.currentTimeListenable.addListener(listener);
    addTearDown(() => painter.currentTimeListenable.removeListener(listener));

    // 60 Hz：推进 12 帧（≈200 ms）。老实现按 33 ms 节流 ⇒ 最多 6 次。
    const frames = 12;
    for (var i = 0; i < frames; i++) {
      fakePositionMs += 16.0;
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      notifications,
      greaterThanOrEqualTo(frames - 2),
      reason: '渲染通知应跟随 vsync（≈每帧一次），实际 $notifications / $frames',
    );
  });

  group('D2-1 / D2-2 1 s 回读阶跃平滑（§5.2.2）', () {
    test('单帧吸收量有上限，且在 150 ms 窗口内收敛', () {
      const correction = 20.0; // 注入"插值落后 20 ms 的回读"
      var residual = correction;
      var frames = 0;

      // 第一帧：吸收量必须小于全部纠正量（否则就不是"分摊"）。
      final firstAbsorbed = absorbLyricNativeCorrection(
        residualMs: residual,
        scheduledMs: correction,
        flush: false,
      );
      expect(
        firstAbsorbed,
        lessThan(correction),
        reason: '单帧不得一次吞掉全部纠正量',
      );
      expect(firstAbsorbed, greaterThan(0));
      residual -= firstAbsorbed;

      // 60 Hz 推进：150 ms ≈ 9 帧内必须收敛。
      while (residual.abs() > 0.01 && frames < 60) {
        residual -= absorbLyricNativeCorrection(
          residualMs: residual,
          scheduledMs: correction,
          flush: false,
        );
        frames++;
      }
      expect(
        frames,
        lessThanOrEqualTo(10),
        reason: '应在 150 ms（≈9 帧）内收敛，实际 $frames 帧',
      );
      expect(residual.abs(), lessThanOrEqualTo(0.01));
    });

    test('单帧吸收量不超过残余量（不会过冲）', () {
      for (final residual in <double>[0.5, 5, 20, 31.9, -0.5, -20]) {
        final absorbed = absorbLyricNativeCorrection(
          residualMs: residual,
          scheduledMs: residual,
          flush: false,
        );
        expect(
          absorbed.abs(),
          lessThanOrEqualTo(residual.abs() + 1e-12),
          reason: 'residual=$residual',
        );
        expect(absorbed.sign, residual.sign, reason: '方向必须一致');
      }
    });

    test('flush（行尾前 200 ms / pending seek）一次性吸收全部残余', () {
      expect(
        absorbLyricNativeCorrection(
          residualMs: 20.0,
          scheduledMs: 20.0,
          flush: true,
        ),
        closeTo(20.0, 1e-12),
      );
      expect(
        absorbLyricNativeCorrection(
          residualMs: 31.5,
          scheduledMs: 31.5,
          flush: true,
        ),
        closeTo(31.5, 1e-12),
      );
    });

    test('零残余不产生推进', () {
      expect(
        absorbLyricNativeCorrection(
          residualMs: 0.0,
          scheduledMs: 0.0,
          flush: false,
        ),
        0.0,
      );
      expect(
        absorbLyricNativeCorrection(
          residualMs: 0.0,
          scheduledMs: 0.0,
          flush: true,
        ),
        0.0,
      );
    });

    test('平滑上限常量符合 Spec（32 ms 门槛 / 150 ms 窗口 / 200 ms 行尾对齐）', () {
      expect(lyricNativeCorrectionMaxMs, 32.0);
      expect(lyricNativeCorrectionWindowMs, 150.0);
      expect(lyricNativeCorrectionFlushLeadMs, 200.0);
    });

    test('D2-2 纠正量 ≥ 100 ms 仍走 seek 分支（不被平滑吞掉）', () {
      // seek 门槛（100 ms）必须严格大于平滑门槛（32 ms），
      // 否则大跳转会被误判成"可平滑的回读误差"。
      const seekThreshold = 100.0;
      expect(lyricNativeCorrectionMaxMs, lessThan(seekThreshold));
    });
  });

  testWidgets('D1-3 非活动行不因渲染节拍被重绘', (tester) async {
    final line = buildLine();
    await tester.pumpWidget(
      host(
        LyricsLineWidget(
          line: line,
          opacity: 0.5,
          distance: 5,
          positionMs: 0,
          isHighlightActive: false,
        ),
      ),
    );
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(LyricsLineWidget),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    expect(
      (painter as dynamic).currentTimeListenable,
      isNull,
      reason: '非活动行不得挂每帧进度 notifier（否则会放大重绘量，R8）',
    );
  });

  testWidgets('D4-1 和声行入场期间布局高度恒定、绘制高度生长', (tester) async {
    final line = buildLine()
      ..bgText = 'Stay close'
      ..bgWords = <SyncLyricWord>[
        SyncLyricWord(
          const Duration(milliseconds: 500),
          const Duration(milliseconds: 900),
          'Stay ',
        ),
        SyncLyricWord(
          const Duration(milliseconds: 1400),
          const Duration(milliseconds: 1300),
          'close',
        ),
      ]
      ..bgStart = const Duration(milliseconds: 500)
      ..bgEnd = const Duration(milliseconds: 3200);

    final bgVisibility = ValueNotifier<double>(0.0);
    addTearDown(bgVisibility.dispose);

    await tester.pumpWidget(
      host(
        LyricsLineWidget(
          line: line,
          opacity: 1.0,
          distance: 0,
          positionMs: 0,
          isHighlightActive: true,
          reserveBackgroundVocalHeight: true,
          backgroundVocalVisibilityListenable: bgVisibility,
        ),
      ),
    );
    await tester.pump();

    double layoutHeight() => tester
        .widget<SizedBox>(
          find
              .ancestor(
                of: find.byType(OverflowBox),
                matching: find.byType(SizedBox),
              )
              .first,
        )
        .height!;

    double paintHeight() =>
        tester.widget<OverflowBox>(find.byType(OverflowBox)).maxHeight!;

    final layoutAtStart = layoutHeight();
    final paintAtStart = paintHeight();

    for (final factor in <double>[0.15, 0.4, 0.7, 0.95]) {
      bgVisibility.value = factor;
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        layoutHeight(),
        closeTo(layoutAtStart, 0.01),
        reason: 'D5：布局高度必须恒定（下方行不下移），factor=$factor',
      );
      expect(
        paintHeight(),
        greaterThanOrEqualTo(paintAtStart - 1e-9),
        reason: 'D5：绘制高度单调不减，factor=$factor',
      );
    }

    bgVisibility.value = 1.0;
    await tester.pump(const Duration(milliseconds: 16));
    expect(layoutHeight(), closeTo(layoutAtStart, 0.01));
    expect(
      paintHeight(),
      greaterThan(paintAtStart),
      reason: 'D5：绘制高度在入场期间增长到终点',
    );
  });

  testWidgets('D3-1 在线模式外推：50 ms 快照之间渲染值单调递增且不超 anchor+75ms', (
    tester,
  ) async {
    final line = buildLine();
    Widget build(double positionMs) => host(
      LyricsLineWidget(
        line: line,
        opacity: 1.0,
        distance: 0,
        positionMs: positionMs,
        usesExternalPosition: true,
        isHighlightActive: true,
      ),
    );

    await tester.pumpWidget(build(1000));
    await tester.pump();

    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(LyricsLineWidget),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter!;
    final listenable = (painter as dynamic).currentTimeListenable;
    expect(listenable, isNotNull, reason: '在线高亮行需要外推进度');

    final observed = <double>[];
    void listener() => observed.add((listenable as dynamic).value as double);
    // ignore: avoid_dynamic_calls
    (listenable as dynamic).addListener(listener);
    addTearDown(() {
      // ignore: avoid_dynamic_calls
      (listenable as dynamic).removeListener(listener);
    });

    // 两个 50 ms 快照之间推进 3 帧（≈48 ms）。
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(observed, isNotEmpty, reason: '外推必须产生渲染通知');
    for (var i = 1; i < observed.length; i++) {
      expect(
        observed[i],
        greaterThanOrEqualTo(observed[i - 1] - 1e-9),
        reason: '外推值必须单调递增',
      );
    }
    expect(
      observed.last,
      lessThanOrEqualTo(1000 + 75.0 + 1e-6),
      reason: '外推上限 75 ms（1.5 × 50 ms 快照间隔）',
    );

    // 新快照到来后残差应 ≤ 1 帧（≈16.7 ms 内被纠正）。
    await tester.pumpWidget(build(1050));
    await tester.pump();
    expect(
      (listenable as dynamic).value as double,
      closeTo(1050, 20.0),
      reason: '新快照后残差应 ≤ 1 帧',
    );
  });
}

/// 测试之间重置 painter 的静态缓存族（避免跨用例污染 layout 计数）。
void _resetPainterCaches() => LyricsLinePainter.clearPool();
