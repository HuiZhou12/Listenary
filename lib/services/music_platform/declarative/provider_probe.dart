/// 受控主动探测（Spec §4 的 P1–P10）。
///
/// 它只做一件事：把**候选**里的每一项各试一次，把结果聚合成报告，并给出最高分的
/// 可编辑初稿。它不是"自动理解任意 API"，也不做开放式扫描。
///
/// 硬约束（逐条对应 Spec）：
/// - P1 以**条目**为单位（服务级探测：baseUrl 可达性 + 协议基本形态，Spec §19.5）；
/// - P2/P7 候选由调用方按 D-F3-1 决定：**优先条目自身的声明式绑定**，
///   只有该条目尚无任何绑定时才用兼容模板（闭集，不做开放式扫描，也不新增插件机制）；
/// - P3 串行、不重试、不跟随跨主机重定向（传输层由调用方以 followRedirects:false 构造）；
/// - P4 每个请求用条目自身的超时；总预算到期立即停止并聚合；
/// - P5 不携带**必须**的凭据：已配置的凭据会被使用，但没有凭据也照样探测，
///   并把 401/403 记为"需要认证"；
/// - P6 所有候选路径只拼在用户提供的 baseUrl 上（传输层持有该 baseUrl）；
/// - P8 失败聚合进报告，不抛异常；
/// - P9/P10 不读写偏好与凭据存储；产出只是草稿，是否保存由调用方决定。
///
/// **F3-S1（P-07）**：执行与判定**不再自己实现** —— 构造请求、发送、成功判定、
/// 失败分类与脱敏诊断全部交给共享引擎
/// [executeDeclarativeRequest]（试跑走的是**同一条**路径）。此前这里的 401/403 判断、
/// 成功判定与兜底 `catch (_)` 是审计点名的"**第四处分类逻辑**"，已删除。
library;

import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_execution.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// 单次探测的硬上限（P2/P3/P4）。
const providerProbeMaxRequests = 4;
const providerProbeTotalBudget = Duration(seconds: 30);

/// 探测用的固定输入：只取一条，足以判断"能不能解析出曲目"。
const providerProbeKeyword = 'listenary';
const providerProbeLimit = 1;

/// 候选**来源**（D-F3-1 第 3 条：每个候选必须标明来源，不得混淆）。
enum ProviderProbeCandidateSource {
  /// 用户为该条目**自己配置**的声明式绑定。
  userConfig,

  /// 编译期**兼容模板**（只在该条目尚无任何声明式绑定时作为兜底）。
  compatibilityTemplate,
}

String providerProbeCandidateSourceLabel(ProviderProbeCandidateSource source) =>
    switch (source) {
      ProviderProbeCandidateSource.userConfig => '条目自身配置',
      ProviderProbeCandidateSource.compatibilityTemplate => '兼容模板',
    };

/// 一个**探测候选**：一条声明式绑定 + 它来自哪里 + 它验的是哪个能力。
///
/// D-F3-5 第 6 条：一次探测只能证明"**这个候选**的**这个能力**"发得出去、回得来、解析得出，
/// 因此来源与能力都必须跟着结论一起走（不能只报"探测成功"）。
final class ProviderProbeCandidate {
  const ProviderProbeCandidate({
    required this.id,
    required this.label,
    required this.binding,
    required this.capability,
    required this.source,
  });

  /// 从兼容模板构造候选（旧路径的等价形态；来源如实标为模板）。
  factory ProviderProbeCandidate.fromTemplate(
    OnlineMusicProviderTemplate template,
  ) => ProviderProbeCandidate(
    id: template.id,
    label: template.label,
    binding: template.search,
    capability: OnlineMusicCapability.search,
    source: ProviderProbeCandidateSource.compatibilityTemplate,
  );

  final String id;
  final String label;
  final OnlineMusicDeclarativeCapabilityBinding binding;

  /// 这个候选**实际验证**的能力。
  final OnlineMusicCapability capability;

  final ProviderProbeCandidateSource source;

  /// 界面上「来源（能力）」这一段，例如 `条目自身配置（搜索）`。
  String get sourceLabel =>
      '${providerProbeCandidateSourceLabel(source)}'
      '（${onlineMusicCapabilityLabel(capability)}）';

  @override
  String toString() =>
      'ProviderProbeCandidate($id, capability=${capability.name}, '
      'source=${source.name})';
}

