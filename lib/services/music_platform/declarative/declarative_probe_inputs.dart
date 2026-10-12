/// 探测的**每能力输入契约**（F3-2 / Spec §9.1、§10 决策 5）。
///
/// 为什么单独一个文件：探测的"输入要求"是**能力的属性**，不是某个平台的属性，
/// 也不该散落在 UI 里（旧实现把关键词与每页数量写死在 `provider_probe.dart` 顶部，
/// 界面上既看不见也改不了，用户只能拿到一个用 `listenary` 探出来的结论）。
///
/// 用户裁定（Spec §10 决策 5）：
/// - **按能力定义并允许编辑**；
/// - **使用默认输入必须在报告中注明**；
/// - **缺少必需输入时不得发送请求**。
library;

import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';

/// 探测可能用到的输入项。
///
/// 现在只有这两项（可探测的能力都"不需要实体 ID"，见 `probeCapableCapabilities`）；
/// 以后若要放开需要 ID 的能力，在这里加 `trackId` / `playlistId` 即可，
/// **不要**再往探测函数签名上挂零散参数。
enum DeclarativeProbeInput { keyword, limit }

String declarativeProbeInputLabel(DeclarativeProbeInput input) =>
    switch (input) {
      DeclarativeProbeInput.keyword => '关键词',
      DeclarativeProbeInput.limit => '每页数量',
    };

/// 一个能力的输入要求。
final class DeclarativeProbeInputRequirement {
  const DeclarativeProbeInputRequirement({
    this.required = const {},
    this.optionalWithDefault = const {},
  });

  /// **必须有值**，否则不发送请求。
  final Set<DeclarativeProbeInput> required;

  /// **可以不填**（有默认值）；但一旦**显式填成空**，同样不发送请求 ——
  /// 用户清空它就是在说"别用默认值替我决定"。
  final Set<DeclarativeProbeInput> optionalWithDefault;
}

/// 各能力的输入要求。
///
/// 探测用**服务级**证据，因此可探测能力都**不需要实体 ID**；关键词与每页数量
/// 只影响"查询长什么样"，不影响"服务像不像"。给出默认值是为了保持"一键探测"，
/// 但默认值会被**如实披露**（见 [ResolvedProbeInputs.defaultedNotes]）。
DeclarativeProbeInputRequirement probeInputRequirementFor(
  OnlineMusicCapability capability,
) => switch (capability) {
  OnlineMusicCapability.search => const DeclarativeProbeInputRequirement(
    optionalWithDefault: {
      DeclarativeProbeInput.keyword,
      DeclarativeProbeInput.limit,
    },
  ),
  // 搜索专辑：与搜索同判据（给默认关键词即可 ✓）。
  OnlineMusicCapability.searchAlbums =>
    const DeclarativeProbeInputRequirement(
      optionalWithDefault: {
        DeclarativeProbeInput.keyword,
        DeclarativeProbeInput.limit,
      },
    ),
  // 新歌 / 新专辑 / 歌单列表 / 歌单分类 / 榜单：由服务端决定"给什么"，无需关键词。
  OnlineMusicCapability.newSongs ||
  OnlineMusicCapability.newAlbums ||
  OnlineMusicCapability.playlistCollection ||
  OnlineMusicCapability.playlistCategories ||
  OnlineMusicCapability.chartList => const DeclarativeProbeInputRequirement(
    optionalWithDefault: {DeclarativeProbeInput.limit},
  ),
  // 需要实体 ID 的能力不属于服务级探测（由候选策略排除；这里也如实声明"无要求"）。
  OnlineMusicCapability.playlist ||
  OnlineMusicCapability.artist ||
  OnlineMusicCapability.album ||
  // 艺人专辑列表同样要实体 ID（艺人 id 在请求里 ✓）⇒ 不参与服务级探测 ✓。
  OnlineMusicCapability.artistAlbums ||
  // 艺人单曲列表同样要实体 ID（艺人 id 在请求里 ✓）⇒ 不参与服务级探测 ✓。
  OnlineMusicCapability.artistSongs ||
  OnlineMusicCapability.lyric ||
  OnlineMusicCapability.stream => const DeclarativeProbeInputRequirement(),
};

/// 默认值（**只有一处**，界面与报告都从这里取，避免两处默认值不一致）。
const probeDefaultKeyword = 'listenary';
const probeDefaultLimit = 1;

