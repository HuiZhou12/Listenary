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
import 'package:pure_music/services/music_platform/declarative/declarative_probe_contract.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_inputs.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// 单次探测的硬上限（P2/P3/P4）。
const providerProbeMaxRequests = 4;
const providerProbeTotalBudget = Duration(seconds: 30);

/// 探测默认输入的**唯一来源**（F3-2 起）：真正定义在
/// `declarative_probe_inputs.dart`，这里只是既有调用点的别名，避免两处默认值漂移。
const providerProbeKeyword = probeDefaultKeyword;
const providerProbeLimit = probeDefaultLimit;

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

  /// **可追溯**的候选标识（F3-2c / Spec §9.2）：来源 + 能力 + 候选 id。
  ///
  /// 报告与计划都用它 —— 用户要能回答"这条结论是**哪个候选**给的"，
  /// 而不是只看到一句"探测成功"。
  String get provenanceLabel => '$sourceLabel · $id';

  @override
  String toString() =>
      'ProviderProbeCandidate($id, capability=${capability.name}, '
      'source=${source.name})';
}

/// **服务级探测**能验的能力（D-F3-5，按用户裁定修正）。
///
/// **服务级探测**能验哪些能力、结果怎么计数 —— 见 `declarative_probe_contract.dart`。
///
/// F3-4：这张表**只有一份**（契约），`probeCapableCapabilities` 与映射单位都从它派生；
/// 以前这里另存一份能力列表、`_judgeProbeResponse` 里再写一份单位字面量，
/// 新增能力时漏改一处就会出现"能探但不会计数"。

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
    this.mappingIncompleteReason,
    this.requestSummary,
    this.responsePreview,
  });

  final String candidateId;
  final String label;

  /// 该候选的**来源**与它实际验证的**能力**（D-F3-1 第 3 条 / D-F3-5 第 6 条）。
  final ProviderProbeCandidateSource source;
  final OnlineMusicCapability capability;

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

  /// 阶段④（映射）**不完整**的原因：缺哪些字段 / 哪条路径读不出（F3-1 / R3）。
  ///
  /// 这是 `unconfirmed` 的**证据**：只有"未能确认"是没用的，用户要知道差哪一项。
  final String? mappingIncompleteReason;

  /// 传输失败的**结构化详情**（F3-S2 / D-F3-4）：超时 / 无法连接 / DNS / TLS / 取消 /
  /// 非传输异常。顶层类别仍是 [failureKind]，这里只把底层真相说清楚。
  final DeclarativeTransportFailure? transportFailure;

  /// **已脱敏**的请求摘要（P-07：失败时它是唯一的排查依据）。
  final String? requestSummary;

  /// **已脱敏**的响应片段（P-07）。
  final String? responsePreview;

  /// 是否真的发出过请求。
  bool get wasAttempted => status != ProviderProbeStatus.notAttempted;

  /// 这个候选是否**算作失败**（F3-1 / Spec §13.4.2）。
  ///
  /// `notAttempted`（预算耗尽 / 无候选 / 已取消）**不算失败** —— 本片修掉的一处真实缺陷：
  /// 此前 [confidence] 把"一个请求都没发"直接归成 `failed`，等于把"没试"说成"试过且失败"。
  bool get countsAsFailure =>
      status == ProviderProbeStatus.notSent || failureKind != null;

  /// 单个阶段的结论（F3-1 的**四阶段状态机**）。
  DeclarativeVerificationStageStatus stageStatus(
    DeclarativeVerificationStage stage,
  ) {
    // 一个请求都没发 ⇒ **四个阶段都没轮到**（不是失败）。
    if (status == ProviderProbeStatus.notAttempted) {
      return DeclarativeVerificationStageStatus.notRun;
    }
    switch (stage) {
      case DeclarativeVerificationStage.config:
        // 请求都没构造出来 ⇒ 问题在配置（凭据 / 敏感头 / 参数绑定）。
        return status == ProviderProbeStatus.notSent
            ? DeclarativeVerificationStageStatus.failed
            : DeclarativeVerificationStageStatus.passed;
      case DeclarativeVerificationStage.transport:
        if (status == ProviderProbeStatus.notSent) {
          return DeclarativeVerificationStageStatus.notRun;
        }
        // 没有状态码 ⇒ 压根没拿到响应（超时 / DNS / 连接 / TLS / 取消）。
        return statusCode == null
            ? DeclarativeVerificationStageStatus.failed
            : DeclarativeVerificationStageStatus.passed;
      case DeclarativeVerificationStage.judgement:
        if (status == ProviderProbeStatus.notSent || statusCode == null) {
          return DeclarativeVerificationStageStatus.notRun;
        }
        // 有状态码却有失败分类 ⇒ 成功判定没过（含"2xx 但响应不可读"）。
        return failureKind != null
            ? DeclarativeVerificationStageStatus.failed
            : DeclarativeVerificationStageStatus.passed;
      case DeclarativeVerificationStage.mapping:
        if (status == ProviderProbeStatus.notSent ||
            statusCode == null ||
            failureKind != null) {
          return DeclarativeVerificationStageStatus.notRun;
        }
        return mappingIncompleteReason != null
            ? DeclarativeVerificationStageStatus.failed
            : DeclarativeVerificationStageStatus.passed;
    }
  }

  /// **第一个失败的阶段**（都通过或未尝试 ⇒ null）。
  ///
  /// 界面据此说"卡在哪一步"，而不是把四种完全不同的原因混成一句"候选未通过"。
  DeclarativeVerificationStage? get firstFailedStage {
    for (final stage in DeclarativeVerificationStage.values) {
      if (stageStatus(stage) == DeclarativeVerificationStageStatus.failed) {
        return stage;
      }
    }
    return null;
  }

  /// 这次探测的**结论可信度**（F3-S6 / D-F3-3，与试跑**同一套词表**）。
  ///
  /// - [DeclarativeVerificationConfidence.failed]：请求没发出去（配置问题）或明确的失败；
  /// - [DeclarativeVerificationConfidence.unconfirmed]：**未尝试**（预算耗尽 / 取消 / 无候选）、
  ///   认证条件未满足（服务可能可达，但没证明能力可用）、响应有效但没解析出任何条目
  ///   （空结果）、或字段映射不全（能取到列表，但不足以证明这份配置可用）；
  /// - [DeclarativeVerificationConfidence.verified]：解析出了条目且字段/身份都通过。
  ///
  /// ⚠️ "未尝试"必须靠 [status] / [notAttemptedReason] / [stageStatus] 读，**不能**靠
  /// `confidence == failed` 判定；需要"是否算失败"时一律用 [countsAsFailure]。
  DeclarativeVerificationConfidence get confidence {
    // F3-1：`notAttempted` **不是失败**（D-F3-5）—— 三态里没有"没试过"这一档，
    // 因此归到"未能确认"，并由 `notAttemptedReason` 与阶段状态说明真相。
    if (status == ProviderProbeStatus.notAttempted) {
      return DeclarativeVerificationConfidence.unconfirmed;
    }
    if (status == ProviderProbeStatus.notSent) {
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
    // F3-1 / R4：判据从"分数 < 2"改为**映射是否真的不完整** —— 不再让数分决定结论。
    if (mappingIncompleteReason != null) {
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
      'ProviderProbeOutcome($candidateId, status=${status.name}, '
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
    this.inputNotes = const [],
  });

  final List<ProviderProbeOutcome> outcomes;

  /// 本次探测**用了哪些默认输入**的如实说明（F3-2 / Spec §10 决策 5）。
  ///
  /// 为什么必须有：结论是"在这个输入下"得到的。不说清输入，用户会把它当成
  /// 对任意输入都成立的结论（旧实现把关键词写死 `listenary` 且不声明）。
  final List<String> inputNotes;

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
  bool get didNotSendAnyRequest => outcomes.every(
    (outcome) => outcome.status != ProviderProbeStatus.attempted,
  );

  /// **阶段汇总**（F3-3c / Spec §13.3 "阶段汇总"）：把逐候选结论收成一句可解释的话。
  ProviderProbeSummary get summary => providerProbeSummaryOf(outcomes);
}

