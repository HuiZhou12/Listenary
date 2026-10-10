import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';

/// F4-S3（P-11 + 延期 A）：把**分页与 limit 的契约**定下来并钉住 ——
///  - `limit`：只进请求参数 + 参与分页元数据；**不裁剪**映射结果；
///  - `offset`：每平台独立透传（老行为不变）；
///  - `page`：运行期由 `offset ~/ limit + 1` 派生（以前恒 1 ⇒ 永远请求第一页）；
///  - `cursor`：**暂不支持** —— 服务层契约里没有它的位置 ⇒ **明确失败**，绝不静默。
final class _CapturingTransport implements DeclarativeHttpTransport {
  _CapturingTransport(this.response);

  final DeclarativeHttpResponse response;
  final List<BuiltDeclarativeRequest> requests = [];

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    return response;
  }
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();
  @override
  Future<String?> readCredential(String reference) async => null;
}

/// 搜索响应：3 条曲目 + 总数 + 游标（用于验"不截断 + 元数据照记"）。
const _body = <String, Object?>{
  'code': 200,
  'result': {
    'songs': [
      {'id': 1, 'name': 'A'},
      {'id': 2, 'name': 'B'},
      {'id': 3, 'name': 'C'},
    ],
    'total': 100,
    'cursor': 'next-abc',
  },
};

OnlineMusicFieldSpec _int(String path, {bool required = false}) =>
    OnlineMusicFieldSpec(
      candidates: [JsonPath.tryParse(path)!],
      transform: OnlineMusicFieldTransform.asInt,
      required: required,
    );

OnlineMusicFieldSpec _str(String path, {bool required = false}) =>
    OnlineMusicFieldSpec(
      candidates: [JsonPath.tryParse(path)!],
      transform: OnlineMusicFieldTransform.asString,
      required: required,
    );

OnlineMusicResponseSpec _spec({
  OnlineMusicPaginationKind kind = OnlineMusicPaginationKind.offsetLimit,
}) => OnlineMusicResponseSpec(
  listPath: JsonPath.tryParse('result.songs'),
  totalPath: JsonPath.tryParse('result.total'),
  nextCursorPath: JsonPath.tryParse('result.cursor'),
  pagination: OnlineMusicPaginationSpec(kind: kind),
  fields: {
    OnlineMusicDomainField.trackId: _int('id', required: true),
    OnlineMusicDomainField.title: _str('name', required: true),
  },
);

OnlineMusicDeclarativeCapabilityBinding _searchBinding({
  OnlineMusicPaginationKind kind = OnlineMusicPaginationKind.offsetLimit,
  List<OnlineMusicParamBinding> extraQuery = const [],
}) => OnlineMusicDeclarativeCapabilityBinding(
  request: OnlineMusicRequestSpec(
    path: '/search',
    query: [
      const OnlineMusicParamBinding(
        name: 'keywords',
        source: OnlineMusicInputSource.keyword,
        required: true,
      ),
      ...extraQuery,
    ],
  ),
  response: _spec(kind: kind),
);