/// 用户在界面上填的输入（`null` = 没填 ⇒ 用默认）。
final class DeclarativeProbeInputs {
  const DeclarativeProbeInputs({this.keyword, this.limit});

  final String? keyword;
  final int? limit;

  bool get isEmpty => keyword == null && limit == null;

  @override
  String toString() => 'DeclarativeProbeInputs(keyword=$keyword, limit=$limit)';
}

/// 解析后的输入：真正会被用到的值 + **哪些是默认值**。
final class ResolvedProbeInputs {
  const ResolvedProbeInputs({
    required this.keyword,
    required this.limit,
    this.defaultedNotes = const [],
  });

  final String keyword;
  final int limit;

  /// 使用默认值的**如实说明**（Spec §10 决策 5：报告必须注明）。
  final List<String> defaultedNotes;

  bool get usedAnyDefault => defaultedNotes.isNotEmpty;

  @override
  String toString() =>
      'ResolvedProbeInputs(keyword=$keyword, limit=$limit, '
      'defaulted=${defaultedNotes.length})';
}

/// 把用户输入解析成可执行输入；**缺必需输入 ⇒ 返回 null**（调用方据此"不发送请求"）。
///
/// 规则：
/// 1. `null` ⇒ 该能力**有默认值**时用默认值，并记一条 [ResolvedProbeInputs.defaultedNotes]；
///    该能力**没有**这一项（例如榜单不需要关键词）⇒ 忽略它，**不报错**（用户填多了不算错）；
/// 2. 空串（或纯空白）= 用户**显式清空** ⇒ 若该能力允许它，则视为"缺少必需输入" ⇒ 返回 null；
/// 3. 非正数的每页数量 ⇒ 视为非法 ⇒ 返回 null（不拿一个荒谬的值去打服务端）。
ResolvedProbeInputs? resolveProbeInputs(
  OnlineMusicCapability capability,
  DeclarativeProbeInputs inputs,
) {
  final requirement = probeInputRequirementFor(capability);
  final notes = <String>[];

  // ---- 关键词 ----
  final keywordAllowed =
      requirement.required.contains(DeclarativeProbeInput.keyword) ||
      requirement.optionalWithDefault.contains(DeclarativeProbeInput.keyword);
  var keyword = probeDefaultKeyword;
  if (keywordAllowed) {
    final raw = inputs.keyword;
    if (raw == null) {
      notes.add('关键词使用默认值「$probeDefaultKeyword」');
    } else {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null; // 显式清空 ⇒ 缺必需输入
      keyword = trimmed;
    }
  }

  // ---- 每页数量 ----
  final limitAllowed =
      requirement.required.contains(DeclarativeProbeInput.limit) ||
      requirement.optionalWithDefault.contains(DeclarativeProbeInput.limit);
  var limit = probeDefaultLimit;
  if (limitAllowed) {
    final raw = inputs.limit;
    if (raw == null) {
      notes.add('每页数量使用默认值 $probeDefaultLimit');
    } else {
      if (raw <= 0) return null; // 非法值 ⇒ 不发请求
      limit = raw;
    }
  }

  return ResolvedProbeInputs(
    keyword: keyword,
    limit: limit,
    defaultedNotes: List.unmodifiable(notes),
  );
}

/// 某能力**被显式清空**的必需输入名（用于"未尝试"的说明文案）。
String? missingRequiredProbeInputName(
  OnlineMusicCapability capability,
  DeclarativeProbeInputs inputs,
) {
  final requirement = probeInputRequirementFor(capability);
  final keywordAllowed =
      requirement.required.contains(DeclarativeProbeInput.keyword) ||
      requirement.optionalWithDefault.contains(DeclarativeProbeInput.keyword);
  if (keywordAllowed &&
      inputs.keyword != null &&
      inputs.keyword!.trim().isEmpty) {
    return declarativeProbeInputLabel(DeclarativeProbeInput.keyword);
  }
  final limitAllowed =
      requirement.required.contains(DeclarativeProbeInput.limit) ||
      requirement.optionalWithDefault.contains(DeclarativeProbeInput.limit);
  if (limitAllowed && inputs.limit != null && inputs.limit! <= 0) {
    return declarativeProbeInputLabel(DeclarativeProbeInput.limit);
  }
  return null;
}