/// 一次探测的**汇总结论**（F3-3c）。
///
/// 为什么需要它：逐候选明细回答了"每个候选怎么了"，但用户真正要的是
/// "**这次探测到底证明了什么、卡在哪一步、为什么推荐它**"。
/// 汇总只做**计数与归因**，不重新判定任何东西（判定仍在共享执行引擎里）。
final class ProviderProbeSummary {
  const ProviderProbeSummary({
    required this.verifiedCount,
    required this.unconfirmedCount,
    required this.failedCount,
    required this.notAttemptedCount,
    required this.failedStageCounts,
    this.recommendedProvenance,
    this.recommendationReason,
  });

  final int verifiedCount;
  final int unconfirmedCount;
  final int failedCount;
  final int notAttemptedCount;

  /// 各**失败阶段**的候选数（"卡在哪一步"的分布）。
  final Map<DeclarativeVerificationStage, int> failedStageCounts;

  /// 被推荐为初稿的候选（可追溯标识），没有则为 null。
  final String? recommendedProvenance;

  /// 推荐它的**理由**（可解释，绝不写"分数最高"）。
  final String? recommendationReason;

  bool get hasRecommendation => recommendedProvenance != null;

  /// 一句话结论（界面直接显示；**不含任何凭据值**）。
  String describe() {
    if (verifiedCount == 0 &&
        unconfirmedCount == 0 &&
        failedCount == 0 &&
        notAttemptedCount == 0) {
      return '本次没有候选（未发出任何请求）';
    }
    final parts = <String>[
      if (verifiedCount > 0) '$verifiedCount 个已验证可用',
      if (unconfirmedCount > 0) '$unconfirmedCount 个未能确认',
      if (failedCount > 0) '$failedCount 个验证失败',
      if (notAttemptedCount > 0) '$notAttemptedCount 个未尝试',
    ];
    final buffer = StringBuffer('结论：${parts.join(' / ')}');
    if (failedStageCounts.isNotEmpty) {
      final stages = [
        for (final entry in failedStageCounts.entries)
          '${declarativeVerificationStageLabel(entry.key)}×${entry.value}',
      ];
      buffer.write('；卡点：${stages.join('、')}');
    }
    if (recommendedProvenance != null) {
      buffer.write('；推荐「$recommendedProvenance」');
      if (recommendationReason != null) {
        buffer.write('（$recommendationReason）');
      }
    }
    return buffer.toString();
  }