void main() {
  group('★ F4-S3 分页与 limit 的契约（P-11 + 延期 A）', () {
    test('映射器**不按 limit 截断**：返回 3 条而 limit=2 ⇒ 仍映射 3 条，元数据照记', () {
      final page = mapDeclarativeSearchResponse(
        spec: _spec(),
        body: _body,
        platform: MusicPlatform.netease,
        limit: 2,
        offset: 4,
      );

      expect(
        page.items,
        hasLength(3),
        reason: '契约：limit 只进请求与元数据判定，**不裁剪**服务端返回的条目',
      );
      expect(page.limit, 2);
      expect(page.offset, 4);
      expect(page.total, 100);
      expect(page.nextCursor, 'next-abc', reason: '游标照常映射出来（只是暂时无法回传）');
    });

    test('运行期 page 由 offset/limit 派生（以前恒 1）', () async {
      final transport = _CapturingTransport(
        const DeclarativeHttpResponse(statusCode: 200, data: _body),
      );
      final provider = DeclarativeMusicProvider(
        providerId: 'p',
        bindings: {
          OnlineMusicCapability.search: _searchBinding(
            extraQuery: const [
              OnlineMusicParamBinding(
                name: 'page',
                source: OnlineMusicInputSource.page,
              ),
            ],
          ),
        },
        transport: transport,
        credentials: const _NoCredentialReader(),
        contentPlatform: MusicPlatform.netease,
      );

      await provider.search(
        platform: MusicPlatform.netease,
        keyword: 'k',
        limit: 2,
        offset: 4,
        cancelToken: OnlineMusicCancelToken(),
      );
      expect(
        transport.requests.last.query['page'],
        '3',
        reason: 'offset 4 / limit 2 ⇒ 第 3 页',
      );

      await provider.search(
        platform: MusicPlatform.netease,
        keyword: 'k',
        limit: 0,
        offset: 10,
        cancelToken: OnlineMusicCancelToken(),
      );
      expect(
        transport.requests.last.query['page'],
        '1',
        reason: 'limit <= 0 时按第一页处理，不做除零',
      );
    });

    test('offset/limit 照旧透传：老行为不变', () async {
      final transport = _CapturingTransport(
        const DeclarativeHttpResponse(statusCode: 200, data: _body),
      );
      final provider = DeclarativeMusicProvider(
        providerId: 'p',
        bindings: {
          OnlineMusicCapability.search: _searchBinding(
            extraQuery: const [
              OnlineMusicParamBinding(
                name: 'limit',
                source: OnlineMusicInputSource.limit,
              ),
              OnlineMusicParamBinding(
                name: 'offset',
                source: OnlineMusicInputSource.offset,
              ),
            ],
          ),
        },
        transport: transport,
        credentials: const _NoCredentialReader(),
        contentPlatform: MusicPlatform.netease,
      );

      await provider.search(
        platform: MusicPlatform.netease,
        keyword: 'k',
        limit: 30,
        offset: 60,
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(transport.requests.last.query['limit'], '30');
      expect(transport.requests.last.query['offset'], '60');
    });

    test('游标分页**明确不可用**：声明 cursor ⇒ 运行期明确失败，不静默返回第一页', () async {
      final transport = _CapturingTransport(
        const DeclarativeHttpResponse(statusCode: 200, data: _body),
      );
      final provider = DeclarativeMusicProvider(
        providerId: 'p',
        bindings: {
          OnlineMusicCapability.search: _searchBinding(
            kind: OnlineMusicPaginationKind.cursor,
          ),
        },
        transport: transport,
        credentials: const _NoCredentialReader(),
        contentPlatform: MusicPlatform.netease,
      );

      await expectLater(
        provider.search(
          platform: MusicPlatform.netease,
          keyword: 'k',
          limit: 30,
          offset: 30,
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.safeMessage,
            'safeMessage',
            contains('游标分页'),
          ),
        ),
      );
      expect(
        transport.requests,
        isEmpty,
        reason: '明确失败 ⇒ 一个请求都不发（不静默把第二页当第一页）',
      );
    });

    test('游标取值参数在没有游标时**构造期明确失败**（兜底，不静默省掉参数）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'cursor',
            source: OnlineMusicInputSource.cursor,
          ),
        ],
      );

      expect(
        () => buildDeclarativeRequest(
          spec: spec,
          inputs: const DeclarativeInputs(),
        ),
        throwsA(
          isA<DeclarativeRequestException>()
              .having(
                (error) => error.kind,
                'kind',
                DeclarativeRequestErrorKind.invalidParameterBinding,
              )
              .having(
                (error) => error.safeMessage,
                'safeMessage',
                contains('无法提供游标'),
              ),
        ),
      );
    });
  });
}
