import 'package:pure_music/services/music_platform/models/music_models.dart';

/// 一个**平台自己的**音质档位（D2:A + 用户补充口径④）。
///
/// 内部的 [MusicQuality] 只是跨平台的**偏好键**，不代表所有平台都叫同一个名字：
/// 网易云的「无损」与 QQ 的 `SQ` 都可以映射到内部的 `lossless`。
/// 因此 UI 必须展示 [displayLabel]（平台自己的文案），不要把内部键当文案给用户看。
final class PlatformQualityTier {
  const PlatformQualityTier({
    required this.internalLevel,
    required this.displayLabel,
    required this.requestValue,
  });

  /// 内部偏好层的键（[MusicQuality.level]）。
  final String internalLevel;

  /// 该平台自己的展示文案，例如「无损」/`SQ`/`Hi-Res`。
  final String displayLabel;

  /// 实际传给该平台的值；由平台自己决定（可以是 `sq` 这种平台专有取值）。
  final String requestValue;

  @override
  String toString() => '$displayLabel($internalLevel→$requestValue)';
}

/// 内部偏好键的档位序，用于"不高于期望的最接近档位"；未知键返回 -1。
int musicQualityRank(String level) =>
    MusicQuality.values.indexWhere((quality) => quality.level == level);

/// 网易云（内置 ChkSz）档位：7 档，文案与请求值都取自 [MusicQuality]。
///
/// 这是**默认配置下行为不变**的保证 —— 档位集合、顺序、请求值与今天完全一致。
final List<PlatformQualityTier> neteaseQualityTiers = List.unmodifiable([
  for (final quality in MusicQuality.values)
    PlatformQualityTier(
      internalLevel: quality.level,
      displayLabel: quality.label,
      requestValue: quality.level,
    ),
]);

/// QQ 音乐（`qq-music-api`）的档位声明。
///
/// **依据（真实源码，非编造；见 Spec §19.3）**：
/// - `qq-music-api/getMusicPlay.ts`：`type AudioQuality = 'm4a' | '128' | '320' | 'ape' | 'flac'`，
///   `DEFAULT_QUALITY = '128'`；
/// - `qq-music-api/api-metadata.ts`：`quality.enumValues = ['m4a','128','320','ape','flac']`，
///   `defaultValue = '128'`；
/// - 播放解析参数形状：`{ songmid, quality, resType }`（`resType = 'play'`）。
///
/// **"内部档位 → QQ 取值"的映射是我们（Listenary）的抽象决定**，不是 QQ 的语义：
/// `128 → standard`、`320 → exhigh`、`flac → lossless`。
///
/// `ape` / `m4a` **暂不暴露**：源码只给出取值集合，没有可靠的"它对应哪种音质"的口径
/// （真实语义待确认），因此不为它们编造内部档位。
/// 早先 Spec 草稿里的 `sq` 是编造的，**已作废**。
final List<PlatformQualityTier> qqQualityTiers = List.unmodifiable([
  const PlatformQualityTier(
    internalLevel: 'standard',
    displayLabel: '128',
    requestValue: '128',
  ),
  const PlatformQualityTier(
    internalLevel: 'exhigh',
    displayLabel: '320',
    requestValue: '320',
  ),
  const PlatformQualityTier(
    internalLevel: 'lossless',
    displayLabel: 'flac',
    requestValue: 'flac',
  ),
]);

/// 一次「内部偏好 → 平台档位」的解析结果。
final class PlatformQualitySelection {
  const PlatformQualitySelection({
    required this.requestValue,
    required this.displayLabel,
    required this.internalLevel,
    this.fellBack = false,
  });

  /// 实际传给该平台的值。
  final String requestValue;

  /// 展示给用户的文案（**平台自己的名称**）。
  final String displayLabel;

  /// 实际命中的内部档位（回落后可能与用户偏好不同）。
  final String internalLevel;

  /// 是否与用户偏好不同；为真时 UI 应提示"已回落为 displayLabel"。
  final bool fellBack;

  @override
  String toString() => '$displayLabel($requestValue)${fellBack ? ' ←回落' : ''}';
}

