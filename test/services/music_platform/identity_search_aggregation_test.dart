import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';

/// decoupling-2.2（R4 / R5）：在线搜索页的**身份版**聚合链路。
///
/// 关键点（否则 UI 是"能选不能搜"）：
/// - 两个自定义平台的曲目必须各自落在自己的身份键下，**不互相覆盖**；
/// - 一处失败不改变另一处的可用性（一个进 failuresByIdentity，另一个照常出结果）；
/// - 门槛与 `searchableIdentities` 同源：不在集合里的身份**一个请求都不发**。
void main() {
  const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const betaId = '0f9a1c2e-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const alpha = PlatformIdentity.custom(alphaId);
  const beta = PlatformIdentity.custom(betaId);

  ({
    CompositeOnlineMusicService service,
    _CountingTransport alphaT,
    _CountingTransport betaT,
  })
  build() {
    final alphaT = _CountingTransport('alpha');
    final betaT = _CountingTransport('beta');
    return (
      service: CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(
          providers: [_provider('alpha', alphaT), _provider('beta', betaT)],
          providerIdentities: const {'alpha': alpha, 'beta': beta},
        ),
      ),
      alphaT: alphaT,
      betaT: betaT,
    );
  }

  test('★ R4 两个自定义平台同时搜索：结果各归自己的身份键，不串台', () async {
    final harness = build();
    addTearDown(harness.service.dispose);

    final result = await harness.service.searchIdentities(
      identities: const [alpha, beta],
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(result.perPlatformIdentity.keys, containsAll([alpha, beta]));
    expect(
      result.perPlatformIdentity[alpha]!.items.single.title,
      'alpha',
      reason: '结果必须按身份归位（枚举键 custom 只有一个，会互相覆盖）',
    );
    expect(result.perPlatformIdentity[beta]!.items.single.title, 'beta');
    expect(harness.alphaT.requests, hasLength(1));
    expect(harness.betaT.requests, hasLength(1));
  });

  test('★ R4 一处失败不影响另一处的可用性（失败按身份隔离）', () async {
    final alphaT = _CountingTransport('alpha');
    final betaT = _FailingTransport();
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(
        providers: [_provider('alpha', alphaT), _provider('beta', betaT)],
        providerIdentities: const {'alpha': alpha, 'beta': beta},
      ),
    );
    addTearDown(service.dispose);

    final result = await service.searchIdentities(
      identities: const [alpha, beta],
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(result.perPlatformIdentity[alpha], isNotNull);
    expect(result.failuresByIdentity[beta], isNotNull);
    expect(result.perPlatformIdentity.containsKey(beta), isFalse);
  });

  test('★ R4 门槛同源：不在 searchableIdentities 里的身份一个请求都不发', () async {
    final harness = build();
    addTearDown(harness.service.dispose);

    expect(
      harness.service.capabilities.searchableIdentities,
      containsAll(const [alpha, beta]),
    );
    expect(
      harness.service.capabilities.searchableIdentities.contains(
        const PlatformIdentity.custom('id-not-configured'),
      ),
      isFalse,
    );

    final result = await harness.service.searchIdentities(
      identities: const [PlatformIdentity.custom('id-not-configured')],
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(result.perPlatformIdentity, isEmpty);
    expect(result.failuresByIdentity, isEmpty);
    expect(harness.alphaT.requests, isEmpty);
    expect(harness.betaT.requests, isEmpty);
  });

  test('★ R5 身份无效（空稳定 ID）⇒ 不进可搜索集合、不发请求、不回落网易云', () async {
    final harness = build();
    addTearDown(harness.service.dispose);

    const invalid = PlatformIdentity.custom('   ');
    expect(harness.service.capabilities.canSearchIdentity(invalid), isFalse);

    final result = await harness.service.searchIdentities(
      identities: const [invalid],
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(result.perPlatformIdentity, isEmpty);
    expect(harness.alphaT.requests, isEmpty);
    expect(harness.betaT.requests, isEmpty);
  });
}

OnlineMusicResponseSpec _searchResponse() => OnlineMusicResponseSpec(
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

DeclarativeMusicProvider _provider(
  String id,
  DeclarativeHttpTransport transport,
) => DeclarativeMusicProvider(
  providerId: id,
  contentPlatform: MusicPlatform.custom,
  bindings: {
    OnlineMusicCapability.search: OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/search'),
      response: _searchResponse(),
    ),
    OnlineMusicCapability.stream: OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/song/url'),
      response: _searchResponse(),
    ),
  },
  transport: transport,
  credentials: const _NoCredentialReader(),
);

/// 返回**自己身份**的曲目（标题 = provider id）⇒ 断言能分辨结果归到了谁那里。
final class _CountingTransport implements DeclarativeHttpTransport {
  _CountingTransport(this.providerId);

  final String providerId;
  final List<BuiltDeclarativeRequest> requests = [];

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    return DeclarativeHttpResponse(
      statusCode: 200,
      data: <String, Object?>{
        'result': <String, Object?>{
          'songs': <Object?>[
            <String, Object?>{'id': providerId.hashCode, 'name': providerId},
          ],
        },
      },
    );
  }
}

final class _FailingTransport implements DeclarativeHttpTransport {
  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async => throw const FormatException('down');
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();
  @override
  Future<String?> readCredential(String reference) async => null;
}
