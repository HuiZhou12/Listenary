import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

/// S5：内部偏好层 → 平台档位层 → 播放参数（D2:A / D10:A / D10b:a）。
///
/// 核心口径：**内部抽象不是展示文案** —— UI 必须用平台自己的 `displayLabel`。
void main() {
  const netease = MusicPlatform.netease;
  const qq = MusicPlatform.qq;

  group('内部偏好 → 平台档位（selectPlatformQuality）', () {
    test('平台未声明档位时原样透传（保持既有行为不变）', () {
      final selection = selectPlatformQuality(
        tiers: const [],
        preference: 'lossless',
      );

      expect(selection.requestValue, 'lossless');
      expect(selection.fellBack, isFalse);
    });

    test('同档位命中：不回落，取值与文案都来自平台声明', () {
      final selection = selectPlatformQuality(
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'standard',
            displayLabel: '标准',
            requestValue: '128',
          ),
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: 'SQ',
            requestValue: 'sq',
          ),
        ],
        preference: 'lossless',
      );

      expect(selection.displayLabel, 'SQ');
      expect(selection.requestValue, 'sq');
      expect(selection.fellBack, isFalse);
    });

    test('平台没有该档位时，落到"不高于期望的最接近档位"并标记回落', () {
      // 平台只有 标准(exhigh? 不) —— 用 standard 与 hires，偏好 lossless：
      // 不高于 lossless 的最近一档是 standard。
      final selection = selectPlatformQuality(
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'standard',
            displayLabel: '标准',
            requestValue: '128',
          ),
          PlatformQualityTier(
            internalLevel: 'hires',
            displayLabel: 'Hi-Res',
            requestValue: 'hires',
          ),
        ],
        preference: 'lossless',
      );

      expect(selection.internalLevel, 'standard');
      expect(selection.displayLabel, '标准');
      expect(selection.fellBack, isTrue);
    });

    test('平台最低档都高于期望时，取最低档并标记回落', () {
      final selection = selectPlatformQuality(
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'hires',
            displayLabel: 'Hi-Res',
            requestValue: 'hires',
          ),
          PlatformQualityTier(
            internalLevel: 'jymaster',
            displayLabel: '母带',
            requestValue: 'jymaster',
          ),
        ],
        preference: 'standard',
      );

      expect(selection.internalLevel, 'hires');
      expect(selection.displayLabel, 'Hi-Res');
      expect(selection.fellBack, isTrue);
    });

    test('偏好键无法识别时也不崩，回落到平台最低档', () {
      final selection = selectPlatformQuality(
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: '无损',
            requestValue: 'lossless',
          ),
          PlatformQualityTier(
            internalLevel: 'hires',
            displayLabel: 'Hi-Res',
            requestValue: 'hires',
          ),
        ],
        preference: 'unknown-level',
      );

      expect(selection.requestValue, 'lossless');
      expect(selection.fellBack, isTrue);
    });
  });

  group('内置 ChkSz 的档位声明必须与今天等价', () {
    test('网易云档位 = MusicQuality 的 7 档，请求值就是内部键', () {
      expect(neteaseQualityTiers, hasLength(MusicQuality.values.length));
      for (var index = 0; index < MusicQuality.values.length; index++) {
        final quality = MusicQuality.values[index];
        final tier = neteaseQualityTiers[index];
        expect(tier.internalLevel, quality.level);
        expect(tier.displayLabel, quality.label);
        expect(tier.requestValue, quality.level, reason: '请求值必须与今天一致');
      }
      // 任意已知偏好在网易云上都不该发生"回落"。
      for (final quality in MusicQuality.values) {
        final selection = selectPlatformQuality(
          tiers: neteaseQualityTiers,
          preference: quality.level,
        );
        expect(selection.requestValue, quality.level);
        expect(selection.fellBack, isFalse);
      }
    });
  });

  group('服务层：按平台解析档位', () {
    CompositeOnlineMusicService serviceWith(List<_QualityProvider> providers) =>
        CompositeOnlineMusicService(
          registry: OnlineMusicProviderRegistry(providers: providers),
        );

    test('平台自己的档位名称与请求值被采用（内部抽象不外泄）', () {
      final provider = _QualityProvider(
        'qqA',
        platform: qq,
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: 'flac',
            requestValue: 'flac',
          ),
        ],
      );
      final service = serviceWith([provider]);

      expect(service.qualityTiersFor(qq).single.displayLabel, 'flac');
      // defaultQualityFor 返回的是**内部偏好档位**（调用方继续当"用户偏好"传递，
      // 真正发给平台的取值由 resolve 按平台声明转换 —— 见 §19.7 缺陷 A）。
      expect(service.defaultQualityFor(qq), 'lossless');
      expect(
        service.selectQualityFor(qq, preference: 'lossless').requestValue,
        'flac',
      );
    });

    test('平台没声明档位时透传，且不伪造档位名称', () {
      final provider = _QualityProvider('neteaseA', platform: netease);
      final service = serviceWith([provider]);

      expect(service.qualityTiersFor(netease), isEmpty);
      expect(service.defaultQualityFor(netease), 'lossless');
    });

    test('该平台没有播放解析候选时不返回任何档位', () {
      final provider = _QualityProvider('qqA', platform: qq);
      final service = serviceWith([provider]);

      expect(service.qualityTiersFor(netease), isEmpty);
    });
  });
}

final class _QualityProvider extends UnsupportedOnlineMusicProvider {
  _QualityProvider(
    this.providerId, {
    required this.platform,
    this.tiers = const [],
  });

  @override
  final String providerId;

  final MusicPlatform platform;
  final List<PlatformQualityTier> tiers;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      capability == OnlineMusicCapability.stream ? {platform} : const {};

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) =>
      platform == this.platform ? tiers : const [];

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async => ResolvedStream(
    ref: ref,
    uri: Uri.parse('https://media.invalid/a.flac'),
    requestedQuality: requestedQuality,
    resolvedAt: DateTime.now(),
  );
}
