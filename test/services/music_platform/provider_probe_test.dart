import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_execution.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';

/// ChkSz 搜索样本（与 S2 验收用的是同一份真实样本）。
const _chkszBody = <String, Object?>{
  'code': 200,
  'msg': 'success',
  'data': {
    'songs': [
      {'id': 65800, 'name': '最佳损友', 'artists': '陈奕迅', 'duration': 233560},
    ],
    'total': 291,
  },
};

/// MSAPI 搜索样本（同一份真实样本）。
const _msapiBody = <String, Object?>{
  'result': {
    'songs': [
      {
        'id': 347230,
        'name': '海阔天空',
        'artists': [
          {'id': 11127, 'name': 'Beyond'},
        ],
        'album': {'id': 78372827, 'name': '华纳廿三周年纪念精选系列'},
        'duration': 239560,
      },
    ],
  },
};

void main() {
  late _FakeProbeTransport transport;

  setUp(() => transport = _FakeProbeTransport());

  test('a ChkSz-compatible service yields a draft from the builtin template', () async {
    transport.responder = (options) async {
      expect(options.path, '/api/163_search');
      expect(options.queryParameters['apikey'], 'chksz_KEY_TEST_ONLY');
      expect(options.queryParameters['keyword'], providerProbeKeyword);
      return _chkszBody;
    };

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
      credential: 'chksz_KEY_TEST_ONLY',
    );

    expect(report.hasDraft, isTrue);
    expect(report.draftTemplateId, builtinOnlineMusicChkszId);
    expect(report.draft, chkszSearchTemplate);
    final best = report.outcomes.firstWhere(
      (outcome) => outcome.candidateId == builtinOnlineMusicChkszId,
    );
    expect(best.score, 2);
    expect(best.mappedTrackCount, 1);
    expect(best.statusCode, 200);
  });

  test('probeSearch reports "needs authentication" from the real response', () async {
    // P5：缺凭据也要真的发一次请求，让服务端回答。
    transport.statusCode = 401;
    transport.responder = (options) async => const {'message': 'unauthorized'};

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
    );

    expect(
      transport.requests.any((request) => request.path == '/api/163_search'),
      isTrue,
      reason: '没有凭据也要发出探测请求',
    );
    expect(report.anyNeedsAuthentication, isTrue);
    expect(report.hasDraft, isFalse);
  });

  test('a keyed template without a credential still probes', () async {
    transport.responder = (options) async {
      // 探测副本必须不带任何鉴权参数。
      expect(options.queryParameters.containsKey('apikey'), isFalse);
      return _msapiBody;
    };

    await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
    );

    expect(
      transport.requests.map((request) => request.path).toSet(),
      {'/api/163_search', '/search'},
    );
  });

  test('the candidate list is clamped to the hard limit', () async {
    transport.responder = (options) async => const {'nope': true};

    await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
      maxRequests: 99,
    );

    expect(transport.requests.length, lessThanOrEqualTo(providerProbeMaxRequests));
  });

  test('a netease-proxy service is recognised without any credential', () async {
    transport.responder = (options) async => _msapiBody;

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
    );

    expect(report.draftTemplateId, 'netease-proxy');
    // 两个模板都会被真的探测一次；ChkSz 模板的成功判定不匹配这份响应，因此得分 0。
    expect(
      transport.requests.map((request) => request.path).toSet(),
      {'/api/163_search', '/search'},
    );
    final chkszOutcome = report.outcomes.firstWhere(
      (outcome) => outcome.candidateId == builtinOnlineMusicChkszId,
    );
    expect(chkszOutcome.score, 0);
    expect(chkszOutcome.failureReason, contains('成功判定未通过'));
  });

  test('401 and 403 are reported as "needs authentication"', () async {
    transport.statusCode = 401;
    transport.responder = (options) async => const {'message': 'unauthorized'};

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
    );

    expect(report.hasDraft, isFalse);
    expect(report.anyNeedsAuthentication, isTrue);
    expect(
      report.outcomes.every(
        (outcome) => outcome.failureReason != null || outcome.score == 0,
      ),
      isTrue,
    );
  });

  test('a partial mapping still produces an editable draft', () async {
    // 列表存在（score 1），但缺少必填的 title。
    transport.responder = (options) async => const {
      'result': {
        'songs': [
          {'id': 1},
        ],
      },
    };

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
    );

    expect(report.draftTemplateId, 'netease-proxy');
    final outcome = report.outcomes.firstWhere(
      (candidate) => candidate.candidateId == 'netease-proxy',
    );
    expect(outcome.score, 1);
    expect(outcome.failureReason, contains('字段映射不完整'));
  });

  test('the request count never exceeds the configured maximum', () async {
    transport.responder = (options) async => const {'nope': true};

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
      credential: 'chksz_KEY_TEST_ONLY',
      maxRequests: 1,
    );

    expect(transport.requests, hasLength(1));
    // ⚠️ 断言随 F3-S3（D-F3-5 第 5 条）更新，**不是放宽**：以前超出预算的候选被
    // `.take(maxRequests)` **直接截掉**（报告里根本看不到它），现在它以
    // 「未尝试：请求预算耗尽」出现在报告里 —— 用户必须能看到"有几个候选没试"。
    expect(report.outcomes, hasLength(onlineMusicProviderTemplates().length));
    expect(
      report.outcomes.where(
        (outcome) => outcome.status == ProviderProbeStatus.notAttempted,
      ),
      hasLength(onlineMusicProviderTemplates().length - 1),
    );
    expect(
      report.outcomes.last.notAttemptedReason,
      contains('预算'),
      reason: '超预算的候选必须显示"未尝试：请求预算耗尽"，不得误报为验证失败',
    );
    expect(report.outcomes.last.failureKind, isNull);
  });

  test('the total budget stops further probing and aggregates the rest', () async {
    transport.responder = (options) async => const {'nope': true};
    // 第一次检查就认为预算已用完。
    var calls = 0;
    final start = DateTime.utc(2026, 10, 5);
    DateTime clock() => start.add(Duration(seconds: calls++ * 60));

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
      clock: clock,
    );

    expect(transport.requests, isEmpty);
    // ⚠️ 断言随 F3-S1 收紧（不是放宽）：预算耗尽的候选以前只是"一条失败理由"，
    // 与"试过但失败"在结构上无法区分。D-F3-5 要求这种候选显示
    // 「未尝试：请求预算耗尽」并且**不得误报为验证失败** ⇒ 现在它有独立状态。
    expect(
      report.outcomes.map((outcome) => outcome.status),
      everyElement(ProviderProbeStatus.notAttempted),
    );
    expect(
      report.outcomes.map((outcome) => outcome.notAttemptedReason),
      everyElement(
        allOf(
          contains('未尝试'),
          // 两种"没试"的原因都要说清楚：请求数预算耗尽 / 探测总时限已到。
          anyOf(contains('预算'), contains('时限')),
        ),
      ),
    );
    expect(
      report.outcomes.map((outcome) => outcome.failureKind),
      everyElement(isNull),
      reason: '未尝试 ≠ 验证失败：不得给出失败分类',
    );
    expect(report.didNotSendAnyRequest, isTrue);
  });

  test('every candidate failing yields no draft but a full report', () async {
    transport.statusCode = 500;
    transport.responder = (options) async => const {'oops': true};

    final report = await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
      credential: 'chksz_KEY_TEST_ONLY',
    );

    expect(report.hasDraft, isFalse);
    expect(report.outcomes, hasLength(onlineMusicProviderTemplates().length));
    expect(
      report.outcomes.every((outcome) => outcome.failureReason != null),
      isTrue,
    );
  });

  test('probing issues requests for the configured candidates only', () async {
    transport.responder = (options) async => const {'nope': true};

    await probeDeclarativeSearch(
      transport: transport,
      headerCredentialReader: noHeaderCredentials,
      candidates: templateCandidates(),
      platform: MusicPlatform.netease,
      credential: 'chksz_KEY_TEST_ONLY',
    );

    // 只会打到模板里写明的相对路径，不存在字典式扫描。
    expect(
      transport.requests.map((request) => request.path).toSet(),
      {'/api/163_search', '/search'},
    );
  });

  test('the probe transport can be built without following redirects', () {
    // P3：探测不允许跟随跨主机重定向，由传输层这个开关保证（上层构造时置 false）。
    final transport = DioDeclarativeHttpTransport(
      dio: Dio(BaseOptions(baseUrl: 'https://example.invalid')),
      followRedirects: false,
    );
    expect(transport.followRedirects, isFalse);
  });

  // ======================================================== F3-S1（P-07）

  group('★ F3-S1 探测与试跑共用同一执行与判定引擎', () {
    test('失败分类取自**统一表**，且与试跑对同一响应同结论', () async {
      // 500 + **可读** JSON 响应体
      transport.statusCode = 500;
      transport.responder = (options) async => const {'oops': true};

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: templateCandidates([onlineMusicProviderTemplates().first]),
      );

      final outcome = report.outcomes.single;
      expect(outcome.failureKind, OnlineMusicErrorKind.unavailable);
      // **同一响应**：试跑那边的粗粒度词表必须是同一个结论的投影。
      expect(
        declarativeTestFailureKindFor(outcome.failureKind!),
        classifyUnsuccessfulTestResponse(500, const {'oops': true}),
      );
      expect(
        declarativeTestFailureKindFor(outcome.failureKind!),
        DeclarativeTestFailureKind.http,
      );

      // 同一个状态码但**响应不可读**（HTML 错误页/纯文本）⇒ 统一表判为
      // 「接口定义不匹配」（声明式路径的既定规则：读不出结构就说明打到的不是那个接口）。
      transport.responder = (options) async => '<html>500</html>';
      final unreadable = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: templateCandidates([onlineMusicProviderTemplates().first]),
      );
      expect(
        unreadable.outcomes.single.failureKind,
        OnlineMusicErrorKind.endpointMismatch,
      );
      expect(
        declarativeTestFailureKindFor(
          unreadable.outcomes.single.failureKind!,
        ),
        classifyUnsuccessfulTestResponse(500, '<html>500</html>'),
      );
    });

    test('200 但成功判定不通过：可读响应 ⇒ 业务；不可读 ⇒ 接口定义不匹配', () async {
      transport.statusCode = 200;
      transport.responder = (options) async => const {'nope': true};
      final readable = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: templateCandidates([onlineMusicProviderTemplates().first]),
      );
      expect(
        readable.outcomes.single.failureKind,
        OnlineMusicErrorKind.businessFailure,
      );
      expect(
        declarativeTestFailureKindFor(readable.outcomes.single.failureKind!),
        DeclarativeTestFailureKind.business,
      );

      transport.responder = (options) async => '<html>错误页</html>';
      final unreadable = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: templateCandidates([onlineMusicProviderTemplates().first]),
      );
      expect(
        unreadable.outcomes.single.failureKind,
        OnlineMusicErrorKind.endpointMismatch,
      );
      expect(
        declarativeTestFailureKindFor(unreadable.outcomes.single.failureKind!),
        DeclarativeTestFailureKind.responseFormat,
      );
    });

    test('结果带上**已脱敏**的请求摘要与响应片段', () async {
      // ⚠️ 必须让这条用例**真的成功**（走成功分支）：第一版我随手写了个结构不完整的
      // data，结果落进"映射不全"分支 —— 那样即使把成功分支的诊断字段删掉，用例也照样绿
      // （变异 M4 未命中目标即此原因，已按规则修正夹具而非放宽断言）。
      transport.responder = (options) async => {
        'code': 200,
        'msg': 'success',
        'data': {
          'songs': [
            {'id': 65800, 'name': '最佳损友', 'artists': '陈奕迅', 'duration': 233560},
          ],
          'total': 291,
        },
        'token': 'SECRET_SHOULD_NOT_APPEAR',
      };

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        credential: 'chksz_KEY_TEST_ONLY',
        candidates: templateCandidates([onlineMusicProviderTemplates().first]),
      );

      final outcome = report.outcomes.single;
      expect(outcome.score, 2, reason: '夹具必须走**成功**分支');
      expect(outcome.requestSummary, isNotNull);
      expect(outcome.requestSummary, contains('apikey=[redacted]'));
      expect(outcome.requestSummary, isNot(contains('chksz_KEY_TEST_ONLY')));
      expect(outcome.responsePreview, isNotNull);
      expect(outcome.responsePreview, contains('[redacted]'));
      expect(
        outcome.responsePreview,
        isNot(contains('SECRET_SHOULD_NOT_APPEAR')),
        reason: 'P-07 的诊断必须与试跑共用同一份脱敏',
      );
    });

    test('没有可执行候选 ⇒ 明确报"未尝试"，不构造成功结果', () async {
      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: const [],
      );

      expect(report.outcomes, isEmpty);
      expect(report.hasDraft, isFalse);
      expect(report.isBlocked, isTrue);
      expect(report.blockedReason, contains('没有可执行的探测候选'));
      expect(transport.requests, isEmpty, reason: '一个请求都不该发');
    });

    test('请求**没发出去**（配置问题）⇒ notSent，绝不报成网络故障', () async {
      // 声明了敏感请求头却没凭据：读取口一律返回 null ⇒ 构造请求时明确失败。
      final template = OnlineMusicProviderTemplate(
        id: 'needs-secret-header',
        label: '需要敏感头',
        search: OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/search',
            headers: [
              OnlineMusicHeaderSpec(
                name: 'X-Secret',
                value: '',
                credentialReference: 'a/b/c',
              ),
            ],
          ),
          response: OnlineMusicResponseSpec(
            listPath: JsonPath.tryParse('data')!,
            fields: {
              OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
                candidates: [JsonPath.tryParse('id')!],
                transform: OnlineMusicFieldTransform.asString,
              ),
            },
          ),
        ),
      );

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: templateCandidates([template]),
      );

      final outcome = report.outcomes.single;
      expect(outcome.status, ProviderProbeStatus.notSent);
      expect(outcome.failureKind, isNull, reason: '没发出去 ⇒ 不给出"网络"分类');
      expect(outcome.failureReason, isNotNull);
      expect(transport.requests, isEmpty);
      expect(report.didNotSendAnyRequest, isTrue);
    });

    test('多候选：按顺序各打一次，每个候选**最多一个**请求', () async {
      // 一份响应同时满足两个候选的判定与映射（chksz 用 code/data.songs，msapi 用 result.songs）。
      transport.responder = (options) async => {
        'code': 200,
        'data': {
          'songs': [
            {'id': 1, 'name': 'x', 'artists': 'a', 'duration': 1},
          ],
        },
        'result': {
          'songs': [
            {
              'id': 2,
              'name': 'y',
              'artists': [
                {'id': 1, 'name': 'b'},
              ],
            },
          ],
        },
      };
      final templates = onlineMusicProviderTemplates();
      final candidates = [
        ProviderProbeCandidate(
          id: 'user:search',
          label: '条目自身配置',
          binding: templates.first.search,
          capability: OnlineMusicCapability.search,
          source: ProviderProbeCandidateSource.userConfig,
        ),
        ProviderProbeCandidate(
          id: 'user:newSongs',
          label: '条目自身配置',
          binding: templates.last.search,
          capability: OnlineMusicCapability.newSongs,
          source: ProviderProbeCandidateSource.userConfig,
        ),
      ];

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: candidates,
      );

      // D-F3-5 第 4 条：**服务级**探测不因"支持多个能力"而重复打。
      expect(transport.requests, hasLength(2));
      expect(
        report.outcomes.map((outcome) => outcome.capability),
        [OnlineMusicCapability.search, OnlineMusicCapability.newSongs],
      );
      expect(
        report.outcomes.map((outcome) => outcome.source),
        everyElement(ProviderProbeCandidateSource.userConfig),
      );
      expect(
        report.outcomes.map((outcome) => outcome.sourceLabel),
        everyElement(contains('条目自身配置')),
      );
    });

    test('超出请求预算的候选记为"未尝试"，不误报为验证失败（D-F3-5 第 5 条）', () async {
      transport.responder = (options) async => const {'nope': true};
      final candidates = [
        for (var index = 0; index < providerProbeMaxRequests + 1; index++)
          ProviderProbeCandidate(
            id: 'user:$index',
            label: '条目自身配置',
            binding: onlineMusicProviderTemplates().first.search,
            capability: OnlineMusicCapability.search,
            source: ProviderProbeCandidateSource.userConfig,
          ),
      ];

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: candidates,
      );

      // 预算上限仍然是 4（P4），第 5 个候选不得被尝试、也不得给出失败分类。
      expect(transport.requests, hasLength(providerProbeMaxRequests));
      final last = report.outcomes.last;
      expect(last.status, ProviderProbeStatus.notAttempted);
      expect(last.notAttemptedReason, contains('预算'));
      expect(last.failureKind, isNull);
    });

    test('传输失败带上**结构化详情**：超时 ≠ 连不上 ≠ 域名打错（D-F3-4）', () async {
      transport.error = DioException(
        requestOptions: RequestOptions(path: '/search'),
        type: DioExceptionType.connectionTimeout,
      );

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: noHeaderCredentials,
        platform: MusicPlatform.netease,
        candidates: templateCandidates([onlineMusicProviderTemplates().first]),
      );

      final outcome = report.outcomes.single;
      expect(outcome.status, ProviderProbeStatus.attempted);
      expect(
        outcome.failureKind,
        OnlineMusicErrorKind.network,
        reason: 'D-F3-4：顶层类别不变，超时仍在既有传输失败大类下',
      );
      expect(
        outcome.transportFailure,
        DeclarativeTransportFailure.timeout,
        reason: '但**底层类型**必须真的读出来',
      );
      expect(outcome.failureReason, contains('超时'));
      expect(
        outcome.failureReason,
        isNot(contains('不可达')),
        reason: 'P-50：不得再把超时说成笼统的"网络不可达"',
      );
    });

    test('源码守卫：探测不得再长出"第二套分类"', () {
      // 审计点名的"第四处分类逻辑"就是这样长出来的：探测自带 401/403 判断、
      // 自带成功判定、自带兜底 `catch (_)`。这里用源码扫描把它钉死 ——
      // 一旦有人再写一遍，这个测试就会红。
      final source = File(
        'lib/services/music_platform/declarative/provider_probe.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('executeDeclarativeRequest'),
        reason: 'F3-S1：探测必须走共享执行引擎',
      );
      for (final forbidden in const [
        'declarativeResponseIsSuccess', // 成功判定只允许在引擎里出现
        'classifyHttpStatus', // 分类只允许在引擎里出现
        'statusCode == 401', // 认证判断只允许由统一表得出
        'statusCode == 403',
        'catch (_) {', // 兜底吞异常会再次把配置错误误诊成网络故障
      ]) {
        expect(
          source,
          isNot(contains(forbidden)),
          reason: '探测不得自带分类：$forbidden',
        );
      }
    });
  });
}

