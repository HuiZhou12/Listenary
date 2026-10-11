import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_inputs.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_plan.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_verification.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// **F3-2a 验收**：探测的**每能力输入契约**（Spec §9.1 / §10 决策 5）。
///
/// 钉三件事：
/// 1. 输入**按能力**定义（搜索要关键词，榜单不要）—— 不再写死在探测函数顶部；
/// 2. **用了默认值必须如实披露**（结论是"在这个输入下"得到的）；
/// 3. **缺少必需输入 ⇒ 一个请求都不发**（宁可说"没试"，也不拿默认值替用户决定）。
void main() {
  group('输入契约（纯模型）', () {
    test('搜索：不填 ⇒ 用默认值，并**如实披露**', () {
      final resolved = resolveProbeInputs(
        OnlineMusicCapability.search,
        const DeclarativeProbeInputs(),
      );

      expect(resolved, isNotNull);
      expect(resolved!.keyword, probeDefaultKeyword);
      expect(resolved.limit, probeDefaultLimit);
      expect(resolved.usedAnyDefault, isTrue);
      expect(resolved.defaultedNotes, hasLength(2));
      expect(resolved.defaultedNotes.join('|'), contains('关键词使用默认值'));
      expect(resolved.defaultedNotes.join('|'), contains('每页数量使用默认值'));
    });

    test('搜索：**显式清空**关键词 ⇒ 缺必需输入（返回 null）', () {
      expect(
        resolveProbeInputs(
          OnlineMusicCapability.search,
          const DeclarativeProbeInputs(keyword: '   '),
        ),
        isNull,
      );
    });

    test('搜索：非法每页数量 ⇒ 返回 null（不拿荒谬的值去打服务端）', () {
      expect(
        resolveProbeInputs(
          OnlineMusicCapability.search,
          const DeclarativeProbeInputs(limit: 0),
        ),
        isNull,
      );
      expect(
        resolveProbeInputs(
          OnlineMusicCapability.search,
          const DeclarativeProbeInputs(limit: -3),
        ),
        isNull,
      );
    });

    test('搜索：填写后原样使用，且不再披露默认值', () {
      final resolved = resolveProbeInputs(
        OnlineMusicCapability.search,
        const DeclarativeProbeInputs(keyword: '海阔天空', limit: 5),
      );

      expect(resolved!.keyword, '海阔天空');
      expect(resolved.limit, 5);
      expect(resolved.defaultedNotes, isEmpty);
      expect(resolved.usedAnyDefault, isFalse);
    });

    test('榜单：**不需要**关键词（填了也忽略，不报错）', () {
      final resolved = resolveProbeInputs(
        OnlineMusicCapability.chartList,
        const DeclarativeProbeInputs(keyword: 'abc'),
      );

      expect(resolved, isNotNull);
      expect(resolved!.defaultedNotes.single, contains('每页数量'));
    });

    test('"缺哪个必需输入"的说明可读', () {
      expect(
        missingRequiredProbeInputName(
          OnlineMusicCapability.search,
          const DeclarativeProbeInputs(keyword: ''),
        ),
        '关键词',
      );
      expect(
        missingRequiredProbeInputName(
          OnlineMusicCapability.search,
          const DeclarativeProbeInputs(limit: 0),
        ),
        '每页数量',
      );
      expect(
        missingRequiredProbeInputName(
          OnlineMusicCapability.search,
          const DeclarativeProbeInputs(),
        ),
        isNull,
      );
    });
  });

  group('探测接线（真调用 probeDeclarativeSearch）', () {
    test('★ 缺必需输入 ⇒ 未尝试，且**一个请求都不发**', () async {
      final transport = _FakeTransport(explode: true);

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: _NoCredentialReader(),
        platform: MusicPlatform.netease,
        candidates: [_searchCandidate()],
        inputs: const DeclarativeProbeInputs(keyword: ' '),
      );

      expect(transport.calls, 0, reason: '缺必需输入时绝不发请求');
      final outcome = report.outcomes.single;
      expect(outcome.status, ProviderProbeStatus.notAttempted);
      expect(outcome.notAttemptedReason, contains('关键词'));
      expect(outcome.countsAsFailure, isFalse, reason: '"没试"不是"试过且失败"');
      expect(
        outcome.stageStatus(DeclarativeVerificationStage.config),
        DeclarativeVerificationStageStatus.notRun,
      );
      expect(report.hasDraft, isFalse);
    });

    test('默认输入被如实披露；请求确实发出（500 ⇒ 判定阶段失败）', () async {
      final transport = _FakeTransport(statusCode: 500);

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: _NoCredentialReader(),
        platform: MusicPlatform.netease,
        candidates: [_searchCandidate()],
      );

      expect(transport.calls, 1);
      expect(report.inputNotes.join('|'), contains('关键词使用默认值'));
      final outcome = report.outcomes.single;
      expect(outcome.confidence, DeclarativeVerificationConfidence.failed);
      expect(
        outcome.firstFailedStage,
        DeclarativeVerificationStage.judgement,
        reason: 'HTTP 500 到达 ⇒ 传输过了，卡在判定',
      );
    });

    test('显式输入：不再披露默认值', () async {
      final transport = _FakeTransport(statusCode: 500);

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: _NoCredentialReader(),
        platform: MusicPlatform.netease,
        candidates: [_searchCandidate()],
        inputs: const DeclarativeProbeInputs(keyword: 'x', limit: 3),
      );

      expect(transport.calls, 1);
      expect(report.inputNotes, isEmpty);
    });
  });
  group('F3-2c 兼容性过滤与可追溯', () {
    test('普通搜索候选：兼容（返回 null），且 provenance 可追溯', () {
      final candidate = _searchCandidate();

      expect(probeCandidateIncompatibility(candidate), isNull);
      expect(candidate.provenanceLabel, contains('搜索'));
      expect(candidate.provenanceLabel, contains(candidate.id));
    });

    test('路径带占位符 ⇒ 明确判定不兼容（原因可读）', () {
      final candidate = _candidateWithPath('/song/{trackId}');

      final reason = probeCandidateIncompatibility(candidate);
      expect(reason, isNotNull);
      expect(reason, contains('占位符'));
      expect(reason, contains('trackId'));
    });

    test('需要实体 ID 的能力（歌词）⇒ 明确判定不兼容', () {
      final candidate = ProviderProbeCandidate(
        id: 'user:lyric',
        label: '条目自身配置',
        source: ProviderProbeCandidateSource.userConfig,
        capability: OnlineMusicCapability.lyric,
        binding: OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(path: '/lyric'),
          response: OnlineMusicResponseSpec(
            listPath: JsonPath.tryParse('data'),
          ),
        ),
      );

      final reason = probeCandidateIncompatibility(candidate);
      expect(reason, isNotNull);
      expect(reason, contains('曲目 / 歌单 ID'));
    });

    test('★ 不兼容候选 ⇒ 未尝试、**不发请求**、原因写清楚', () async {
      final transport = _FakeTransport(explode: true);

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: _NoCredentialReader(),
        platform: MusicPlatform.netease,
        candidates: [_candidateWithPath('/song/{trackId}')],
      );

      expect(transport.calls, 0, reason: '不兼容的候选绝不消耗请求预算');
      final outcome = report.outcomes.single;
      expect(outcome.status, ProviderProbeStatus.notAttempted);
      expect(outcome.notAttemptedReason, contains('占位符'));
      expect(outcome.countsAsFailure, isFalse);
    });

    test('计划里如实列出"不会请求"的候选（不许看起来像测过但失败）', () {
      final plan = ProviderProbePlan(
        candidates: [_searchCandidate(), _candidateWithPath('/song/{trackId}')],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
      );

      expect(plan.incompatibleCandidateLines, hasLength(1));
      expect(plan.incompatibleCandidateLines.single, contains('→'));
      final text = plan.describe();
      expect(text, contains('不会请求：'));
      expect(text, contains('占位符'));
    });
  });
  group('R6：凭据不出现在任何对外文本里', () {
    const secret = 'SECRET_MUST_NOT_LEAK_ANYWHERE';

    test('★ 传输抛错时，错误文本/摘要/片段/toString 都不含凭据', () async {
      final transport = _FakeTransport(explode: true);
      ProviderProbeOutcome? outcome;
      Object? thrown;

      try {
        final report = await probeDeclarativeSearch(
          transport: transport,
          headerCredentialReader: _NoCredentialReader(),
          platform: MusicPlatform.netease,
          candidates: [_queryAuthCandidate()],
          credential: secret,
        );
        outcome = report.outcomes.single;
      } catch (error) {
        // 引擎若选择直接抛出，也算"对外文本"的一种 —— 一并检查。
        thrown = error;
      }

      final text = [
        outcome?.failureReason,
        outcome?.requestSummary,
        outcome?.responsePreview,
        outcome?.mappingIncompleteReason,
        outcome?.toString(),
        '$thrown',
      ].join(' ');
      expect(text.contains(secret), isFalse, reason: 'R6：任何对外文本都不得含凭据');
    });

    test('★ 凭据**确实**发给了服务端，但请求摘要里是 [redacted]（不是没发）', () async {
      final transport = _FakeTransport(statusCode: 500);

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: _NoCredentialReader(),
        platform: MusicPlatform.netease,
        candidates: [_queryAuthCandidate()],
        credential: secret,
      );

      // 1) 真的发出去了（否则这条测试就没证明力）。
      expect(transport.requests.single.query['apikey'], secret);
      // 2) 界面上看到的是遮蔽后的形态。
      final summary = report.outcomes.single.requestSummary ?? '';
      expect(summary, contains('apikey=[redacted]'));
      expect(summary.contains(secret), isFalse);
      // 3) 整个 outcome 的任何字段都不含它。
      expect(report.outcomes.single.toString().contains(secret), isFalse);
    });

    test('★ 响应体不整块保留：只留脱敏且截断的片段', () async {
      final transport = _FakeTransport(statusCode: 500);
      transport.responderBody = const {
        'code': 500,
        'msg': 'RAW_BODY_MARKER 不该出现在诊断字段里',
      };

      final report = await probeDeclarativeSearch(
        transport: transport,
        headerCredentialReader: _NoCredentialReader(),
        platform: MusicPlatform.netease,
        candidates: [_searchCandidate()],
      );

      final outcome = report.outcomes.single;
      for (final field in [
        outcome.failureReason,
        outcome.requestSummary,
        outcome.mappingIncompleteReason,
      ]) {
        expect(
          field ?? '',
          isNot(contains('RAW_BODY_MARKER')),
          reason: 'R6：原始响应体不得进入诊断文本字段',
        );
      }
    });
  });
}

