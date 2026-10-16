/// 探测**发请求之前的计划**（F3-2b / Spec §13.2 的 R7 与 §9.4）。
///
/// 为什么需要它：旧实现点下"探测该服务"就立刻发请求，用户**事前不知道**
/// 会测哪些候选、用什么输入、是否需要真实凭据 —— 事后只能看到一个结论。
/// 用户裁定（Spec §13.2 R7 / §9.4）要求：**真正发请求前**能说明这三件事。
///
/// 本文件只放**纯数据与措辞**（不查配置、不发请求），因此可以单独下断言；
/// 候选来自哪一层由调用方（provider 层）决定，避免 declarative → provider 的反向依赖。
library;

import 'package:pure_music/services/music_platform/declarative/declarative_probe_inputs.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';

/// 一次探测的**事前计划**（只读快照，不含任何凭据值）。
final class ProviderProbePlan {
  const ProviderProbePlan({
    required this.candidates,
    required this.inputs,
    required this.requiresCredential,
    required this.hasCredential,
    this.blockedReason,
    this.maxRequests = providerProbeMaxRequests,
    this.totalBudget = providerProbeTotalBudget,
  });

  /// 按**执行顺序**排列的候选。
  final List<ProviderProbeCandidate> candidates;

  /// 用户在界面上填的输入（`null` = 用默认值）。
  final DeclarativeProbeInputs inputs;

  /// 该条目**声明**需要凭据（`requiresCredential`）。
  final bool requiresCredential;

  /// 本次是否**真的**读到了凭据（决定"要不要先配 Key"）。
  final bool hasCredential;

  /// 计划阶段就被拦下的原因（非法服务地址 / 没有候选）——非 null 时**不发任何请求**。
  final String? blockedReason;

  final int maxRequests;
  final Duration totalBudget;

  bool get isBlocked => blockedReason != null;

  /// 该条目声明需要凭据、但这一次没有可用凭据 ⇒ 探测仍会进行，但**认证条件不满足**，
  /// 结论最多是"未能确认"（D-F3-2）。
  bool get probesWithoutCredential => requiresCredential && !hasCredential;

  /// 每个候选的"来源（能力）+ 候选 id"，顺序即执行顺序。
  List<String> get candidateLines => [
    for (final candidate in candidates) candidate.provenanceLabel,
  ];

  /// **不会发请求**的候选（兼容性过滤，F3-2c）：`候选 → 原因`。
  ///
  /// 单独列出来是有意的：用户必须能看到"哪个候选被跳过了、为什么"，
  /// 否则会把它误读成"测过但失败了"。
  List<String> get incompatibleCandidateLines => [
    for (final candidate in candidates)
      if (probeCandidateIncompatibility(candidate) case final reason?)
        '${candidate.provenanceLabel} → $reason',
  ];

  /// 前 [limit] 个候选（用于界面上"将测试：…"的简短列出）。
  List<String> candidateLinesPreview({int limit = 4}) =>
      candidateLines.length <= limit
      ? candidateLines
      : [...candidateLines.take(limit), '…（共 ${candidateLines.length} 个候选）'];

  /// 本次会使用的输入（**默认值也写出来**，Spec §10 决策 5）。
  ///
  /// 逐候选解析：不同能力的输入要求不同（搜索要关键词，榜单不要），
  /// 因此这里按**第一个能给出结果的候选**说明；无候选时返回空。
  List<String> get inputLines {
    final lines = <String>[];
    for (final candidate in candidates) {
      final resolved = resolveProbeInputs(candidate.capability, inputs);
      if (resolved == null) {
        final missing =
            missingRequiredProbeInputName(candidate.capability, inputs) ?? '输入';
        lines.add('${candidate.provenanceLabel}：缺少必需的$missing（本次不会发送请求）');
        continue;
      }
      final used = <String>['关键词「${resolved.keyword}」'];
      if (resolved.limit != probeDefaultLimit) {
        used.add('每页 ${resolved.limit}');
      } else {
        used.add('每页 ${resolved.limit}（默认）');
      }
      final defaults = resolved.defaultedNotes.isEmpty
          ? ''
          : '（含默认值：${resolved.defaultedNotes.join('、')}）';
      lines.add('${candidate.provenanceLabel}：${used.join('、')}$defaults');
    }
    return List.unmodifiable(lines);
  }

  /// 事前说明（界面直接显示；**不含任何凭据值**）。
  String describe() {
    final buffer = StringBuffer();
    if (isBlocked) {
      buffer.writeln('不会发起探测：$blockedReason');
      return buffer.toString().trimRight();
    }
    buffer.writeln(
      '将按顺序测试 ${candidates.length} 个候选'
      '（最多 ${maxRequests.clamp(1, providerProbeMaxRequests)} 次请求 / '
      '${totalBudget.inSeconds} 秒）：',
    );
    for (final line in candidateLinesPreview()) {
      buffer.writeln('· $line');
    }
    for (final line in incompatibleCandidateLines) {
      // F3-2c：被兼容性过滤掉的候选**不会**发请求 —— 原因必须写出来，
      // 否则用户会把它读成"测过但失败了"。
      buffer.writeln('不会请求：$line');
    }
    for (final line in inputLines) {
      buffer.writeln('输入：$line');
    }
    buffer.writeln(
      requiresCredential
          ? (hasCredential
                ? '凭据：使用该条目已配置的 Key'
                : '凭据：该条目声明需要 Key，但尚未配置 ⇒ 探测仍会进行，'
                      '结论最多是"未能确认"（不会伪造成功）')
          : '凭据：该条目不需要 Key',
    );
    return buffer.toString().trimRight();
  }
}
