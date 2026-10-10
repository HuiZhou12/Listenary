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
/// **F3 落地（S1–S7，按用户裁定的 D-F3-1…D-F3-5）**：
/// - 执行与判定**只有一份**：构造 / 发送 / 成功判定 / 失败分类 / 脱敏摘要与片段都在
///   [executeDeclarativeRequest]（`declarative_execution.dart`），探测与试跑共用；
///   本文件**不再自带**任何分类逻辑（有源码守卫盯着）。
/// - 候选由调用方给（`online_music_probe_candidates.dart`）：**条目自身绑定优先**，
///   只有条目完全没有声明式绑定时才用兼容模板，并如实标注来源（D-F3-1）。
/// - **服务级探测的可验能力范围**（按用户裁定修正）：优先 `search`；否则第一个已配置且
///   **不需要用户提供具体实体 ID**、能独立执行的能力 —— 目前为
///   `search` / `newSongs` / `playlistCollection` / `playlistCategories` / `chartList`。
///   不同能力**按各自的响应结构与映射结果判定**（不强制返回曲目列表）。
///   需要具体曲目 / 歌单 ID 的 `playlist` / `lyric` / `stream` **不作默认探针**，
///   也**绝不伪造 ID** ⇒ 交给试跑（Spec §19.5 的"探测 = 服务级 / 试跑 = 按能力"）。
/// - 缺凭据时只对**那一次请求**剥认证；这种探测**不计为可用、不产出初稿**，
///   并如实标注"需要 Key"（D-F3-2）。
/// - 结论用**三态**词表（`declarative_verification.dart`）：已验证可用 / 未能确认 /
///   验证失败 —— 空结果既不算可用，也不一律当映射失败（D-F3-3）。
library;

import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_execution.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_verification.dart';
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