ProviderProbeCandidate _queryAuthCandidate() => ProviderProbeCandidate(
  id: 'user:search',
  label: '条目自身配置',
  source: ProviderProbeCandidateSource.userConfig,
  capability: OnlineMusicCapability.search,
  binding: OnlineMusicDeclarativeCapabilityBinding(
    request: const OnlineMusicRequestSpec(
      path: '/search',
      auth: OnlineMusicQueryAuthPlacement(parameterName: 'apikey'),
    ),
    response: OnlineMusicResponseSpec(
      listPath: JsonPath.tryParse('data.songs'),
    ),
  ),
);

ProviderProbeCandidate _candidateWithPath(String path) =>
    ProviderProbeCandidate(
      id: 'user:search',
      label: '条目自身配置',
      source: ProviderProbeCandidateSource.userConfig,
      capability: OnlineMusicCapability.search,
      binding: OnlineMusicDeclarativeCapabilityBinding(
        request: OnlineMusicRequestSpec(path: path),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('data.songs'),
        ),
      ),
    );

ProviderProbeCandidate _searchCandidate() => ProviderProbeCandidate(
  id: 'user:search',
  label: '条目自身配置',
  source: ProviderProbeCandidateSource.userConfig,
  capability: OnlineMusicCapability.search,
  binding: OnlineMusicDeclarativeCapabilityBinding(
    request: const OnlineMusicRequestSpec(path: '/search'),
    response: OnlineMusicResponseSpec(
      listPath: JsonPath.tryParse('data.songs'),
    ),
  ),
);

final class _FakeTransport implements DeclarativeHttpTransport {
  _FakeTransport({this.statusCode = 200, this.explode = false});

  final int statusCode;
  final bool explode;
  int calls = 0;

  /// 记录**实际发出去**的请求（R6 要证明"发给服务端了、但报告里没有"）。
  final List<BuiltDeclarativeRequest> requests = [];

  /// 响应体（R6 的"不整块保留"用得上）。
  Object? responderBody;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    calls++;
    requests.add(request);
    if (explode) {
      throw StateError('这条路径不应该发出任何请求');
    }
    return DeclarativeHttpResponse(
      statusCode: statusCode,
      data: responderBody ?? const {'code': 500, 'msg': 'boom'},
    );
  }
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  @override
  Future<String?> readCredential(String reference) async => null;
}
