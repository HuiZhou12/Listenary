/// 探测的**能力契约**（F3-4 / Spec §9.1、§13.3）：一个能力在"服务级探测"里
/// **能不能被探测**、**不能的原因**、**结果怎么计数**。
///
/// 为什么要有它（而不是散在各处）：旧实现把这三件事写在两个地方 —— 可探测性在
/// `probeCapableCapabilities`，结果单位在 `_judgeProbeResponse` 的字符串字面量里。
/// 新增能力时必须记得同时改两处，漏一处就会出现"能探但不会计数"或"探了却算作不可探"。
/// 现在**只有这一张表**：`probeCapableCapabilities` 与映射单位都从它派生。
///
/// 与本文件的关系：这是**能力的契约**，不是平台的知识 —— 不允许按平台分支。
library;

import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';

/// 单个能力的探测契约。
final class DeclarativeProbeCapabilityContract {
  const DeclarativeProbeCapabilityContract({
    required this.capability,
    required this.unit,
    this.probeable = true,
    this.notProbeableReason,
  });

  final OnlineMusicCapability capability;

  /// 能否作为**服务级探针**（判据：不需要用户提供具体实体 ID 就能独立执行）。
  final bool probeable;

  /// 结果单位（"首曲目 / 个歌单 / 个分类 / 个榜单"）。
  ///
  /// 界面与报告都用它 —— 不同能力的结构不同，不能一律说"首"。
  /// 不可探测的能力没有单位（空串）。
  final String unit;

  /// 不可探测时的**可读原因**（界面/候选过滤都用它，只有这一份文案）。
  final String? notProbeableReason;
}

/// 需要具体实体 ID 的能力的统一说明（**文案只有这一份**）。
const probeNeedsEntityIdReason =
    '该能力需要具体的曲目 / 歌单 ID，不适合服务级探测'
    '（请用「试跑」并自己填 ID；探测不会伪造 ID）';

/// **顺序即执行顺序**（搜索优先）。
///
/// - 可探测：搜索 / 新歌 / 歌单列表 / 歌单分类 / 榜单 —— 各自用**自己的**响应结构判定；
/// - 不可探测：歌单详情 / 歌词 / 播放解析 —— 需要实体 ID，交给**试跑**，**绝不伪造 ID**。
const declarativeProbeCapabilityContracts =
    <DeclarativeProbeCapabilityContract>[
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.search,
        unit: '首曲目',
      ),
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.newSongs,
        unit: '首曲目',
      ),
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.playlistCollection,
        unit: '个歌单',
      ),
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.playlistCategories,
        unit: '个分类',
      ),
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.chartList,
        unit: '个榜单',
      ),
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.playlist,
        unit: '',
        probeable: false,
        notProbeableReason: probeNeedsEntityIdReason,
      ),
      // 艺人详情同样需要实体 ID（艺人 id 在请求里、不在响应里）⇒ 交给「试跑」✓。
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.artist,
        unit: '',
        probeable: false,
        notProbeableReason: probeNeedsEntityIdReason,
      ),
      // 专辑详情同理（专辑 id 在请求里）✓。
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.album,
        unit: '',
        probeable: false,
        notProbeableReason: probeNeedsEntityIdReason,
      ),
      // 艺人专辑列表同理（艺人 id 在请求里）✓。
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.artistAlbums,
        unit: '',
        probeable: false,
        notProbeableReason: probeNeedsEntityIdReason,
      ),
      // 艺人单曲列表同理 ✓。
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.artistSongs,
        unit: '',
        probeable: false,
        notProbeableReason: probeNeedsEntityIdReason,
      ),
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.lyric,
        unit: '',
        probeable: false,
        notProbeableReason: probeNeedsEntityIdReason,
      ),
      DeclarativeProbeCapabilityContract(
        capability: OnlineMusicCapability.stream,
        unit: '',
        probeable: false,
        notProbeableReason: probeNeedsEntityIdReason,
      ),
    ];

/// 该能力的契约；**每个能力都必须有**（表里缺项 ⇒ 契约不完整，而不是悄悄放过）。
DeclarativeProbeCapabilityContract probeContractFor(
  OnlineMusicCapability capability,
) {
  for (final contract in declarativeProbeCapabilityContracts) {
    if (contract.capability == capability) return contract;
  }
  throw StateError('探测能力契约缺少 ${capability.name}（新增能力时必须同时补契约）');
}

/// **服务级探测**能验的能力（顺序即执行顺序）—— 由契约派生，不另写一份列表。
List<OnlineMusicCapability> get probeCapableCapabilities => [
  for (final contract in declarativeProbeCapabilityContracts)
    if (contract.probeable) contract.capability,
];

/// 结果单位（不可探测的能力返回空串）。
String probeResultUnitFor(OnlineMusicCapability capability) =>
    probeContractFor(capability).unit;

/// 不可探测的原因（可探测的能力返回 null）。
String? probeNotProbeableReasonFor(OnlineMusicCapability capability) =>
    probeContractFor(capability).notProbeableReason;
