import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
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

  test('a netease-proxy service is recognised without any credential', () async {
    transport.responder = (options) async {
      expect(options.path, '/search');
      expect(options.queryParameters['keywords'], providerProbeKeyword);
      return _msapiBody;
    };

    final report = await probeDeclarativeSearch(
      transport: transport,
      platform: MusicPlatform.netease,
    );

    expect(report.draftTemplateId, 'netease-proxy');
    // ChkSz 模板需要凭据，因此探测按"需要认证"记录而不是发请求。
    final chkszOutcome = report.outcomes.firstWhere(
      (outcome) => outcome.candidateId == builtinOnlineMusicChkszId,
    );
    expect(chkszOutcome.needsAuthentication, isTrue);
    expect(chkszOutcome.failureReason, contains('需要凭据'));
    expect(transport.requests, hasLength(1));
  });

  test('401 and 403 are reported as "needs authentication"', () async {
    transport.statusCode = 401;
    transport.responder = (options) async => const {'message': 'unauthorized'};

    final report = await probeDeclarativeSearch(
      transport: transport,
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
      platform: MusicPlatform.netease,
      credential: 'chksz_KEY_TEST_ONLY',
      maxRequests: 1,
    );

    expect(transport.requests, hasLength(1));
    expect(report.outcomes, hasLength(1));
  });

  test('the total budget stops further probing and aggregates the rest', () async {
    transport.responder = (options) async => const {'nope': true};
    // 第一次检查就认为预算已用完。
    var calls = 0;
    final start = DateTime.utc(2026, 10, 5);
    DateTime clock() => start.add(Duration(seconds: calls++ * 60));

    final report = await probeDeclarativeSearch(
      transport: transport,
      platform: MusicPlatform.netease,
      clock: clock,
    );

    expect(transport.requests, isEmpty);
    expect(
      report.outcomes.map((outcome) => outcome.failureReason),
      everyElement(contains('探测预算已用完')),
    );
  });

  test('every candidate failing yields no draft but a full report', () async {
    transport.statusCode = 500;
    transport.responder = (options) async => const {'oops': true};

    final report = await probeDeclarativeSearch(
      transport: transport,
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
}

final class _FakeProbeTransport implements DeclarativeHttpTransport {
  final List<BuiltDeclarativeRequest> requests = [];
  int statusCode = 200;
  Future<Map<String, Object?>> Function(RequestOptionsLike options) responder =
      (options) async => const {};

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
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
