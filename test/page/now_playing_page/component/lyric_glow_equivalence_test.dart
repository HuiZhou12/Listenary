import 'dart:ui' show PictureRecorder;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/lyric_render_config.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_painter.dart';

/// Spec §7.2：辉光视觉强度的等价性钉死断言（D2）。
///
/// **像素级不做自动断言**（仓库无 golden 基础设施，`MaskFilter.blur` 的光栅
/// 结果随 Skia/GPU 变化）—— 像素等价由人工 M8 签认。这里只钉死参数与曲线。
void main() {
  group('E1 lyricGlowSigma 钉死 sigma 公式与 clamp（D2）', () {
    test('near sigma 系数 0.08/0.02，clamp 到 2.5–5.0', () {
      for (final fontSize in <double>[16, 24, 32, 48]) {
        for (final strength in <double>[0, 0.5, 1]) {
          final sigma = lyricGlowNearSigma(
            fontSize: fontSize,
            strength: strength,
          );
          final raw = fontSize * (0.08 + 0.02 * strength);
          expect(sigma, closeTo(raw.clamp(2.5, 5.0), 1e-9));
          expect(sigma, greaterThanOrEqualTo(2.5));
          expect(sigma, lessThanOrEqualTo(5.0));
        }
      }
    });

    test('far sigma 系数 0.22/0.05，clamp 到 7.0–12.0', () {
      for (final fontSize in <double>[16, 24, 32, 48]) {
        for (final strength in <double>[0, 0.5, 1]) {
          final sigma = lyricGlowFarSigma(
            fontSize: fontSize,
            strength: strength,
          );
          final raw = fontSize * (0.22 + 0.05 * strength);
          expect(sigma, closeTo(raw.clamp(7.0, 12.0), 1e-9));
          expect(sigma, greaterThanOrEqualTo(7.0));
          expect(sigma, lessThanOrEqualTo(12.0));
        }
      }
    });

    test('golden 表：关键组合与改动前的内联表达式逐值相等', () {
      // 这些值由改动前的 `(fontSize * (0.08 + 0.02 * strength)).clamp(2.5,5.0)`
      // 与 `(fontSize * (0.22 + 0.05 * strength)).clamp(7.0,12.0)` 直接算出。
      const nearGolden = <String, double>{
        '16|0': 2.5, // 1.28 → clamp 2.5
        '16|0.5': 2.5, // 1.44 → clamp 2.5
        '16|1': 2.5, // 1.6 → clamp 2.5
        '24|0': 2.5, // 1.92 → clamp 2.5
        '32|0': 2.56, // 32*0.08
        '32|0.5': 2.88, // 32*0.09
        '32|1': 3.2, // 32*0.10
        '48|0': 3.84, // 48*0.08
        '48|0.5': 4.32, // 48*0.09
        '48|1': 4.8, // 48*0.10
      };
      const farGolden = <String, double>{
        '16|0': 7.0, // 3.52 → clamp 7.0
        '16|1': 7.0, // 4.32 → clamp 7.0
        '24|0': 7.0, // 5.28 → clamp 7.0
        '32|0': 7.04, // 32*0.22
        '32|0.5': 7.84, // 32*0.245
        '32|1': 8.64, // 32*0.27
        '48|0': 10.56, // 48*0.22
        '48|0.5': 11.76, // 48*0.245
        '48|1': 12.0, // 12.96 → clamp 12.0
      };
      nearGolden.forEach((key, expected) {
        final parts = key.split('|');
        expect(
          lyricGlowNearSigma(
            fontSize: double.parse(parts[0]),
            strength: double.parse(parts[1]),
          ),
          closeTo(expected, 1e-9),
          reason: 'near $key',
        );
      });
      farGolden.forEach((key, expected) {
        final parts = key.split('|');
        expect(
          lyricGlowFarSigma(
            fontSize: double.parse(parts[0]),
            strength: double.parse(parts[1]),
          ),
          closeTo(expected, 1e-9),
          reason: 'far $key',
        );
      });
    });
  });

  group('E2 lyricGlowAlpha 钉死强度（D2）', () {
    test('glowAlpha = 0.30 + 0.14 * strength', () {
      expect(lyricGlowAlpha(0), closeTo(0.30, 1e-12));
      expect(lyricGlowAlpha(0.5), closeTo(0.37, 1e-12));
      expect(lyricGlowAlpha(1), closeTo(0.44, 1e-12));
    });

    test('远层系数固定 0.55', () {
      expect(lyricGlowFarAlphaFactor, 0.55);
    });
  });

  group('E3 光层数量与混合模式（防悄悄减成 1 层）', () {
    test('固定 2 层、BlendMode.screen', () {
      expect(lyricGlowLayerCount, 2);
      expect(lyricGlowBlendMode, BlendMode.screen);
    });
  });

  group('E4 lyricCharacterScale 101 点 golden 曲线（D2 峰值不动）', () {
    test('scaleAndGlow 峰值 1.26（strength=1）逐点对齐', () {
      const duration = Duration(milliseconds: 2200);
      const median = Duration(milliseconds: 500);
      // strength = max(absolute, relative)
      //   absolute = ((2200-750)/1750).clamp = 0.8285714286
      //   relative = ((2200/500 - 1.8)/1.7).clamp = 1.0 ⇒ strength = 1.0
      // maxScale = 1.15 + 0.11*1.0 = 1.26
      const maxScale = 1.26;
      for (var i = 0; i <= 100; i++) {
        final progress = i / 100.0;
        final expected = progress <= 0.0 || progress >= 1.0
            ? 1.0
            : 1.0 + (maxScale - 1.0) * 4.0 * progress * (1.0 - progress);
        expect(
          lyricCharacterScale(
            effect: LyricWordEffect.scaleAndGlow,
            duration: duration,
            lineMedianDuration: median,
            progress: progress,
          ),
          closeTo(expected, 1e-9),
          reason: 'progress=$progress',
        );
      }
    });

    test('scale 峰值 1.20（strength=1）逐点对齐', () {
      const duration = Duration(milliseconds: 2200);
      const median = Duration(milliseconds: 500);
      const maxScale = 1.20; // 1.12 + 0.08*1.0
      for (var i = 0; i <= 100; i++) {
        final progress = i / 100.0;
        final expected = progress <= 0.0 || progress >= 1.0
            ? 1.0
            : 1.0 + (maxScale - 1.0) * 4.0 * progress * (1.0 - progress);
        expect(
          lyricCharacterScale(
            effect: LyricWordEffect.scale,
            duration: duration,
            lineMedianDuration: median,
            progress: progress,
          ),
          closeTo(expected, 1e-9),
          reason: 'progress=$progress',
        );
      }
    });

    test('峰值区间仍落在 1.15–1.26（D2 原文）', () {
      final peak = lyricCharacterScale(
        effect: LyricWordEffect.scaleAndGlow,
        duration: const Duration(milliseconds: 2200),
        lineMedianDuration: const Duration(milliseconds: 500),
        progress: 0.5,
      );
      expect(peak, closeTo(1.26, 1e-9));
      expect(peak, greaterThanOrEqualTo(1.15));
      expect(peak, lessThanOrEqualTo(1.26));
    });
  });

  group('E7 alignBaseline 亚像素对齐边界（仅 y，dpr 量化）', () {
    test('误差 ≤ 1/dpr 且单调不减', () {
      for (final dpr in <double>[1.0, 1.25, 1.5, 2.0]) {
        var previous = double.negativeInfinity;
        for (var i = 0; i <= 400; i++) {
          final y = i * 0.25;
          final aligned = alignBaseline(y, dpr);
          expect(
            (aligned - y).abs(),
            lessThanOrEqualTo(1.0 / dpr + 1e-9),
            reason: 'dpr=$dpr y=$y',
          );
          expect(
            aligned,
            greaterThanOrEqualTo(previous - 1e-9),
            reason: 'dpr=$dpr y=$y 必须单调不减',
          );
          previous = aligned;
        }
      }
    });

    test('非法 dpr 原样返回（不抛错）', () {
      expect(alignBaseline(12.345, 0), 12.345);
      expect(alignBaseline(12.345, -1), 12.345);
      expect(alignBaseline(12.345, double.nan), 12.345);
    });

    test('dpr=2 时落在整像素上', () {
      expect(alignBaseline(10.3, 2.0), 10.5);
      expect(alignBaseline(10.6, 2.0), 10.5);
      expect(alignBaseline(10.8, 2.0), 11.0);
    });
  });

  group('E5 measureHeight 换行/行高不变（D6 统一逐字不改变换行）', () {
    late LyricsLinePainter painter;

    LyricsLinePainter build(SyncLyricLine line, double fontSize) {
      final config = LyricRenderConfig(
        textAlign: LyricTextAlign.left,
        baseFontSize: fontSize,
        translationBaseFontSize: fontSize * 0.85,
        showTranslation: true,
        showRoman: true,
        fontWeight: 700,
        enableBlur: false,
      );
      return LyricsLinePainter(
        line: line,
        currentTimeMs: 0,
        blurSigma: 0,
        config: config,
        scheme: const ColorScheme.dark(),
        isMainLine: true,
        useMaterialYouColor: false,
        lineMedianWordDuration: lyricMedianWordDuration(line.words),
      );
    }

    setUp(() {
      LyricsLinePainter.clearPool();
      painter = build(
        SyncLyricLine(
          Duration.zero,
          const Duration(seconds: 4),
          <SyncLyricWord>[
            SyncLyricWord(
              Duration.zero,
              const Duration(milliseconds: 500),
              'Hello ',
            ),
            SyncLyricWord(
              const Duration(milliseconds: 500),
              const Duration(milliseconds: 500),
              'world ',
            ),
            SyncLyricWord(
              const Duration(milliseconds: 1000),
              const Duration(milliseconds: 3000),
              'listen',
            ),
          ],
          '你好世界',
          'Ni hao shi jie',
        )..translation = '这是一句很长的翻译文本用来触发换行测试',
        32,
      );
    });

    test('同一 fixture 的 measureHeight 是确定值（可回归对比基线）', () {
      final first = painter.measureHeight(600);
      final second = painter.measureHeight(600);
      expect(second, closeTo(first, 1e-9));
      expect(first, greaterThan(0));
    });

    test('行高随可用宽度单调不减（换行逻辑未被改动）', () {
      final narrow = painter.measureHeight(120);
      final wide = painter.measureHeight(2000);
      expect(narrow, greaterThanOrEqualTo(wide));
    });

    test('和声因子参数只缩放和声块，不影响主行高', () {
      final noBg = painter.measureHeight(
        600,
        reserveBackgroundVocalHeight: false,
      );
      final factorZero = painter.measureHeight(
        600,
        reserveBackgroundVocalHeight: true,
        backgroundVocalHeightFactor: 0.0,
      );
      expect(factorZero, closeTo(noBg, 1e-9));
    });
  });

  group('E6 段落缓存正确性（防把旧色烘进缓存，R1）', () {
    setUp(() => LyricsLinePainter.clearPool());

    /// 用真实的 paint 路径连续绘制两帧，借 layout 次数/命中次数断言缓存行为。
    void paintOnce(LyricsLinePainter painter, ColorScheme scheme) {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, const Size(600, 200));
      recorder.endRecording();
    }

    LyricsLinePainter buildLinePainter({
      required SyncLyricLine line,
      required double opacity,
      required ColorScheme scheme,
    }) {
      return LyricsLinePainter(
        line: line,
        currentTimeMs: 2500,
        blurSigma: 0,
        config: const LyricRenderConfig(
          textAlign: LyricTextAlign.left,
          baseFontSize: 24,
          translationBaseFontSize: 20,
          showTranslation: false,
          showRoman: false,
          fontWeight: 700,
          enableBlur: false,
        ),
        scheme: scheme,
        isMainLine: true,
        isHighlightActive: false,
        opacity: opacity,
        lineMedianWordDuration: const Duration(milliseconds: 500),
      );
    }

    test('同 (char, style) 连续取两次 ⇒ 第二次命中且不再 layout', () {
      final line = SyncLyricLine(
        Duration.zero,
        const Duration(seconds: 4),
        <SyncLyricWord>[
          SyncLyricWord(
            Duration.zero,
            const Duration(milliseconds: 4000),
            'ab',
          ),
        ],
        'ab',
      );
      const scheme = ColorScheme.dark();
      final painter = buildLinePainter(
        line: line,
        opacity: 1.0,
        scheme: scheme,
      );
      paintOnce(painter, scheme);
      final layoutsAfterFirst = LyricsLinePainter.paragraphLayoutCount;
      paintOnce(painter, scheme);
      final layoutsAfterSecond = LyricsLinePainter.paragraphLayoutCount;
      expect(
        LyricsLinePainter.paragraphCacheHitCount,
        greaterThan(0),
        reason: '第二帧必须命中段落缓存',
      );
      expect(
        layoutsAfterSecond,
        layoutsAfterFirst,
        reason: '命中后不得再新增 layout',
      );
    });

    test('改变颜色（opacity）后必须重新 layout，不得复用旧色段落', () {
      final line = SyncLyricLine(
        Duration.zero,
        const Duration(seconds: 4),
        <SyncLyricWord>[
          SyncLyricWord(
            Duration.zero,
            const Duration(milliseconds: 4000),
            'ab',
          ),
        ],
        'ab',
      );
      const scheme = ColorScheme.dark();
      final opaque = buildLinePainter(
        line: line,
        opacity: 1.0,
        scheme: scheme,
      );
      paintOnce(opaque, scheme);
      final layoutsBefore = LyricsLinePainter.paragraphLayoutCount;
      final translucent = buildLinePainter(
        line: line,
        opacity: 0.42,
        scheme: scheme,
      );
      paintOnce(translucent, scheme);
      expect(
        LyricsLinePainter.paragraphLayoutCount,
        greaterThan(layoutsBefore),
        reason: 'opacity 变化 ⇒ 颜色变化 ⇒ 必须重新 layout',
      );
    });

    test('clearPool 释放段落缓存，不泄漏', () {
      final line = SyncLyricLine(
        Duration.zero,
        const Duration(seconds: 4),
        <SyncLyricWord>[
          SyncLyricWord(
            Duration.zero,
            const Duration(milliseconds: 4000),
            'ab',
          ),
        ],
        'ab',
      );
      const scheme = ColorScheme.dark();
      paintOnce(
        buildLinePainter(line: line, opacity: 1.0, scheme: scheme),
        scheme,
      );
      expect(LyricsLinePainter.paragraphCacheSize, greaterThan(0));
      LyricsLinePainter.clearPool();
      expect(LyricsLinePainter.paragraphCacheSize, 0);
    });
  });
}
