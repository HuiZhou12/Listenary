import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';

/// 平台档位菜单（D2:A / D10:A / I4）。
///
/// 只列**该平台自己声明**的档位，并且用**它自己的文案**（"标准 / 无损 / SQ…"）；
/// 勾选的是内部偏好档位（[PlatformQualityTier.internalLevel]），实际传给平台的取值
/// 由档位声明决定。发生回落时，菜单里明确写出"已回落为 X"，同时回调 [onOpened]
/// 供调用方给出更显眼的提示。
///
/// [platformLabel] 非空时，菜单顶部给出**这是哪个平台的档位**：档位文案本身是平台专有的
/// （QQ 是 `flac/320/128`、网易云是"无损/Hi-Res"），不写出平台名的话用户无法判断
/// 自己看到的是哪一家的档位 —— 而"音质选择"必须能回答"来源是谁"。
///
/// 与播放会话解耦（只吃 `tiers` + `selection`），因此可以单独做 widget 测试。
class PlatformQualityMenuButton extends StatelessWidget {
  const PlatformQualityMenuButton({
    super.key,
    required this.tiers,
    required this.selection,
    required this.onSelected,
    required this.iconColor,
    this.platformLabel,
    this.onOpened,
    this.iconSize = 28.0,
  });

  /// 该平台声明的档位（非空；空列表请改用 [InternalQualityMenuButton]）。
  final List<PlatformQualityTier> tiers;

  /// 内部偏好 → 该平台的解析结果（含是否回落）。
  final PlatformQualitySelection selection;

  /// 选中回调，参数是**内部偏好档位**（保持跨平台偏好语义）。
  final ValueChanged<String> onSelected;

  /// 这些档位属于哪个平台（平台展示名）。为空时不渲染表头（保持既有观感）。
  final String? platformLabel;

  final Color iconColor;
  final VoidCallback? onOpened;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '音质',
      onOpened: onOpened,
      onSelected: onSelected,
      itemBuilder: (context) => [
        // 表头：只是说明"这些是哪个平台的档位"，不可选。
        if (platformLabel case final label?)
          PopupMenuItem<String>(
            enabled: false,
            height: 32,
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: AppType.caption,
                fontWeight: AppType.weightSemibold,
              ),
            ),
          ),
        if (selection.fellBack)
          PopupMenuItem<String>(
            enabled: false,
            child: Text(
              '已回落为 ${selection.displayLabel}',
              style: TextStyle(color: scheme.error),
            ),
          ),
        for (final tier in tiers)
          PopupMenuItem(
            value: tier.internalLevel,
            child: Row(
              children: [
                if (tier.internalLevel == selection.internalLevel)
                  const Icon(Symbols.check, size: 18)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(tier.displayLabel),
              ],
            ),
          ),
      ],
      icon: Icon(Symbols.high_quality, color: iconColor),
      iconSize: iconSize,
    );
  }
}

/// 平台**没有档位声明**时的既有菜单：内部档位列表。
///
/// 保持引入平台档位之前的行为不变（补充口径④：不得伪造平台档位名称）。
class InternalQualityMenuButton extends StatelessWidget {
  const InternalQualityMenuButton({
    super.key,
    required this.preference,
    required this.onSelected,
    required this.iconColor,
    this.iconSize = 28.0,
  });

  /// 当前内部偏好档位（[MusicQuality.level]）。
  final String preference;

  final ValueChanged<String> onSelected;
  final Color iconColor;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    MusicQuality? current;
    for (final quality in MusicQuality.values) {
      if (quality.level == preference) {
        current = quality;
        break;
      }
    }
    return PopupMenuButton<MusicQuality>(
      tooltip: '音质',
      onSelected: (quality) => onSelected(quality.level),
      itemBuilder: (context) => [
        for (final quality in MusicQuality.values)
          PopupMenuItem(
            value: quality,
            child: Row(
              children: [
                if (quality == current)
                  const Icon(Symbols.check, size: 18)
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(quality.label),
              ],
            ),
          ),
      ],
      icon: Icon(Symbols.high_quality, color: iconColor),
      iconSize: iconSize,
    );
  }
}