/// 该候选**走到了哪一步**（D-F3-4 / D-F3-5：三种情形必须能分开）。
///
/// 特别是 [notAttempted]：**一个请求都没发**（预算耗尽 / 已取消 / 没有可执行候选），
/// 它**不是**"验证失败" —— 把它渲染成失败就是我们反复修的"谎称试过了"。
enum ProviderProbeStatus {
  /// 真的发出了一次请求（成或败见 [ProviderProbeOutcome.failureKind]）。
  attempted,

  /// **没有发出请求**：配置/凭据问题（请求构造失败、敏感头凭据读取失败）。
  notSent,

  /// **没有尝试**：预算耗尽 / 已取消 / 没有可执行候选。
  notAttempted,
}

final class ProviderProbeOutcome {
  const ProviderProbeOutcome({
    required this.candidateId,
    required this.label,
    required this.score,
    required this.source,
    required this.capability,
    this.status = ProviderProbeStatus.attempted,
    this.statusCode,
    this.mappedTrackCount = 0,
    this.needsAuthentication = false,
    this.failureReason,
    this.notAttemptedReason,
    this.failureKind,
    this.transportFailure,
    this.requestSummary,
    this.responsePreview,
  });

  final String candidateId;
  final String label;

  /// 该候选的**来源**与它实际验证的**能力**（D-F3-1 第 3 条 / D-F3-5 第 6 条）。
  final ProviderProbeCandidateSource source;
  final OnlineMusicCapability capability;

  /// 2 = 可用；1 = 部分可用（能取到列表但字段映射不全）；0 = 不可用。
  ///
  /// ⚠️ 它**只**描述探测所发的那一个请求的证据（D-F3-5）：不能证明该条目的全部能力。
  final int score;

  final ProviderProbeStatus status;

  final int? statusCode;
  final int mappedTrackCount;

  /// 401/403 或"需要凭据但没配置"。
  final bool needsAuthentication;

  /// 非敏感说明（不含响应体内容）。
  final String? failureReason;

  /// 未尝试的原因（仅 [ProviderProbeStatus.notAttempted]）。
  final String? notAttemptedReason;

  /// **统一判定表**给出的失败分类（F3-S1：与试跑同一套，不再自带第二套分类）。
  final OnlineMusicErrorKind? failureKind;

  /// 传输失败的**结构化详情**（F3-S2 / D-F3-4）：超时 / 无法连接 / DNS / TLS / 取消 /
  /// 非传输异常。顶层类别仍是 [failureKind]，这里只把底层真相说清楚。
  final DeclarativeTransportFailure? transportFailure;

  /// **已脱敏**的请求摘要（P-07：失败时它是唯一的排查依据）。
  final String? requestSummary;

  /// **已脱敏**的响应片段（P-07）。
  final String? responsePreview;

  /// 是否真的发出过请求。
  bool get wasAttempted => status != ProviderProbeStatus.notAttempted;

  /// 界面上「来源（能力）」这一段，例如 `条目自身配置（搜索）`。
  String get sourceLabel =>
      '${providerProbeCandidateSourceLabel(source)}'
      '（${onlineMusicCapabilityLabel(capability)}）';

  @override
  String toString() =>
      'ProviderProbeOutcome($candidateId, status=${status.name}, score=$score, '
      'statusCode=$statusCode, kind=${failureKind?.name})';
}

final class ProviderProbeReport {
  const ProviderProbeReport({
    required this.outcomes,
    this.draft,
    this.draftTemplateId,
    this.draftSource,
    this.draftCapability,
    this.blockedReason,
  });

  final List<ProviderProbeOutcome> outcomes;

  /// 最高分候选生成的初稿；全部分数为 0 时为 null（进入手工配置）。
  final OnlineMusicDeclarativeCapabilityBinding? draft;
  final String? draftTemplateId;

  /// 初稿来自哪里、验的是哪个能力（D-F3-5 第 6 条：结论必须带上来源与能力）。
  final ProviderProbeCandidateSource? draftSource;
  final OnlineMusicCapability? draftCapability;

  /// **整个探测被拦下**的原因（非 null 时 [outcomes] 必为空）。
  ///
  /// 两种情形，都不是"候选都没通过"：
  /// - 服务地址是用户显式提供的非法值（F0-3 / P-18）；
  /// - **没有任何可执行的候选**（D-F3-5：要明确报告"未尝试"，不得构造虚假成功）。
  /// 这两种情况都**一个请求都不发**，因此**绝不能**报成"我们试过了"（反模式 3/10）。
  final String? blockedReason;

  bool get isBlocked => blockedReason != null;

  bool get hasDraft => draft != null;

  bool get anyNeedsAuthentication =>
      outcomes.any((outcome) => outcome.needsAuthentication);

