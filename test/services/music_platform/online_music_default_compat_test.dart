import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// S9：**默认配置的兼容回归**。
///
/// 用户确认的兼容口径是"**默认配置下对外可观察行为与现有版本保持兼容**"
/// （不是逐字节一致）。本文件在**配置与路由层**把这句话变成断言：
/// 默认条目仍是单个内置 chksz、四个能力仍是内置、落盘结构不新增键、
/// 单条目的路由结果与改造前完全一致。
void main() {
  const netease = MusicPlatform.netease;

  test('默认配置：单个内置 chksz 条目，四个能力都是内置实现', () {
    const settings = OnlineMusicSettings.defaults;

    expect(settings.providers, hasLength(1));
    final definition = settings.providers.single;
    expect(definition.id, defaultOnlineMusicProviderId);
    expect(definition.contentPlatform, netease);
    for (final capability in OnlineMusicCapability.values) {
      expect(
        definition.bindingFor(capability),
        isA<OnlineMusicBuiltinCapabilityBinding>(),
        reason: '${capability.name} 在默认配置下必须仍是内置实现',
      );
    }
  });

  test('默认配置落盘结构不新增键（D13:A：不迁移、不改写用户文件）', () {
    final json = OnlineMusicSettings.defaults.toJson();

    expect(json.containsKey('routing'), isFalse, reason: '空 routing 不写盘');
    expect(
      json.containsKey('capabilities'),
      isTrue,
      reason: '旧的 capabilities 键仍然照写，旧版本可继续读',
    );
    expect(json['defaultProvider'], defaultOnlineMusicProviderId);
  });

  test('旧配置读取后不产生显式候选，路由完全由"单条目"推导', () {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {'id': 'chksz', 'protocol': 'chksz'},
      ],
    });

    for (final capability in OnlineMusicCapability.values) {
      expect(
        settings.explicitCandidateIdsFor(netease, capability),
        isEmpty,
        reason: '${capability.name} 没有显式候选 → 由注册顺序推导',
      );
    }
  });

  test('单条目路由结果与改造前一致：四能力都命中同一个 Provider', () {
    // 用"声明支持四能力的单条目"代表内置 chksz 条目（这里不需要真实运行时）。
    final chkszLike = _AllCapabilityProvider('chksz', netease);
    final registry = OnlineMusicProviderRegistry(
      providers: [chkszLike],
      explicitCandidates: OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'chksz', 'protocol': 'chksz'},
        ],
      }).explicitCandidateIdsFor,
    );

    for (final capability in OnlineMusicCapability.values) {
      expect(
        registry.providersFor(netease, capability).map((p) => p.providerId),
        ['chksz'],
        reason: '${capability.name} 必须仍然只走这一个条目',
      );
    }
  });

  test('未被任何条目服务的平台不可用，且不静默回落（D14）', () {
    final registry = OnlineMusicProviderRegistry(
      providers: [_AllCapabilityProvider('chksz', netease)],
      defaultProviderId: 'chksz',
    );

    for (final platform in [MusicPlatform.qq, MusicPlatform.kugou]) {
      for (final capability in OnlineMusicCapability.values) {
        expect(
          registry.providersFor(platform, capability),
          isEmpty,
          reason: '${platform.name} 没有 Provider 时必须为空，而不是回落到 netease 的条目',
        );
      }
    }
  });
}

final class _AllCapabilityProvider extends UnsupportedOnlineMusicProvider {
  _AllCapabilityProvider(this.providerId, this.platform);

  @override
  final String providerId;

  final MusicPlatform platform;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) => {
    platform,
  };
}
