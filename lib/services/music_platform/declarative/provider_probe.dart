/// 受控主动探测（Spec §4 的 P1–P10）。
///
/// 它只做一件事：把**编译期闭集**里的候选各试一次，把结果聚合成报告，并给出最高分的
/// 可编辑初稿。它不是"自动理解任意 API"，也不做开放式扫描。
///
/// 硬约束（逐条对应 Spec）：
/// - P1 以单个能力为单位（第一阶段只有 search）；
/// - P2/P7 候选只来自 [onlineMusicProviderTemplates]（闭集、不接受用户自定义）；
/// - P3 串行、不重试、不跟随跨主机重定向（传输层由调用方以 followRedirects:false 构造）；
/// - P4 每个请求用条目自身的超时；总预算到期立即停止并聚合；
/// - P5 不携带**必须**的凭据：已配置的凭据会被使用，但没有凭据也照样探测，
///   并把 401/403 记为"需要认证"；
/// - P6 所有候选路径只拼在用户提供的 baseUrl 上（传输层持有该 baseUrl）；
/// - P8 失败聚合进报告，不抛异常；
/// - P9/P10 不读写偏好与凭据存储；产出只是草稿，是否保存由调用方决定。
library;

import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// 单次探测的硬上限（P2/P3/P4）。
const providerProbeMaxRequests = 4;
const providerProbeTotalBudget = Duration(seconds: 30);

/// 探测用的固定输入：只取一条，足以判断"能不能解析出曲目"。
const providerProbeKeyword = 'listenary';
const providerProbeLimit = 1;

final class ProviderProbeOutcome {
  const ProviderProbeOutcome({
    required this.candidateId,
    required this.label,
    required this.score,
    this.statusCode,
    this.mappedTrackCount = 0,
    this.needsAuthentication = false,
    this.failureReason,
  });

  final String candidateId;
  final String label;

  /// 2 = 可用；1 = 部分可用（能取到列表但字段映射不全）；0 = 不可用。
  final int score;

  final int? statusCode;
  final int mappedTrackCount;

  /// 401/403 或"需要凭据但没配置"。
  final bool needsAuthentication;

  /// 非敏感说明（不含响应体内容）。
  final String? failureReason;

  @override
  String toString() =>
      'ProviderProbeOutcome($candidateId, score=$score, status=$statusCode)';
}

final class ProviderProbeReport {
  const ProviderProbeReport({
    required this.outcomes,
    this.draft,
    this.draftTemplateId,
  });

  final List<ProviderProbeOutcome> outcomes;

  /// 最高分候选生成的初稿；全部分数为 0 时为 null（进入手工配置）。
  final OnlineMusicDeclarativeCapabilityBinding? draft;
  final String? draftTemplateId;

  bool get hasDraft => draft != null;

  bool get anyNeedsAuthentication =>
      outcomes.any((outcome) => outcome.needsAuthentication);
}

/// 探测 search 能力。
///
/// [credential] 是**已经配置好**的凭据值（可以为 null）。探测不会因为缺它而拒绝执行。
Future<ProviderProbeReport> probeDeclarativeSearch({
  required DeclarativeHttpTransport transport,
  required MusicPlatform platform,
  List<OnlineMusicProviderTemplate>? templates,
  String? credential,
  OnlineMusicCancelToken? cancelToken,
  DateTime Function()? clock,
  Duration totalBudget = providerProbeTotalBudget,
  int maxRequests = providerProbeMaxRequests,
  String keyword = providerProbeKeyword,
  int limit = providerProbeLimit,
}) async {
  final now = clock ?? DateTime.now;
  final startedAt = now();
  final token = cancelToken ?? OnlineMusicCancelToken();
  final candidates = (templates ?? onlineMusicProviderTemplates())
      .take(maxRequests)
      .toList(growable: false);

  final outcomes = <ProviderProbeOutcome>[];
  OnlineMusicProviderTemplate? best;
  var bestScore = 0;

  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    if (now().difference(startedAt) >= totalBudget) {
      for (final skipped in candidates.skip(index)) {
        outcomes.add(
          ProviderProbeOutcome(
            candidateId: skipped.id,
            label: skipped.label,
            score: 0,
            failureReason: '探测预算已用完，未尝试该候选',
          ),
        );
      }
      break;
    }
    if (token.isCancelled) {
      outcomes.add(
        ProviderProbeOutcome(
          candidateId: candidate.id,
          label: candidate.label,
          score: 0,
          failureReason: '探测已取消',
        ),
      );
      break;
    }

    final outcome = await _probeCandidate(
      transport: transport,
      template: candidate,
      platform: platform,
      credential: credential,
      cancelToken: token,
      keyword: keyword,
      limit: limit,
    );
    outcomes.add(outcome);
    if (outcome.score > bestScore) {
      bestScore = outcome.score;
      best = candidate;
    }
  }

  return ProviderProbeReport(
    outcomes: List.unmodifiable(outcomes),
    draft: best?.search,
    draftTemplateId: best?.id,
  );
}