  /// 是否**一个请求都没发出去**（全部候选都是未尝试/未发出）。
  bool get didNotSendAnyRequest =>
      outcomes.every((outcome) => outcome.status != ProviderProbeStatus.attempted);
}

/// 按**给定的候选顺序**做一次服务级探测（D-F3-5：每个候选最多一个请求）。
///
/// 候选的**来源与顺序**由调用方决定（条目自身配置优先，模板仅作兼容兜底，见
/// `online_music_probe_candidates.dart`）—— 探测本身不查配置，只负责"按顺序试一遍并说清结论"。
///
/// [credential] 是**已经配置好**的凭据值（可以为 null）。探测不会因为缺它而拒绝执行。
Future<ProviderProbeReport> probeDeclarativeSearch({
  required DeclarativeHttpTransport transport,
  required OnlineMusicCredentialReader headerCredentialReader,
  required MusicPlatform platform,
  required List<ProviderProbeCandidate> candidates,
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
  // D-F3-5 第 5 条：保留请求预算上限。**不截断候选列表** —— 超预算的候选必须以
  // "未尝试：请求预算耗尽"出现在报告里（截掉它们等于悄悄少报了几个候选）。
  final requestBudget = maxRequests.clamp(1, providerProbeMaxRequests);
  var requestsIssued = 0;

  // D-F3-5：没有可执行候选 ⇒ 明确报告"未尝试"，**不构造**虚假的成功结果，
  // 也不谎称"候选都没通过"（那意味着我们试过了）。
  if (candidates.isEmpty) {
    return const ProviderProbeReport(
      outcomes: [],
      blockedReason: '没有可执行的探测候选（该条目没有声明式绑定，也没有匹配的兼容模板）',
    );
  }

  final outcomes = <ProviderProbeOutcome>[];
  ProviderProbeCandidate? best;
  var bestScore = 0;

  for (var index = 0; index < candidates.length; index++) {
    final candidate = candidates[index];
    if (requestsIssued >= requestBudget) {
      outcomes.add(_notAttempted(candidate, '未尝试：请求预算耗尽'));
      continue;
    }
    if (now().difference(startedAt) >= totalBudget) {
      outcomes.add(_notAttempted(candidate, '未尝试：探测总时限已用完'));
      continue;
    }
    if (token.isCancelled) {
      outcomes.add(_notAttempted(candidate, '未尝试：探测已被取消'));
      continue;
    }
    requestsIssued++;

    final outcome = await _probeCandidate(
      transport: transport,
      headerCredentialReader: headerCredentialReader,
      candidate: candidate,
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
    draft: best?.binding,
    draftTemplateId: best?.id,
    draftSource: best?.source,
    draftCapability: best?.capability,
  );
}

/// "未尝试"的统一构造（D-F3-5：它**不是**失败，因此不给分类、不给分数）。
ProviderProbeOutcome _notAttempted(
  ProviderProbeCandidate candidate,
  String reason,
) => ProviderProbeOutcome(
  candidateId: candidate.id,
  label: candidate.label,
  score: 0,
  source: candidate.source,
  capability: candidate.capability,
  status: ProviderProbeStatus.notAttempted,
  notAttemptedReason: reason,
);

Future<ProviderProbeOutcome> _probeCandidate({
  required DeclarativeHttpTransport transport,
  required OnlineMusicCredentialReader headerCredentialReader,
  required ProviderProbeCandidate candidate,
  required MusicPlatform platform,
  required String? credential,
  required OnlineMusicCancelToken cancelToken,
  required String keyword,
  required int limit,
}) {
  final binding = candidate.binding;
  final spec = binding.request;

  // P5：**不因为缺凭据而拒绝探测**。没有凭据时用「无认证」的副本发一次，
  // 让服务端自己回答（401/403 → 需要认证；200 且能解析 → 直接拿到初稿）。
  //
  // ⚠️ D-F3-2：剥离只发生在**这一次探测请求**上；初稿仍然保留模板自己的认证声明
  // （S4 会把"需要 Key（尚未配置）"的结论如实报出来）。
  final hasCredential = credential != null && credential.isNotEmpty;
  final probeSpec = hasCredential
      ? spec
      : OnlineMusicRequestSpec(
          verb: spec.verb,
          path: spec.path,
          query: spec.query,
          headers: spec.headers,
          body: spec.body,
          auth: const OnlineMusicNoAuthPlacement(),
        );

  final inputs = DeclarativeInputs(
    keyword: keyword,
    limit: limit,
    offset: 0,
    page: 1,
  );

  return _send(
    transport: transport,
    headerCredentialReader: headerCredentialReader,
    candidate: candidate,
    binding: binding,
    spec: probeSpec,
    inputs: inputs,
    credential: credential,
    platform: platform,
    cancelToken: cancelToken,
    limit: limit,
  );
}

Future<ProviderProbeOutcome> _send({
  required DeclarativeHttpTransport transport,
  required OnlineMusicCredentialReader headerCredentialReader,
  required ProviderProbeCandidate candidate,
  required OnlineMusicDeclarativeCapabilityBinding binding,
  required OnlineMusicRequestSpec spec,
  required DeclarativeInputs inputs,
  required String? credential,
  required MusicPlatform platform,
  required OnlineMusicCancelToken cancelToken,
  required int limit,
}) async {
  // F3-S1：**共享执行引擎**（与试跑同一条路径）—— 构造 → 发送 → 成功判定 → 分类 → 脱敏诊断。
  final execution = await executeDeclarativeRequest(
    spec: spec,
    success: binding.response.success,
    inputs: inputs,
    transport: transport,
    headerCredentialReader: headerCredentialReader,
    credential: credential,
    cancelToken: cancelToken,
  );

  if (execution.stage == DeclarativeExecutionStage.notSent) {
    // 请求**根本没发出去**（配置/凭据问题）⇒ 不能报成"网络或服务不可达"。
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      score: 0,
      source: candidate.source,
      capability: candidate.capability,
      status: ProviderProbeStatus.notSent,
      failureReason: execution.failureReason,
      requestSummary: execution.requestSummary,
    );
  }

  if (!execution.isSuccess) {
    final kind = execution.failureKind;
    final statusCode = execution.statusCode;
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      score: 0,
      source: candidate.source,
      capability: candidate.capability,
      statusCode: statusCode,
      // 401/403（或缺凭据）⇒ 如实报"需要认证"，绝不归成网络故障（D-F3-2）。
      needsAuthentication:
          kind == OnlineMusicErrorKind.notConfigured ||
          kind == OnlineMusicErrorKind.forbidden,
      failureKind: kind,
      transportFailure: execution.transportFailure,
      // 文案：**没有状态码**（传输失败/取消/非传输异常）时用引擎给出的**底层详情**
      // （F3-S2：超时 / 无法连接 / DNS / TLS / 取消 / 非传输异常），
      // 以前这里会写成"成功判定未通过（HTTP null）"，等于把网络问题说成了业务判定问题。
      // 有状态码时才用既有口径（认证 / 成功判定），分类仍取自**统一表**。
      failureReason: statusCode == null
          ? execution.failureReason
          : kind == OnlineMusicErrorKind.notConfigured ||
                kind == OnlineMusicErrorKind.forbidden
          ? '该接口需要认证（HTTP $statusCode）'
          : '成功判定未通过（HTTP $statusCode）',
      requestSummary: execution.requestSummary,
      responsePreview: execution.responsePreview,
    );
  }

  try {
    final page = mapDeclarativeSearchResponse(
      spec: binding.response,
      body: execution.body,
      platform: platform,
      limit: limit,
      offset: 0,
    );
    if (page.items.isEmpty) {
      return ProviderProbeOutcome(
        candidateId: candidate.id,
        label: candidate.label,
        score: 0,
        source: candidate.source,
        capability: candidate.capability,
        statusCode: execution.statusCode,
        failureReason: '响应成功但没有解析出任何曲目',
        requestSummary: execution.requestSummary,
        responsePreview: execution.responsePreview,
      );
    }
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      score: 2,
      source: candidate.source,
      capability: candidate.capability,
      statusCode: execution.statusCode,
      mappedTrackCount: page.items.length,
      requestSummary: execution.requestSummary,
      responsePreview: execution.responsePreview,
    );
  } on DeclarativeMappingException catch (error) {
    // 列表存在但字段映射不全：给 1 分，让用户拿到一个可继续编辑的初稿。
    final partial = _countListEntries(binding.response.listPath, execution.body);
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      score: partial > 0 ? 1 : 0,
      source: candidate.source,
      capability: candidate.capability,
      statusCode: execution.statusCode,
      mappedTrackCount: partial,
      failureReason: '字段映射不完整：${error.reason}',
      requestSummary: execution.requestSummary,
      responsePreview: execution.responsePreview,
    );
  }
}

int _countListEntries(JsonPath? listPath, Object? body) {
  if (listPath == null) return 0;
  final value = listPath.read(body);
  return value is List ? value.length : 0;
}
