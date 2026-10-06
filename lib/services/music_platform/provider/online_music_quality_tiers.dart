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
