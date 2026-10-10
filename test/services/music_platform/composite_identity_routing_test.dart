import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';

/// F5-P-39（P2）：服务层按平台身份**路由 + 聚合**（用户必需测试 ②③⑦）。
///
/// ⚠️ 两个易错前提（本次调试确认）：
/// 1. 搜索门槛要求平台**同时**具备 search 与 stream 候选（`composite:39-42`）；
/// 2. 声明式响应必须配好列表路径，否则预检就报 `endpointMismatch`、**一个请求都不发**。
void main() {
  const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const betaId = '0f9a1c2e-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  ({CompositeOnlineMusicService service, _CountingTransport alphaT, _CountingTransport betaT})
  build() {
    final alphaT = _CountingTransport();
    final betaT = _CountingTransport();
    return (
      service: CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(
          providers: [_provider('alpha', alphaT), _provider('beta', betaT)],
          providerIdentities: const {
            'alpha': PlatformIdentity.custom(alphaId),
            'beta': PlatformIdentity.custom(betaId),
          },
        ),
      ),
      alphaT: alphaT,
      betaT: betaT,
    );
  }

  test('★ P2-门槛 自定义平台必须能进能力集合（否则聚合一请求都不发）', () {
    final harness = build();
    addTearDown(harness.service.dispose);
    expect(
      harness.service.capabilities.searchablePlatforms,
      contains(MusicPlatform.custom),
      reason: '能力集合是路由/门槛依据，必须含 custom（P1a 越界曾把这里排除掉）',
    );
  });

  test('★ P2-③ 按稳定 ID 路由：只打中身份匹配的 provider', () async {
    final harness = build();
    addTearDown(harness.service.dispose);

    await harness.service.search(
      platform: MusicPlatform.custom,
      identity: const PlatformIdentity.custom(alphaId),
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(harness.alphaT.requests, hasLength(1));
    expect(harness.betaT.requests, isEmpty, reason: '不得串到另一个自定义平台');
  });

  test('★ P2-② 聚合：身份键承载结果，旧枚举键不静默覆盖', () async {
    final harness = build();
    addTearDown(harness.service.dispose);

    final result = await harness.service.searchAggregated(
      platforms: const [MusicPlatform.custom],
      identities: const {
        MusicPlatform.custom: PlatformIdentity.custom(alphaId),
      },
      keyword: 'x',
      cancelToken: OnlineMusicCancelToken(),
    );

    expect(result.perPlatformIdentity.keys, [
      const PlatformIdentity.custom(alphaId),
    ]);
    expect(harness.alphaT.requests, hasLength(1));
    expect(harness.betaT.requests, isEmpty);
  });

  test('★ P2-⑦ 身份无效（缺稳定 ID）⇒ unavailable 且 0 请求', () async {
    final harness = build();
    addTearDown(harness.service.dispose);

    await expectLater(
      harness.service.search(
        platform: MusicPlatform.custom,
        identity: const PlatformIdentity.custom(''),
        keyword: 'x',
        cancelToken: OnlineMusicCancelToken(),
      ),
      throwsA(
        isA<OnlineMusicException>().having(
          (error) => error.kind,
          'kind',
          OnlineMusicErrorKind.unavailable,
        ),
      ),
    );
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
    // 映射要求必填 title（本次调试确认：缺它会报 endpointMismatch，一个请求都不发）。
    OnlineMusicDomainField.title: OnlineMusicFieldSpec(
      candidates: [JsonPath.tryParse('name')!],
      transform: OnlineMusicFieldTransform.asString,
      required: true,
    ),
  },
);

DeclarativeMusicProvider _provider(String id, DeclarativeHttpTransport transport) =>
    DeclarativeMusicProvider(
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