final class _FakeProbeTransport implements DeclarativeHttpTransport {
  final List<BuiltDeclarativeRequest> requests = [];
  int statusCode = 200;

  /// 非空时所有发送都以该异常失败（F3-S2：用来覆盖传输异常分类）。
  Object? error;

  /// 响应体故意放宽成 `Object?`：F3-S1 要覆盖"**不可读**响应"（HTML 错误页/纯文本）
  /// 与"可读 JSON"的分类差异，而真实服务端确实会回这些东西。
  Future<Object?> Function(RequestOptionsLike options) responder =
      (options) async => const {};

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    final failure = error;
    if (failure != null) throw failure;
    final body = await responder(_Options(request));
    return DeclarativeHttpResponse(statusCode: statusCode, data: body);
  }
}

/// 让假传输层的 responder 拿到与 Dio 近似的视图（path + query）。
abstract class RequestOptionsLike {
  String get path;
  Map<String, dynamic> get queryParameters;
}

final class _Options implements RequestOptionsLike {
  _Options(this.request);

  final BuiltDeclarativeRequest request;

  @override
  String get path => request.path;

  @override
  Map<String, dynamic> get queryParameters => request.query;
}

/// 探测要求注入"敏感请求头凭据读取口"（F3-S1：与试跑共用同一条执行路径）。
///
/// 本文件的候选都没有敏感请求头，因此给一个"一律读不到"的读取口即可 ——
/// 而且它是 **fail-closed** 的：真有敏感头却没读到值时，构造请求会明确失败。
const OnlineMusicCredentialReader noHeaderCredentials = _NoHeaderCredentials();

final class _NoHeaderCredentials implements OnlineMusicCredentialReader {
  const _NoHeaderCredentials();

  @override
  Future<String?> readCredential(String reference) async => null;
}
/// 旧的 `templates:` 参数在 F3-S3 换成了**候选列表**（每个候选带来源与能力）。
/// 这些用例本来就是"拿模板当候选"，因此这里等价转换（来源如实标为兼容模板）。
List<ProviderProbeCandidate> templateCandidates([
  List<OnlineMusicProviderTemplate>? templates,
]) => [
  for (final template in templates ?? onlineMusicProviderTemplates())
    ProviderProbeCandidate.fromTemplate(template),
];