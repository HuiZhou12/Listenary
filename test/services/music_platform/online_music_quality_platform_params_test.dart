import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

/// §19.7 音质缺陷 A + §19.3 QQ 真实档位：
/// **发给平台的一定是平台自己的请求值**（QQ:`flac`），而不是内部偏好键（`lossless`）。
void main() {
  const netease = MusicPlatform.netease;
  const qq = MusicPlatform.qq;

  CompositeOnlineMusicService serviceWith(List<_TierProvider> providers) =>
      CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: providers),
      );

  group('QQ 档位声明（以真实源码为依据，§19.3）', () {
    test('只声明语义明确的 3 档，请求值就是 QQ 自己的取值', () {
      expect(qqQualityTiers.map((tier) => tier.requestValue), [
        '128',
        '320',
        'flac',
      ]);
      expect(qqQualityTiers.map((tier) => tier.displayLabel), [
        '128',
        '320',
        'flac',
      ], reason: '展示名用平台自己的取值');
      expect(qqQualityTiers.map((tier) => tier.internalLevel), [
        'standard',
        'exhigh',
        'lossless',
      ], reason: '内部档位映射是我们的抽象决定');
      // 早先草稿里的 `sq` 是编造的，已作废（§19.3）。
      expect(
        qqQualityTiers.map((tier) => tier.requestValue),
        isNot(contains('sq')),
      );
      // ape / m4a 的真实语义待确认 ⇒ 暂不暴露。
      expect(
        qqQualityTiers.map((tier) => tier.requestValue),
        isNot(contains('ape')),
      );
      expect(
        qqQualityTiers.map((tier) => tier.requestValue),
        isNot(contains('m4a')),
      );
    });
  });

  group('下发前按该 Track 的平台声明转换成平台请求值（缺陷 A）', () {
    test('QQ 曲目：内部偏好 lossless 必须变成 flac', () async {
      final provider = _TierProvider(
        'qqA',
        platform: qq,
        tiers: qqQualityTiers,
      );
      final service = serviceWith([provider]);

      await service.resolve(
        const PlatformTrackRef(platform: qq, trackId: '0039MnYb0qxYhV'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(provider.requestedQualities, ['flac']);
      expect(provider.lastRequestedQuality, isNot('lossless'));
    });

    test('QQ 曲目：exhigh → 320、standard → 128', () async {
      final provider = _TierProvider(
        'qqA',
        platform: qq,
        tiers: qqQualityTiers,
      );
      final service = serviceWith([provider]);

      for (final entry in {'exhigh': '320', 'standard': '128'}.entries) {
        await service.resolve(
          const PlatformTrackRef(platform: qq, trackId: 'x'),
          requestedQuality: entry.key,
          cancelToken: OnlineMusicCancelToken(),
        );
      }

      expect(provider.requestedQualities, ['320', '128']);
    });

    test('QQ 没有该档位时落到"不高于期望的最接近档"（仍发平台取值）', () async {
      final provider = _TierProvider(
        'qqA',
        platform: qq,
        tiers: qqQualityTiers,
      );
      final service = serviceWith([provider]);

      // 母带/沉浸声/全景声 QQ 都没有：不高于 hires 的最近一档是 flac(lossless)。
      await service.resolve(
        const PlatformTrackRef(platform: qq, trackId: 'x'),
        requestedQuality: 'jymaster',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(provider.requestedQualities, ['flac']);
    });

    test('网易云：内部键 == 请求值，既有行为零变化', () async {
      final provider = _TierProvider(
        'neteaseA',
        platform: netease,
        tiers: neteaseQualityTiers,
      );
      final service = serviceWith([provider]);

      for (final quality in MusicQuality.values) {
        await service.resolve(
          const PlatformTrackRef(platform: netease, trackId: 'x'),
          requestedQuality: quality.level,
          cancelToken: OnlineMusicCancelToken(),
        );
      }

      expect(provider.requestedQualities, [
        for (final quality in MusicQuality.values) quality.level,
      ]);
    });

    test('平台没有档位声明时原样透传（自建声明式 Provider 的既有行为）', () async {
      final provider = _TierProvider('self', platform: qq);
      final service = serviceWith([provider]);

      await service.resolve(
        const PlatformTrackRef(platform: qq, trackId: 'x'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(provider.requestedQualities, ['lossless']);
    });

    test('切歌按新 Track 的平台重新解析，不沿用上一首的平台参数', () async {
      final neteaseProvider = _TierProvider(
        'neteaseA',
        platform: netease,
        tiers: neteaseQualityTiers,
      );
      final qqProvider = _TierProvider(
        'qqA',
        platform: qq,
        tiers: qqQualityTiers,
      );
      final service = serviceWith([neteaseProvider, qqProvider]);

      // 第一首：网易云。
      await service.resolve(
        const PlatformTrackRef(platform: netease, trackId: 'n1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );
      // 第二首：切到 QQ，同一内部偏好必须重新按 QQ 的声明解析。
      await service.resolve(
        const PlatformTrackRef(platform: qq, trackId: 'q1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(neteaseProvider.requestedQualities, ['lossless']);
      expect(qqProvider.requestedQualities, ['flac']);
    });
  });

  group('defaultQualityFor 返回内部偏好档位（不再提前转换）', () {
    test('QQ：返回内部档位，平台取值由 resolve 转换', () {
      final provider = _TierProvider(
        'qqA',
        platform: qq,
        tiers: qqQualityTiers,
      );
      final service = serviceWith([provider]);

      // Provider 报的内部偏好是 lossless ⇒ 服务层同样返回内部档位。
      expect(service.defaultQualityFor(qq), 'lossless');
      // 真正发给平台的取值仍由档位解析决定。
      expect(
        service.selectQualityFor(qq, preference: 'lossless').requestValue,
        'flac',
      );
    });

    test('网易云：内部档位与平台取值一致（默认配置行为不变）', () {
      final provider = _TierProvider(
        'neteaseA',
        platform: netease,
        tiers: neteaseQualityTiers,
      );
      final service = serviceWith([provider]);

      expect(service.defaultQualityFor(netease), 'lossless');
    });
  });
}

final class _TierProvider extends UnsupportedOnlineMusicProvider {
  @override
  Future<List<OnlineArtistSummary>> fetchFollowedArtists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Followed artists are not implemented here');

  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended playlists are not implemented here');

  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

  _TierProvider(
    this.providerId, {
    required this.platform,
    this.tiers = const [],
  });

  @override
  final String providerId;

  final MusicPlatform platform;
  final List<PlatformQualityTier> tiers;

  final List<String> requestedQualities = [];

  String? get lastRequestedQuality =>
      requestedQualities.isEmpty ? null : requestedQualities.last;

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
  }) async {
    requestedQualities.add(requestedQuality);
    return ResolvedStream(
      ref: ref,
      uri: Uri.parse('https://media.invalid/a.bin'),
      requestedQuality: requestedQuality,
      resolvedAt: DateTime.utc(2026, 10, 7),
    );
  }
}
