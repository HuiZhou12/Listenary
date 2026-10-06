import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// 路由层的平台感知候选解析（S1）。
///
/// `providerFor` 保持旧的平台无关单值语义；`providersFor` 是新增的
/// `(platform, capability)` 有序候选，且**不做**平台无关的默认回落（D14）。
void main() {
  _FakeProvider provider(
    String id,
    Map<OnlineMusicCapability, Set<MusicPlatform>> platforms,
  ) => _FakeProvider(id, platforms);

  final neteaseOnly = <OnlineMusicCapability, Set<MusicPlatform>>{
    OnlineMusicCapability.search: {MusicPlatform.netease},
    OnlineMusicCapability.stream: {MusicPlatform.netease},
  };
  final qqOnly = <OnlineMusicCapability, Set<MusicPlatform>>{
    OnlineMusicCapability.search: {MusicPlatform.qq},
    OnlineMusicCapability.stream: {MusicPlatform.qq},
  };

  group('providersFor（平台感知候选）', () {
    test('只返回声明支持该平台 + 该能力的 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [provider('neteaseA', neteaseOnly), provider('qqA', qqOnly)],
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['neteaseA'],
      );
      expect(
        registry
            .providersFor(MusicPlatform.qq, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['qqA'],
      );
    });

    test('显式配置的 Provider 排第一，其余按注册顺序补齐', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          provider('neteaseA', neteaseOnly),
          provider('neteaseB', neteaseOnly),
          provider('neteaseC', neteaseOnly),
        ],
        capabilityProviders: {OnlineMusicCapability.search: 'neteaseC'},
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['neteaseC', 'neteaseA', 'neteaseB'],
      );
    });

    test('显式配置指向不支持该平台的 Provider 时，它被排除', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [provider('neteaseA', neteaseOnly), provider('qqA', qqOnly)],
        // 把能力显式指向 qq 的 Provider，但查询的是 netease。
        capabilityProviders: {OnlineMusicCapability.search: 'qqA'},
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.search)
            .map((it) => it.providerId),
        ['neteaseA'],
      );
    });

    test('该平台没有任何 Provider 时返回空列表，不回落到默认 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [provider('neteaseA', neteaseOnly)],
        defaultProviderId: 'neteaseA',
      );

      expect(
        registry.providersFor(
          MusicPlatform.kugou,
          OnlineMusicCapability.search,
        ),
        isEmpty,
      );
      expect(
        registry.providersFor(
          MusicPlatform.netease,
          OnlineMusicCapability.lyric,
        ),
        isEmpty,
      );
    });

    test('能力不分平台时，候选只包含真正声明了该能力的 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          provider('withLyric', {
            ...neteaseOnly,
            OnlineMusicCapability.lyric: {MusicPlatform.netease},
          }),
          provider('withoutLyric', neteaseOnly),
        ],
      );

      expect(
        registry
            .providersFor(MusicPlatform.netease, OnlineMusicCapability.lyric)
            .map((it) => it.providerId),
        ['withLyric'],
      );
    });
  });

  group('providerFor（旧语义保持不变）', () {
    test('指向未注册 Provider 时仍回落默认 Provider', () {
      final registry = OnlineMusicProviderRegistry(
        providers: [
          provider('neteaseA', neteaseOnly),
          provider('neteaseB', neteaseOnly),
        ],
        defaultProviderId: 'neteaseB',
        capabilityProviders: {OnlineMusicCapability.search: 'missing'},
      );

      expect(registry.providerIdFor(OnlineMusicCapability.search), 'neteaseB');
    });
  });
}

final class _FakeProvider extends UnsupportedOnlineMusicProvider {
  _FakeProvider(this.providerId, this._platforms);

  @override
  final String providerId;

  final Map<OnlineMusicCapability, Set<MusicPlatform>> _platforms;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _platforms[capability] ?? const {};
}