Future<ProviderProbeOutcome> _probeCandidate({
  required DeclarativeHttpTransport transport,
  required OnlineMusicProviderTemplate template,
  required MusicPlatform platform,
  required String? credential,
  required OnlineMusicCancelToken cancelToken,
  required String keyword,
  required int limit,
}) {
  final binding = template.search;
  final spec = binding.request;

  // P5：认证是"可选使用"而不是"必须先有"。没有凭据时不带凭据发一次，
  // 由服务端告诉我们它是否需要认证。
  final needsCredential = spec.auth is! OnlineMusicNoAuthPlacement;
  if (needsCredential && (credential == null || credential.isEmpty)) {
    return Future.value(
      ProviderProbeOutcome(
        candidateId: template.id,
        label: template.label,
        score: 0,
        needsAuthentication: true,
        failureReason: '该接口需要凭据；配置后重新探测即可自动生成初稿',
      ),
    );
  }

  final inputs = DeclarativeInputs(
    keyword: keyword,
    limit: limit,
    offset: 0,
    page: 1,
  );

  return _send(
    transport: transport,
    template: template,
    binding: binding,
    inputs: inputs,
    credential: credential,
    platform: platform,
    cancelToken: cancelToken,
    limit: limit,
  );
}

Future<ProviderProbeOutcome> _send({
  required DeclarativeHttpTransport transport,
  required OnlineMusicProviderTemplate template,
  required OnlineMusicDeclarativeCapabilityBinding binding,
  required DeclarativeInputs inputs,
  required String? credential,
  required MusicPlatform platform,
  required OnlineMusicCancelToken cancelToken,
  required int limit,
}) async {
  try {
    final request = buildDeclarativeRequest(
      spec: binding.request,
      inputs: inputs,
      credential: credential,
    );
    final response = await transport.send(request, cancelToken: cancelToken);

    if (response.statusCode == 401 || response.statusCode == 403) {
      return ProviderProbeOutcome(
        candidateId: template.id,
        label: template.label,
        score: 0,
        statusCode: response.statusCode,
        needsAuthentication: true,
        failureReason: '该接口需要认证（HTTP ${response.statusCode}）',
      );
    }

    if (!declarativeResponseIsSuccess(
      spec: binding.response.success,
      statusCode: response.statusCode,
      body: response.data,
    )) {
      return ProviderProbeOutcome(
        candidateId: template.id,
        label: template.label,
        score: 0,
        statusCode: response.statusCode,
        failureReason: '成功判定未通过（HTTP ${response.statusCode}）',
      );
    }

    try {
      final page = mapDeclarativeSearchResponse(
        spec: binding.response,
        body: response.data,
        platform: platform,
        limit: limit,
        offset: 0,
      );
      if (page.items.isEmpty) {
        return ProviderProbeOutcome(
          candidateId: template.id,
          label: template.label,
          score: 0,
          statusCode: response.statusCode,
          failureReason: '响应成功但没有解析出任何曲目',
        );
      }
      return ProviderProbeOutcome(
        candidateId: template.id,
        label: template.label,
        score: 2,
        statusCode: response.statusCode,
        mappedTrackCount: page.items.length,
      );
    } on DeclarativeMappingException catch (error) {
      // 列表存在但字段映射不全：给 1 分，让用户拿到一个可继续编辑的初稿。
      final partial = _countListEntries(binding.response.listPath, response.data);
      return ProviderProbeOutcome(
        candidateId: template.id,
        label: template.label,
        score: partial > 0 ? 1 : 0,
        statusCode: response.statusCode,
        mappedTrackCount: partial,
        failureReason: '字段映射不完整：${error.reason}',
      );
    }
  } on DeclarativeRequestException catch (error) {
    return ProviderProbeOutcome(
      candidateId: template.id,
      label: template.label,
      score: 0,
      failureReason: error.safeMessage,
    );
  } catch (_) {
    return ProviderProbeOutcome(
      candidateId: template.id,
      label: template.label,
      score: 0,
      failureReason: '请求失败（网络或服务不可达）',
    );
  }
}

int _countListEntries(JsonPath? listPath, Object? body) {
  if (listPath == null) return 0;
  final value = listPath.read(body);
  return value is List ? value.length : 0;
}