  @override
  String toString() =>
      'ProviderProbeSummary(verified=$verifiedCount, '
      'unconfirmed=$unconfirmedCount, failed=$failedCount, '
      'notAttempted=$notAttemptedCount, recommended=$recommendedProvenance)';
}

/// 由逐候选结论生成汇总（纯函数，便于单独断言）。
ProviderProbeSummary providerProbeSummaryOf(
  List<ProviderProbeOutcome> outcomes,
) {
  var verified = 0;
  var unconfirmed = 0;
  var failed = 0;
  var notAttempted = 0;
  final failedStages = <DeclarativeVerificationStage, int>{};

  ProviderProbeOutcome? recommended;
  var recommendedRank = 0;

  for (final outcome in outcomes) {
    switch (outcome.status) {
      case ProviderProbeStatus.notAttempted:
        // "未尝试"**不是失败**，单独计数（D-F3-5）。
        notAttempted++;
      case ProviderProbeStatus.notSent:
        failed++;
      case ProviderProbeStatus.attempted:
        switch (outcome.confidence) {
          case DeclarativeVerificationConfidence.verified:
            verified++;
          case DeclarativeVerificationConfidence.unconfirmed:
            unconfirmed++;
          case DeclarativeVerificationConfidence.failed:
            failed++;
        }
    }
    final failedStage = outcome.firstFailedStage;
    if (failedStage != null) {
      failedStages[failedStage] = (failedStages[failedStage] ?? 0) + 1;
    }
    // 推荐依据 = 可解释的排序（F3-1/R4）；同一级取**先出现**的候选（顺序即优先级）。
    final rank = probeDraftRank(outcome);
    if (rank > recommendedRank) {
      recommendedRank = rank;
      recommended = outcome;
    }
  }

  return ProviderProbeSummary(
    verifiedCount: verified,
    unconfirmedCount: unconfirmed,
    failedCount: failed,
    notAttemptedCount: notAttempted,
    failedStageCounts: Map.unmodifiable(failedStages),
    // 与 `ProviderProbeCandidate.provenanceLabel` 同一形态（来源（能力）· 候选 id）。
    recommendedProvenance: recommended == null
        ? null
        : '${recommended.sourceLabel} · ${recommended.candidateId}',
    recommendationReason: switch (recommendedRank) {
      2 => '四阶段全通，必需输出齐',
      1 => '四阶段走通但映射不全，仍可作可编辑初稿',
      _ => null,
    },
  );
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
  DeclarativeProbeInputs inputs = const DeclarativeProbeInputs(),
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
  // F3-2：默认输入的如实披露（插入顺序 = 候选顺序 ⇒ 确定性）。
  final inputNotes = <String>{};
  ProviderProbeCandidate? best;
  var bestRank = 0;
  var bestSourceRank = 0;

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
    // F3-2c：**兼容性过滤**（来源优先级不等于可信）—— 不兼容的候选以"未尝试 + 原因"
    // 出现，绝不静默丢弃，也绝不消耗请求预算。
    final incompatible = probeCandidateIncompatibility(candidate);
    if (incompatible != null) {
      outcomes.add(_notAttempted(candidate, '未尝试：$incompatible'));
      continue;
    }
    // F3-2 / 决策 5：**缺少必需输入 ⇒ 不发请求**，并如实记"未尝试"。
    // 宁可说"没试"，也不拿默认值替用户决定（旧实现把关键词写死且不声明）。
    final resolvedInputs = resolveProbeInputs(candidate.capability, inputs);
    if (resolvedInputs == null) {
      final missing =
          missingRequiredProbeInputName(candidate.capability, inputs) ?? '输入';
      outcomes.add(_notAttempted(candidate, '未尝试：缺少必需的$missing（请填写后再探测）'));
      continue;
    }
    inputNotes.addAll(resolvedInputs.defaultedNotes);
    requestsIssued++;

    final outcome = await _probeCandidate(
      transport: transport,
      headerCredentialReader: headerCredentialReader,
      candidate: candidate,
      platform: platform,
      credential: credential,
      cancelToken: token,
      keyword: resolvedInputs.keyword,
      limit: resolvedInputs.limit,
    );
    outcomes.add(outcome);
    // F3-1 / R4：初稿候选按**可解释的排序**选（`probeDraftRank`）。
    // F3-3a：旧的 `score` 字段已**彻底移除** —— 它既不参与判定与推荐，
    // 也不再被任何界面显示，留着只会诱使后来者重新按"分高者胜"写逻辑。
    //（"分高者胜"既说不清为什么，也会让"字段多填了一点"压过"真的可用"）。
    final rank = probeDraftRank(outcome);
    if (rank == 0) continue;
    final sourceRank = outcome.source == ProviderProbeCandidateSource.userConfig
        ? 2
        : 1;
    if (rank > bestRank || (rank == bestRank && sourceRank > bestSourceRank)) {
      bestRank = rank;
      bestSourceRank = sourceRank;
      best = candidate;
    }
  }

  return ProviderProbeReport(
    outcomes: List.unmodifiable(outcomes),
    inputNotes: List.unmodifiable(inputNotes),
    draft: best?.binding,
    draftTemplateId: best?.id,
    draftSource: best?.source,
    draftCapability: best?.capability,
  );
}

