import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';

/// F5-P-39（P2）：注册表**按平台身份**取候选 —— 必需测试 ③（路由按稳定 ID 选对 provider）
/// 以及 ⑦/⑩ 的一部分（身份缺失/未知 ⇒ fail-closed，且**不与其他自定义平台串台**）。
void main() {
  DeclarativeMusicProvider provider(String id) => DeclarativeMusicProvider(
    providerId: id,
    contentPlatform: MusicPlatform.custom,
    bindings: const {
      OnlineMusicCapability.search: OnlineMusicDeclarativeCapabilityBinding(
        request: OnlineMusicRequestSpec(path: '/search'),
        response: OnlineMusicResponseSpec(),
      ),
    },
    transport: _NoopTransport(),
    credentials: const _NoCredentialReader(),
  );

  OnlineMusicProviderRegistry registryWith(Map<String, PlatformIdentity> ids) =>
      OnlineMusicProviderRegistry(
        providers: [provider('alpha'), provider('beta')],
        providerIdentities: ids,
      );

  test('★ P-39-P2 两个自定义平台：各自只拿到自己的 provider（不串台）', () {
    const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const betaId = '0f9a1c2e-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final registry = registryWith({
      'alpha': const PlatformIdentity.custom(alphaId),
      'beta': const PlatformIdentity.custom(betaId),
    });

    expect(
      registry
          .providersForIdentity(
            const PlatformIdentity.custom(alphaId),
            OnlineMusicCapability.search,
          )
          .map((provider) => provider.providerId),
      ['alpha'],
    );
    expect(
      registry
          .providersForIdentity(
            const PlatformIdentity.custom(betaId),
            OnlineMusicCapability.search,
          )
          .map((provider) => provider.providerId),
      ['beta'],
    );

    // 对照：**旧的枚举键 API** 会把两个自定义平台**都**返回 ⇒ 这正是必须改用身份键的原因。
    expect(
      registry.providersFor(MusicPlatform.custom, OnlineMusicCapability.search),
      hasLength(2),
    );
  });

  test('★ P-39-P2 fail-closed：身份无效 / 未登记 / 未知 ID / 能力不匹配 ⇒ 返回空', () {
    final registry = registryWith({
      'alpha': const PlatformIdentity.custom('id-alpha'),
      'beta': const PlatformIdentity.custom('id-beta'),
    });

    expect(
      registry.providersForIdentity(
        const PlatformIdentity.custom('   '),
        OnlineMusicCapability.search,
      ),
      isEmpty,
      reason: '缺稳定 ID ⇒ 身份无效 ⇒ 不得参与网络路由',
    );
    expect(
      registry.providersForIdentity(
        const PlatformIdentity.custom('id-not-configured'),
        OnlineMusicCapability.search,
      ),
      isEmpty,
      reason: '没有匹配的自定义平台 ⇒ 空（绝不借用别人的 provider）',
    );
    expect(
      registry.providersForIdentity(
        const PlatformIdentity.custom('id-alpha'),
        OnlineMusicCapability.lyric,
      ),
      isEmpty,
      reason: '该 provider 没声明这个能力 ⇒ 空',
    );
  });

  test('★ P-39-P2 内置平台：身份版与旧的枚举版**完全等价**（既有语义不变）', () {
    final registry = OnlineMusicProviderRegistry(
      providers: [provider('builtinish')],
    );

    expect(
      registry.providersForIdentity(
        const PlatformIdentity.builtin(MusicPlatform.netease),
        OnlineMusicCapability.search,
      ),
      registry.providersFor(MusicPlatform.netease, OnlineMusicCapability.search),
    );
  });

  test('★ P-39-P2 未登记身份的 provider：不会冒充任何自定义平台', () {
    final registry = registryWith(const {});
    expect(
      registry
          .providersForIdentity(
            const PlatformIdentity.custom('id-alpha'),
            OnlineMusicCapability.search,
          )
          .isEmpty,
      isTrue,
      reason: '身份未知 ⇒ 安全方向：不匹配（而不是匹配任意 custom）',
    );
  });
}

final class _NoopTransport implements DeclarativeHttpTransport {
  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async => const DeclarativeHttpResponse(
    statusCode: 200,
    data: <String, Object?>{},
  );
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();
  @override
  Future<String?> readCredential(String reference) async => null;
}