/// 把内部偏好解析成该平台实际使用的档位（Spec §7.2，确定式规则）。
///
/// 1. 平台声明了**同一内部档位** → 用它（`fellBack = false`）；
/// 2. 否则取"**不高于**期望"中序最大的一档（`fellBack = true`）；
/// 3. 再否则取该平台**最低档**（`fellBack = true`）；
/// 4. 平台**没有声明任何档位**（[tiers] 为空）→ 原样透传偏好，
///    行为与引入本模型之前完全一致（内置与声明式 Provider 的既有取值都不会变）。
PlatformQualitySelection selectPlatformQuality({
  required List<PlatformQualityTier> tiers,
  required String preference,
}) {
  if (tiers.isEmpty) {
    return PlatformQualitySelection(
      requestValue: preference,
      displayLabel: preference,
      internalLevel: preference,
    );
  }

  for (final tier in tiers) {
    if (tier.internalLevel == preference) {
      return PlatformQualitySelection(
        requestValue: tier.requestValue,
        displayLabel: tier.displayLabel,
        internalLevel: tier.internalLevel,
      );
    }
  }

  final preferenceRank = musicQualityRank(preference);
  PlatformQualityTier? closestLower;
  var closestRank = -1;
  if (preferenceRank >= 0) {
    for (final tier in tiers) {
      final rank = musicQualityRank(tier.internalLevel);
      if (rank < 0 || rank > preferenceRank || rank <= closestRank) continue;
      closestLower = tier;
      closestRank = rank;
    }
  }

  final chosen =
      closestLower ??
      tiers.reduce(
        (a, b) =>
            musicQualityRank(a.internalLevel) <=
                musicQualityRank(b.internalLevel)
            ? a
            : b,
      );
  return PlatformQualitySelection(
    requestValue: chosen.requestValue,
    displayLabel: chosen.displayLabel,
    internalLevel: chosen.internalLevel,
    fellBack: true,
  );
}

/// 按**平台档位声明**生成降级链（返回内部偏好档位，从期望档一路降到下限）。
///
/// 为什么不能只用 [MusicQuality] 的下标：内部枚举只是我们的抽象，
/// 平台真实档位可能少一档、多一档或顺序不同（QQ 只有 128/320/flac），
/// 用下标推断"平台真实等级"会把网易云的语义强加到别的平台（Spec §19.7 缺陷 B）。
///
/// 规则与 [selectPlatformQuality] 一致：
/// 1. 期望档优先按 `internalLevel` 命中（命中不了就按"不高于期望的最接近档"）；
/// 2. 下限由 [fallbackQuality] 决定 —— 它可能是**平台请求值**（上一首平台实际返回的档位），
///    也可能是内部档位，两者都认；找不到、或不低于期望时，下限 = 平台最低档。
///
/// 平台**没有**档位声明（[tiers] 为空）时返回 null，表示调用方应保持引入档位模型之前的行为
/// （内部档位原样透传）。
List<String>? platformQualityFallbackChain({
  required List<PlatformQualityTier> tiers,
  required String requestedQuality,
  String? fallbackQuality,
}) {
  if (tiers.isEmpty) return null;
  final ordered = [...tiers]
    ..sort(
      (a, b) => musicQualityRank(
        a.internalLevel,
      ).compareTo(musicQualityRank(b.internalLevel)),
    );
  final selection = selectPlatformQuality(
    tiers: ordered,
    preference: requestedQuality,
  );
  final startIndex = ordered.indexWhere(
    (tier) => tier.internalLevel == selection.internalLevel,
  );
  if (startIndex < 0) return null;

  var endIndex = 0;
  final floor = fallbackQuality;
  if (floor != null) {
    final floorIndex = ordered.indexWhere(
      (tier) => tier.requestValue == floor || tier.internalLevel == floor,
    );
    if (floorIndex >= 0 && floorIndex < startIndex) endIndex = floorIndex;
  }
  return [
    for (var index = startIndex; index >= endIndex; index--)
      ordered[index].internalLevel,
  ];
}