/// 该候选**能否用于服务级探测**；不能则给出**可读原因**（F3-2c / Spec §9.2 的兼容性过滤）。
///
/// 为什么要"过滤而不是悄悄丢掉"：候选池里可能出现两种根本发不出去的候选 ——
/// ① 该能力需要实体 ID（服务级探测**绝不伪造 ID**）；② 请求路径带 `{占位符}`
/// 而探测没有任何 ID 输入可填。这两种都必须以**"未尝试 + 原因"**出现，
/// 而不是被静默剔除（用户会以为"它被测过并且失败了"）。
///
/// 优先级只决定顺序、**不代表可信**：来源再高也要过这一关。
String? probeCandidateIncompatibility(ProviderProbeCandidate candidate) {
  // F3-4：可探测性与原因都取自**能力契约**（文案只有那一份）。
  final notProbeable = probeNotProbeableReasonFor(candidate.capability);
  if (notProbeable != null) return notProbeable;
  final placeholders = RegExp(
    r'\{([^}]+)\}',
  ).allMatches(candidate.binding.request.path).map((m) => m.group(1)!).toList();
  if (placeholders.isNotEmpty) {
    return '该候选的请求路径需要占位符 '
        '${placeholders.map((name) => '{$name}').join('、')}，'
        '而服务级探测没有可提供的实体 ID';
  }
  return null;
}

