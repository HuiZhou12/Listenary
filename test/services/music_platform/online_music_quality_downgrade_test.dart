import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

/// Spec §19.7 **方案 B**：降权提示必须在**平台档位序**上判定。
///
/// 背景缺陷：平台返回的是它自己的取值（QQ = `flac`/`128`/`320`），
/// 旧实现拿内部 `MusicQuality` 枚举下标去查 ⇒ 查到 -1 ⇒ **非网易云平台的降级提示永远不触发**。
void main() {
  /// 网易云档位表的展示文案就是内部档位的中文文案（`neteaseQualityTiers` 的构造决定）。
  String neteaseLabel(String level) => neteaseQualityTiers
      .firstWhere((tier) => tier.internalLevel == level)
      .displayLabel;

  group('QQ（平台档位序）', () {
    test('实际档位低于期望时会提示，且展示平台自己的取值', () {
      final downgrade = resolveQualityDowngrade(
        tiers: qqQualityTiers,
        requested: 'lossless', // flac
        actual: '320', // 低一档
      );

      expect(downgrade, isNotNull, reason: '旧实现这里什么都不提示（下标 -1）');
      expect(downgrade!.displayLabel, '320');
      expect(downgrade.internalLevel, 'exhigh');
    });

    test('实际档位等于期望时不提示', () {
      expect(
        resolveQualityDowngrade(
          tiers: qqQualityTiers,
          requested: 'lossless',
          actual: 'flac',
        ),
        isNull,
      );
    });

    test('期望档该平台没有（hires）时以"实际落点"为基准，不误报', () {
      // QQ 没有 hires ⇒ 服务层本来就发的是 flac，菜单也已提示过"已回落为 flac"，
      // 这里不应再弹一次降权提示。
      expect(
        resolveQualityDowngrade(
          tiers: qqQualityTiers,
          requested: 'hires',
          actual: 'flac',
        ),
        isNull,
      );
    });

    test('认不出的取值不提示（绝不误报）', () {
      expect(
        resolveQualityDowngrade(
          tiers: qqQualityTiers,
          requested: 'lossless',
          actual: 'sq', // 编造/未知取值
        ),
        isNull,
      );
    });

    test('与上一次相同或回升时不重复提示', () {
      expect(
        resolveQualityDowngrade(
          tiers: qqQualityTiers,
          requested: 'lossless',
          actual: '320',
          previousActual: '320',
        ),
        isNull,
        reason: '同一档位重复出现不提示',
      );
      expect(
        resolveQualityDowngrade(
          tiers: qqQualityTiers,
          requested: 'lossless',
          actual: '320',
          previousActual: '128',
        ),
        isNull,
        reason: '从 128 回升到 320 不是降权',
      );
    });

    test('从更高档位掉下来时才提示', () {
      final downgrade = resolveQualityDowngrade(
        tiers: qqQualityTiers,
        requested: 'lossless',
        actual: '128',
        previousActual: 'flac',
      );

      expect(downgrade?.displayLabel, '128');
      expect(downgrade?.internalLevel, 'standard');
    });
  });

  group('网易云（档位声明与内部档位同名）', () {
    test('文案与引入档位模型之前完全一致', () {
      final downgrade = resolveQualityDownGradeNetease();

      expect(downgrade, isNotNull);
      expect(downgrade!.displayLabel, neteaseLabel('exhigh'));
      expect(downgrade.internalLevel, 'exhigh');
    });
  });

  group('平台没有档位声明（声明式透传，保持旧行为）', () {
    test('按内部枚举序判定，展示内部档位的中文文案', () {
      final downgrade = resolveQualityDowngrade(
        tiers: const [],
        requested: 'lossless',
        actual: 'exhigh',
      );

      expect(downgrade, isNotNull);
      expect(downgrade!.displayLabel, neteaseLabel('exhigh'));
      expect(
        musicQualityRank('exhigh'),
        lessThan(musicQualityRank('lossless')),
        reason: '前提：exhigh 确实低于 lossless',
      );
    });

    test('相等 / 认不出时都不提示', () {
      expect(
        resolveQualityDowngrade(
          tiers: const [],
          requested: 'exhigh',
          actual: 'exhigh',
        ),
        isNull,
      );
      expect(
        resolveQualityDowngrade(
          tiers: const [],
          requested: 'lossless',
          actual: 'flac',
        ),
        isNull,
        reason: '内部枚举里没有 flac，认不出就不提示',
      );
    });
  });
}

PlatformQualityDowngrade? resolveQualityDownGradeNetease() =>
    resolveQualityDowngrade(
      tiers: neteaseQualityTiers,
      requested: 'lossless',
      actual: 'exhigh',
    );
