import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';

/// F5-P-39（P-63）：数据可用性复核的判据必须是**稳定平台身份** k.
void main() {
  const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const otherId = '0f9a1c2e-cccc-4ccc-8ccc-cccccccccccc';

  OnlineMusicCapabilities caps({
    Set<MusicPlatform> platforms = const {},
    Set<PlatformIdentity> identities = const {},
  }) => OnlineMusicCapabilities(
    searchablePlatforms: platforms,
    resolvablePlatforms: platforms,
    resolvableIdentities: identities,
  );

  test('★ P63-1 内置平台：判据等价于 resolvablePlatforms（既有语义不变）', () {
    final c = caps(platforms: const {MusicPlatform.netease});
    expect(c.canResolveIdentity(const PlatformIdentity.builtin(MusicPlatform.netease)), isTrue);
    expect(c.canResolveIdentity(const PlatformIdentity.builtin(MusicPlatform.qq)), isFalse);
  });

  test('★ P63-2 自定义平台按 (custom, stableId) 判定：不同 ID 不得互相冒充', () {
    final c = caps(identities: {
      const PlatformIdentity.custom(alphaId),
    });
    expect(c.canResolveIdentity(const PlatformIdentity.custom(alphaId)), isTrue);
    expect(
      c.canResolveIdentity(const PlatformIdentity.custom(otherId)),
      isFalse,
      reason: '另一个自定义平台（或未知历史值）不得被当成可用',
    );
  });

  test('★ P63-3 身份无效 / 未登记 ⇒ false（fail-closed：只呈现状态，不改数据）', () {
    final c = caps(identities: {
      const PlatformIdentity.custom(alphaId),
    });
    expect(c.canResolveIdentity(const PlatformIdentity.custom('')), isFalse);
    expect(c.canResolveIdentity(const PlatformIdentity.custom('   ')), isFalse);
    expect(c.canResolveIdentity(const PlatformIdentity.custom('LegacyProxy')), isFalse);
  });

  test('★ P63-4 组合服务：可解析身份集合来自实际支持 stream 的 provider', () {
    final alphaT = _CountingTransport();
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(
        providers: [_provider('alpha', alphaT)],
        providerIdentities: const {
          'alpha': PlatformIdentity.custom(alphaId),
        },
      ),
    );
    addTearDown(service.dispose);

    expect(
      service.capabilities.resolvableIdentities,
      contains(const PlatformIdentity.custom(alphaId)),
    );
    expect(
      service.capabilities.canResolveIdentity(const PlatformIdentity.custom(alphaId)),
      isTrue,
    );
    expect(
      service.capabilities.canResolveIdentity(const PlatformIdentity.custom(otherId)),
      isFalse,
    );
  });
}

DeclarativeMusicProvider _provider(String id, DeclarativeHttpTransport transport) =>
    DeclarativeMusicProvider(
      providerId: id,
      contentPlatform: MusicPlatform.custom,
      bindings: {
        OnlineMusicCapability.search: OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/search'),
          response: _response(),
        ),
        OnlineMusicCapability.stream: OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/song/url'),
          response: _response(),
        ),
      },
      transport: transport,
      credentials: const _NoCredentialReader(),
    );

OnlineMusicResponseSpec _response() => OnlineMusicResponseSpec(
  listPath: JsonPath.tryParse('result.songs'),
  fields: {
    OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
      candidates: [JsonPath.tryParse('id')!],
      transform: OnlineMusicFieldTransform.asInt,
      required: true,
    ),
    OnlineMusicDomainField.title: OnlineMusicFieldSpec(
      candidates: [JsonPath.tryParse('name')!],
      transform: OnlineMusicFieldTransform.asString,
      required: true,
    ),
  },
);

final class _CountingTransport implements DeclarativeHttpTransport {
  final List<BuiltDeclarativeRequest> requests = [];
  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    return const DeclarativeHttpResponse(
      statusCode: 200,
      data: <String, Object?>{
        'result': <String, Object?>{
          'songs': <Object?>[
            <String, Object?>{'id': 1, 'name': 'x'},
          ],
        },
      },
    );
  }
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();
  @override
  Future<String?> readCredential(String reference) async => null;
}