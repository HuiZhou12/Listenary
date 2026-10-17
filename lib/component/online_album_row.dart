import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/online_source_label.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/component/remote_media_details.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/services/music_platform/index.dart';

/// **专辑结果行**（2026-10-12 抽出为公共组件 ✓）。
///
/// 出处：搜索结果的混合行（R92 ✓）与新的「新发行」页（R95 ✓）都要它 ✓ ——
/// 两边各写一份必然走偏（元信息、来源标记、点击目标都会分叉 ✓），所以抽到这里 ✓。
///
/// 约定：
/// - 元信息以「**专辑 · 年份 · N 首**」自报家门 ✓（参考产品的"类型前缀"做法 ✓），
///   而且**只写平台声明的事实** ✓（年份/曲目数，缺就不写 ✓）——规则在 [albumDetailsOf]
///   （`remote_media_details.dart` ✓），与**卡片**（`AlbumShelf`）共用同一份 ✓；
/// - 自带透明 `Material` ✓ —— 可点区域**不假设**祖先里有 Material（R84 的教训 ✓）；
/// - 点它打开**专辑页** ✓（曲目有序号、整张可播 ✓）。
class OnlineAlbumRow extends StatelessWidget {
  const OnlineAlbumRow({super.key, required this.album, this.onTapOverride});

  final OnlineAlbumSummary album;

  /// 覆盖默认的"打开专辑页"（例如将来要"先订阅再打开"时 ✓）。
  final VoidCallback? onTapOverride;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: AppRadius.smCircular,
        child: InkWell(
          borderRadius: AppRadius.smCircular,
          onTap:
              onTapOverride ??
              () => context.push(
                app_paths.ONLINE_ALBUM_PAGE,
                extra: (
                  platform: album.platform,
                  albumId: album.id,
                  name: album.name,
                ),
              ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: 8.0,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: AppRadius.xsCircular,
                  child: SizedBox.square(
                    dimension: 48.0,
                    child: RemoteMediaCover(
                      coverUri: album.coverUri,
                      placeholder: ColoredBox(
                        color: scheme.surfaceContainerHighest,
                        child: Icon(
                          Symbols.album,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      cacheWidth: 96,
                      cacheHeight: 96,
                    ),
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: AppType.subtitle,
                          fontWeight: AppType.weightMedium,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        albumDetailsOf(album),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                OnlineSourceLabel(
                  label: platformLabelForIdentityOnly(album.identity),
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
