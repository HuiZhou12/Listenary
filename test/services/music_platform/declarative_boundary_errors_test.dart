import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';

/// 记录请求的假传输（用来证明"构造期就拒绝 ⇒ 一个请求都不发"）。
final class _RecordingTransport implements DeclarativeHttpTransport {
  final List<BuiltDeclarativeRequest> requests = [];

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    return const DeclarativeHttpResponse(
      statusCode: 200,
      data: <String, Object?>{},
    );
  }
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();
  @override
  Future<String?> readCredential(String reference) async => null;
}

/// F4-S8：把"边界"**明确报出来**（D3 / D4 / P-65 的裁定）——
/// - P-65：认证注入与声明的参数同名 ⇒ **一律报错**（以前静默覆盖）；
/// - 非 ASCII 头值 ⇒ 明确报错（真实环境实测：传输层会直接失败且用户看不出原因）；
/// - 响应根本不是 JSON ⇒ 明确说成"接口不匹配"，而不是笼统的"字段映射不完整"。
void main() {
  group('★ F4-S8（P-65）认证注入与声明的参数同名 ⇒ 一律报错', () {
    test('保存校验：query / header / body 三种同名都拦下', () {
      const queryConflict = OnlineMusicRequestSpec(
        path: '/s',
        query: [
          OnlineMusicParamBinding(name: 'key', source: OnlineMusicInputSource.keyword),
        ],
        auth: OnlineMusicQueryAuthPlacement(parameterName: 'key'),
      );
      const headerConflict = OnlineMusicRequestSpec(
        path: '/s',
        headers: [OnlineMusicHeaderSpec(name: 'X-Token', value: 'v')],
        auth: OnlineMusicHeaderAuthPlacement(headerName: 'x-token'),
      );
      const bodyConflict = OnlineMusicRequestSpec(
        path: '/s',
        verb: OnlineMusicHttpVerb.post,
        body: OnlineMusicRequestBodySpec(
          fields: [
            OnlineMusicParamBinding(name: 'token', source: OnlineMusicInputSource.keyword),
          ],
        ),
        auth: OnlineMusicBodyAuthPlacement(fieldName: 'token'),
      );

      expect(
        queryConflict.validationIssues().any((i) => i.contains('同名')),
        isTrue,
      );
      expect(
        headerConflict.validationIssues().any((i) => i.contains('同名')),
        isTrue,
        reason: 'HTTP 头名不区分大小写 ⇒ X-Token 与 x-token 也算同名',
      );
      expect(
        bodyConflict.validationIssues().any((i) => i.contains('同名')),
        isTrue,
      );
    });

    test('构造请求：三种同名都在**发请求之前**明确失败', () {
      const queryConflict = OnlineMusicRequestSpec(
        path: '/s',
        query: [
          OnlineMusicParamBinding(name: 'key', source: OnlineMusicInputSource.keyword),
        ],
        auth: OnlineMusicQueryAuthPlacement(parameterName: 'key'),
      );

      expect(
        () => buildDeclarativeRequest(
          spec: queryConflict,
          inputs: const DeclarativeInputs(keyword: 'x'),
          credential: 'secret',
        ),
        throwsA(
          isA<DeclarativeRequestException>().having(
            (error) => error.kind,
            'kind',
            DeclarativeRequestErrorKind.authParameterConflict,
          ),
        ),
      );
    });

    test('不同名 ⇒ 照旧正常工作（不误伤）', () {
      const ok = OnlineMusicRequestSpec(
        path: '/s',
        query: [
          OnlineMusicParamBinding(name: 'keywords', source: OnlineMusicInputSource.keyword),
        ],
        auth: OnlineMusicQueryAuthPlacement(parameterName: 'key'),
      );

      final request = buildDeclarativeRequest(
        spec: ok,
        inputs: const DeclarativeInputs(keyword: 'x'),
        credential: 'secret',
      );

      expect(request.query['keywords'], 'x');
      expect(request.query['key'], 'secret');
      expect(ok.validationIssues(), isEmpty);
    });
  });

  group('★ F4-S8 非 ASCII 头值 ⇒ 明确报错（不留给传输层抛错）', () {
    test('保存校验：静态头值含非 ASCII ⇒ 拦下并指出改用查询参数', () {
      const spec = OnlineMusicRequestSpec(
        path: '/s',
        headers: [OnlineMusicHeaderSpec(name: 'X-Keyword', value: '海阔天空')],
      );

      expect(
        spec.validationIssues().any(
          (issue) => issue.contains('非 ASCII') && issue.contains('查询参数'),
        ),
        isTrue,
      );
    });

    test('构造请求：**动态**头值解析出非 ASCII（中文关键词）⇒ 明确失败', () {
      const spec = OnlineMusicRequestSpec(
        path: '/s',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'X-Keyword',
            value: '',
            source: OnlineMusicInputSource.keyword,
          ),
        ],
      );

      expect(
        () => buildDeclarativeRequest(
          spec: spec,
          inputs: const DeclarativeInputs(keyword: '海阔天空'),
        ),
        throwsA(
          isA<DeclarativeRequestException>()
              .having(
                (error) => error.kind,
                'kind',
                DeclarativeRequestErrorKind.invalidHeaderValue,
              )
              .having(
                (error) => error.safeMessage,
                'safeMessage',
                allOf(contains('X-Keyword'), contains('非 ASCII')),
              ),
        ),
        reason: '真实环境实测：中文头值会让传输层直接抛错，用户看不出原因',
      );
    });

    test('ASCII 头值照旧正常（不误伤）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/s',
        headers: [
          OnlineMusicHeaderSpec(name: 'X-Client', value: 'pure-music/1.0'),
        ],
      );

      final request = buildDeclarativeRequest(
        spec: spec,
        inputs: const DeclarativeInputs(),
      );

      expect(request.headers['X-Client'], 'pure-music/1.0');
      expect(spec.validationIssues(), isEmpty);
    });

    test('★ 运行期：非 ASCII 头值归**配置错误**，绝不被误判为网络故障（且 0 请求）', () async {
      // 用户要求核实的那条：不是"网络不可达"，而是"配置里写了不能用的东西"。
      // 真实环境实测（S2）正是中文头值让传输层直接抛错 ⇒ 现在应当在**发请求之前**明确失败。
      final transport = _RecordingTransport();
      final provider = DeclarativeMusicProvider(
        providerId: 'p',
        bindings: {
          OnlineMusicCapability.search:
              const OnlineMusicDeclarativeCapabilityBinding(
                request: OnlineMusicRequestSpec(
                  path: '/s',
                  query: [
                    OnlineMusicParamBinding(
                      name: 'keywords',
                      source: OnlineMusicInputSource.keyword,
                      required: true,
                    ),
                  ],
                  headers: [
                    OnlineMusicHeaderSpec(
                      name: 'X-Keyword',
                      value: '',
                      source: OnlineMusicInputSource.keyword,
                    ),
                  ],
                ),
                response: OnlineMusicResponseSpec(),
              ),
        },
        transport: transport,
        credentials: const _NoCredentialReader(),
        contentPlatform: MusicPlatform.netease,
      );

      await expectLater(
        provider.search(
          platform: MusicPlatform.netease,
          keyword: '海阔天空',
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>()
              .having(
                (error) => error.kind,
                'kind',
                isNot(OnlineMusicErrorKind.network),
              )
              .having(
                (error) => error.kind,
                'kind',
                OnlineMusicErrorKind.badRequest,
              )
              .having(
                (error) => error.safeMessage,
                'safeMessage',
                contains('非 ASCII'),
              ),
        ),
      );
      expect(
        transport.requests,
        isEmpty,
        reason: '构造期就拒绝 ⇒ 一个请求都不发（不是"发出去失败了"）',
      );
    });
  });

  group('★ F4-S8 响应不是 JSON ⇒ 明确结论（而不是"字段映射不完整"）', () {
    test('结构化响应不报问题；HTML / 纯文本 / 空响应给出明确说明', () {
      expect(nonStructuredResponseReason(const {'a': 1}), isNull);
      expect(nonStructuredResponseReason(const [1, 2]), isNull);
      expect(
        nonStructuredResponseReason('<!DOCTYPE html><html></html>'),
        allOf(contains('不是 JSON'), contains('接口定义与实际返回不匹配')),
      );
      expect(nonStructuredResponseReason(null), contains('不是 JSON'));
    });
  });
}