/// **服务级探测**能验的能力（D-F3-5，按用户裁定修正）。
///
/// Spec §19.5：探测 = 服务级（baseUrl 可达性 + 协议基本形态），**不是**逐个能力验一遍。
/// 收进来的判据是两条（**不再要求"必须返回曲目列表"**）：
/// 1. **不需要用户提供具体实体 ID**（不需要 trackId / playlistId）；
/// 2. 能**独立执行**并给出有效的服务级证据（发一次真实请求 + 用**它自己的**响应结构
///    与映射结果判定 —— 曲目列表、歌单列表、歌单分类、榜单各自算数）。
///
/// 排除在默认探针之外的（按用户裁定第 3 条）：
/// - `playlist`（歌单详情）/ `lyric` / `stream` 都需要**具体实体 ID**
///   ⇒ 交给**试跑**（用户自己填 ID），**绝不伪造一个 ID 去探测**。
const probeCapableCapabilities = <OnlineMusicCapability>[
  // 优先 Search；其余按"无需 ID 即可独立执行"的集合给出（顺序即执行顺序）。
  OnlineMusicCapability.search,
  OnlineMusicCapability.newSongs,
  OnlineMusicCapability.playlistCollection,
  OnlineMusicCapability.playlistCategories,
  OnlineMusicCapability.chartList,
];

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
    this.mappedItemCount = 0,
    this.mappedUnit,
    this.needsAuthentication = false,
    this.credentialMissingForAuth = false,
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
  /// 解析出的**条目数**（按该能力自己的单位：曲目 / 歌单 / 分类 / 榜单…）。
  final int mappedItemCount;

  /// 上面那个数字的**单位**（不同能力不同；用户裁定第 2 条：各能力按自己的结构判定）。
  final String? mappedUnit;

  /// 401/403 或"需要凭据但没配置"。
  final bool needsAuthentication;

  /// **该候选声明了认证、而这次探测没有凭据可用**（D-F3-2）。
  ///
  /// 这种探测为了"不因为缺凭据就拒绝探测"而**剥掉了认证**（只作用于这一次请求），
  /// 因此即使服务端回了 200 且能解析，也**不能**算作"验证可用" ——
  /// 它只是"服务可能可达"，认证条件并未满足。初稿也不会由它生成
  /// （所以不会出现"探测成功但运行期恒 notConfigured"）。
  final bool credentialMissingForAuth;

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

  /// 这次探测的**结论可信度**（F3-S6 / D-F3-3，与试跑**同一套词表**）。
  ///
  /// - [DeclarativeVerificationConfidence.failed]：未尝试 / 请求没发出去 / 明确的失败；
  /// - [DeclarativeVerificationConfidence.unconfirmed]：认证条件未满足（服务可能可达，
  ///   但没证明能力可用）、响应有效但没解析出任何曲目（空结果）、或字段映射不全
  ///   （能取到列表，但不足以证明这份配置可用）；
  /// - [DeclarativeVerificationConfidence.verified]：解析出了曲目且字段/身份都通过。
  DeclarativeVerificationConfidence get confidence {
    if (status != ProviderProbeStatus.attempted) {
      return DeclarativeVerificationConfidence.failed;
    }
    if (credentialMissingForAuth) {
      return DeclarativeVerificationConfidence.unconfirmed;
    }
    if (failureKind != null) return DeclarativeVerificationConfidence.failed;
    if (mappedItemCount == 0) {
      // 响应有效但没有可验证的数据（空结果）⇒ 不能算"可用"。
      return DeclarativeVerificationConfidence.unconfirmed;
    }
    if (score < 2) {
      // 能取到列表但字段映射不全 ⇒ 同样不足以证明可用。
      return DeclarativeVerificationConfidence.unconfirmed;
    }
    return DeclarativeVerificationConfidence.verified;
  }

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
  // D-F3-2：**只**为这一次探测请求剥掉认证（初稿永远保留原声明，见调用方）。
  final authWithoutCredential =
      !hasCredential && spec.auth is! OnlineMusicNoAuthPlacement;
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
    authWithoutCredential: authWithoutCredential,
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
  required bool authWithoutCredential,
  required DeclarativeInputs inputs,
  required String? credential,
  required MusicPlatform platform,
  required OnlineMusicCancelToken cancelToken,
  required int limit,
}) async {
  // 用户裁定第 3 条：需要**具体曲目 / 歌单 ID** 的能力不作默认探针，
  // 且**绝不伪造 ID** —— 因此这里连请求都不发（候选策略本不该把它们放进来，
  // 这是纵深防线：万一日后有人改坏了候选策略，也不会"编一个 ID 去试探"）。
  if (!probeCapableCapabilities.contains(candidate.capability)) {
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      score: 0,
      source: candidate.source,
      capability: candidate.capability,
      status: ProviderProbeStatus.notAttempted,
      notAttemptedReason:
          '未尝试：该能力需要具体的曲目 / 歌单 ID，不适合服务级探测'
          '（请用「试跑」并自己填 ID；探测不会伪造 ID）',
    );
  }

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
      // F4-S8：**响应格式**类（2xx 却不是 JSON）改用引擎给出的**明确**说明 ——
      // 那比"成功判定未通过（HTTP 200）"更说明真实原因，也不会把人引去补字段配置。
      failureReason: statusCode == null
          ? execution.failureReason
          : kind == OnlineMusicErrorKind.endpointMismatch
          ? execution.failureReason
          : kind == OnlineMusicErrorKind.notConfigured ||
                kind == OnlineMusicErrorKind.forbidden
          ? '该接口需要认证（HTTP $statusCode）'
          : '成功判定未通过（HTTP $statusCode）',
      requestSummary: execution.requestSummary,
      responsePreview: execution.responsePreview,
    );
  }

  // F4-S8："2xx 却不是结构化 JSON"的判定**统一在共享引擎里做**
  //（`executeDeclarativeRequest`）⇒ 探测与试跑是同一套分类，这里不再重复判定。
  try {
    // 用户裁定第 2 条：**按候选自己的能力**判定响应 ——
    // 曲目列表 / 歌单列表 / 歌单分类 / 榜单各自用**自己的**结构与映射，
    // 不再强制要求"必须返回曲目列表"。
    final judged = _judgeProbeResponse(
      candidate: candidate,
      binding: binding,
      body: execution.body,
      platform: platform,
      limit: limit,
    );
    if (judged.count == 0) {
      return ProviderProbeOutcome(
        candidateId: candidate.id,
        label: candidate.label,
        score: 0,
        source: candidate.source,
        capability: candidate.capability,
        statusCode: execution.statusCode,
        needsAuthentication: authWithoutCredential,
        credentialMissingForAuth: authWithoutCredential,
        failureReason: authWithoutCredential
            ? '响应成功但没有解析出任何${judged.unit}；且认证条件**未满足**（该能力声明了认证，'
                  '这次探测没有凭据）：请先配置该条目的 Key 再探测'
            : '响应成功但没有解析出任何${judged.unit}',
        requestSummary: execution.requestSummary,
        responsePreview: execution.responsePreview,
      );
    }
    if (authWithoutCredential) {
      // D-F3-2：**服务可能可达，但认证条件未满足** ⇒ 不计为"可用"，也不产出初稿。
      // 这样就不会再有 P-06 的"探测成功、运行期恒 notConfigured"。
      return ProviderProbeOutcome(
        candidateId: candidate.id,
        label: candidate.label,
        score: 0,
        source: candidate.source,
        capability: candidate.capability,
        statusCode: execution.statusCode,
        mappedItemCount: judged.count,
        mappedUnit: judged.unit,
        needsAuthentication: true,
        credentialMissingForAuth: true,
        failureReason:
            '服务可能可达（HTTP ${execution.statusCode}，解析出 ${judged.count} ${judged.unit}），'
            '但认证条件**未满足**：该能力声明了认证，请先配置该条目的 Key 再探测',
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
      mappedItemCount: judged.count,
      mappedUnit: judged.unit,
      requestSummary: execution.requestSummary,
      responsePreview: execution.responsePreview,
    );
  } on DeclarativeMappingException catch (error) {
    // 列表存在但字段映射不全：给 1 分，让用户拿到一个可继续编辑的初稿。
    final partial = _countListEntries(binding.response.listPath, execution.body);
    // ⚠️ 认证未满足时连"部分可用"也不能说（那不是映射问题，而是根本没带凭据）⇒ 不计可用。
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      score: authWithoutCredential ? 0 : (partial > 0 ? 1 : 0),
      source: candidate.source,
      capability: candidate.capability,
      statusCode: execution.statusCode,
      mappedItemCount: partial,
      needsAuthentication: authWithoutCredential,
      credentialMissingForAuth: authWithoutCredential,
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

/// 按候选**自己的能力**判定这次响应（用户裁定第 2 条）。
///
/// 返回 `(解析出的条目数, 单位)`：单位随能力不同（首曲目 / 个歌单 / 个分类 / 个榜单），
/// 界面上也就不会把"歌单列表"说成"曲目"。映射失败时抛
/// [DeclarativeMappingException]（由调用方转成"映射不完整"）。
({int count, String unit}) _judgeProbeResponse({
  required ProviderProbeCandidate candidate,
  required OnlineMusicDeclarativeCapabilityBinding binding,
  required Object? body,
  required MusicPlatform platform,
  required int limit,
}) => switch (candidate.capability) {
  OnlineMusicCapability.search || OnlineMusicCapability.newSongs => (
    count: mapDeclarativeSearchResponse(
      spec: binding.response,
      body: body,
      platform: platform,
      limit: limit,
      offset: 0,
    ).items.length,
    unit: '首曲目',
  ),
  OnlineMusicCapability.playlistCollection => (
    count: mapDeclarativePlaylistCollectionResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: '个歌单',
  ),
  OnlineMusicCapability.chartList => (
    count: mapDeclarativePlaylistCollectionResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: '个榜单',
  ),
  OnlineMusicCapability.playlistCategories => (
    count: mapDeclarativePlaylistCategoriesResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: '个分类',
  ),
  // 需要具体实体 ID 的能力**不作为默认探针**（见 `probeCapableCapabilities`）。
  // 真走到这里说明候选策略被改坏了 ⇒ 明确失败，而不是硬套某个映射或伪造 ID。
  OnlineMusicCapability.playlist ||
  OnlineMusicCapability.lyric ||
  OnlineMusicCapability.stream => throw const DeclarativeMappingException(
    '该能力需要具体的曲目 / 歌单 ID，不适合服务级探测（请用「试跑」并自己填 ID）',
  ),
};