/// 该候选**能否作为初稿**、以及它的可解释排序值（F3-1 / Spec §9.4 的 R4）。
///
/// - `0`：**不可作初稿** —— 未尝试 / 请求没发出去 / 明确失败 / 认证条件未满足 / 空结果；
/// - `1`：**部分可用** —— 能取到列表但字段映射不全（仍给用户一个可继续编辑的初稿）；
/// - `2`：**已验证可用** —— 四阶段全通且必需输出齐。
///
/// 调用方在**同级**时用"来源优先级（条目自身配置 > 兼容模板）→ 候选顺序"打破平手，
/// 因此推荐依据始终可以讲清楚，而不是"分数谁大"。
int probeDraftRank(ProviderProbeOutcome outcome) {
  if (outcome.status != ProviderProbeStatus.attempted) return 0;
  if (outcome.failureKind != null) return 0;
  if (outcome.credentialMissingForAuth) return 0;
  if (outcome.mappedItemCount == 0) return 0;
  return outcome.mappingIncompleteReason == null ? 2 : 1;
}

/// "未尝试"的统一构造（D-F3-5：它**不是**失败，因此不给分类、不给分数）。
ProviderProbeOutcome _notAttempted(
  ProviderProbeCandidate candidate,
  String reason,
) => ProviderProbeOutcome(
  candidateId: candidate.id,
  label: candidate.label,
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
  // F3-4：可探测性与原因都取自**能力契约**（文案只有那一份，见 `declarative_probe_contract.dart`）。
  final notProbeable = probeNotProbeableReasonFor(candidate.capability);
  if (notProbeable != null) {
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      source: candidate.source,
      capability: candidate.capability,
      status: ProviderProbeStatus.notAttempted,
      notAttemptedReason: '未尝试：$notProbeable',
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
    final partial = _countListEntries(
      binding.response.listPath,
      execution.body,
    );
    // ⚠️ 认证未满足时连"部分可用"也不能说（那不是映射问题，而是根本没带凭据）⇒ 不计可用。
    return ProviderProbeOutcome(
      candidateId: candidate.id,
      label: candidate.label,
      source: candidate.source,
      capability: candidate.capability,
      statusCode: execution.statusCode,
      mappedItemCount: partial,
      needsAuthentication: authWithoutCredential,
      credentialMissingForAuth: authWithoutCredential,
      failureReason: '字段映射不完整：${error.reason}',
      // F3-1 / R3：`unconfirmed` 必须带**证据**（缺哪条路径 / 哪个字段），
      // 否则用户只看到"未能确认"，不知道下一步改什么。
      mappingIncompleteReason: error.reason,
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
  // 艺人详情**需要实体 ID**（艺人 id 在请求里、不在响应里）⇒ 按既有设计它本就不参与
  // "服务级探测"（见 `probeInputRequirementFor` 把它归入"需要实体 ID"那一组）。
  // 这里**如实报错**，而不是假装能探测 ✓。
  OnlineMusicCapability.artist => throw UnsupportedError(
    '艺人详情需要艺人 ID，不参与服务级探测（请用「试跑」验证这份配置）',
  ),
  // 专辑详情同理：专辑 id 在请求里 ⇒ 不参与服务级探测，**如实报错** ✓。
  OnlineMusicCapability.album => throw UnsupportedError(
    '专辑详情需要专辑 ID，不参与服务级探测（请用「试跑」验证这份配置）',
  ),
  // 艺人专辑列表同理（艺人 id 在请求里 ✓）。
  OnlineMusicCapability.artistAlbums => throw UnsupportedError(
    '艺人专辑列表需要艺人 ID，不参与服务级探测（请用「试跑」验证这份配置）',
  ),
  // 艺人单曲列表同理 ✓。
  OnlineMusicCapability.artistSongs => throw UnsupportedError(
    '艺人单曲列表需要艺人 ID，不参与服务级探测（请用「试跑」验证这份配置）',
  ),
  // 搜索艺人：与"搜索专辑"同一套（数组类 ✓）⇒ 用艺人列表映射数一数 ✓。
  OnlineMusicCapability.searchArtists ||
  // 关注艺人与"搜索艺人"**同构**（都是艺人摘要数组 ✓）⇒ 复用同一个映射 ✓。
  OnlineMusicCapability.followedArtists => (
    count: mapDeclarativeArtistListResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: probeResultUnitFor(candidate.capability),
  ),
  // 搜索专辑：与"新专辑"同一套（数组类 ✓）⇒ 用专辑列表映射数一数 ✓。
  OnlineMusicCapability.searchAlbums => (
    count: mapDeclarativeAlbumListResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: probeResultUnitFor(candidate.capability),
  ),
  // 新专辑：**数组类**能力（服务端决定给什么 ✓）⇒ 用专辑列表映射数一数 ✓。
  OnlineMusicCapability.newAlbums => (
    count: mapDeclarativeAlbumListResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: probeResultUnitFor(candidate.capability),
  ),
  OnlineMusicCapability.search ||
  OnlineMusicCapability.newSongs ||
  // 推荐曲目与搜索/新歌**同构**（都是曲目数组 ✓）⇒ 探测复用同一个映射 ✓。
  OnlineMusicCapability.recommendedTracks => (
    count: mapDeclarativeSearchResponse(
      spec: binding.response,
      body: body,
      platform: platform,
      limit: limit,
      offset: 0,
    ).items.length,
    unit: probeResultUnitFor(candidate.capability),
  ),
  OnlineMusicCapability.playlistCollection ||
  // 推荐歌单：与"歌单列表"**同构**（都是歌单摘要数组 ✓）⇒ 探测复用同一个映射 ✓。
  OnlineMusicCapability.recommendedPlaylists => (
    count: mapDeclarativePlaylistCollectionResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: probeResultUnitFor(candidate.capability),
  ),
  OnlineMusicCapability.chartList => (
    count: mapDeclarativePlaylistCollectionResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: probeResultUnitFor(candidate.capability),
  ),
  OnlineMusicCapability.playlistCategories => (
    count: mapDeclarativePlaylistCategoriesResponse(
      spec: binding.response,
      body: body,
      platform: platform,
    ).length,
    unit: probeResultUnitFor(candidate.capability),
  ),
  // 需要具体实体 ID 的能力**不作为默认探针**（见能力契约）。
  // 真走到这里说明候选策略被改坏了 ⇒ 明确失败，而不是硬套某个映射或伪造 ID。
  OnlineMusicCapability.playlist ||
  OnlineMusicCapability.lyric ||
  OnlineMusicCapability.stream => throw DeclarativeMappingException(
    probeNotProbeableReasonFor(candidate.capability) ?? '该能力不适合服务级探测',
  ),
};
