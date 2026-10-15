import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **三栏歌曲格**（2026-10-12 新增 ✓）。
///
/// 依据：参考产品的「猜你喜欢」**不是横向货架、也不是单列列表** ✗ ——
/// 是**三栏并排的歌曲格** ✓：每项 = 小方封面 + **加粗曲名** + 灰字「艺人 · 专辑」✓，
/// 整块**纵向铺开**（要更多就翻页 ✓，不在这一块里横滑 ✓）。
///
/// 为什么单独成组件：探索页的「新歌」块也是这个形状 ✓（R100 做的 ✓）⇒
/// 两处必须**同一份实现** ✓，否则必然一边改一边忘 ✗。
class TrackGrid extends StatelessWidget {
  const TrackGrid({
    super.key,
    required this.tracks,
    required this.onTap,
    this.columns = 3,
  });

  final List<MusicTrack> tracks;
  final void Function(MusicTrack track) onTap;
  final int columns;

  @override
  Widget build(BuildContext context) {
    // 窄窗口退回两栏 ✓（三栏会把曲名挤成省略号一片 ✗）。
    return LayoutBuilder(
      builder: (context, constraints) {
        final effective = constraints.maxWidth < 700 ? 2 : columns;
        final rows = <List<int>>[];
        for (var i = 0; i < tracks.length; i += effective) {
          rows.add([
            for (var j = i; j < i + effective && j < tracks.length; j++) j,
          ]);
        }
        return Column(
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var column = 0; column < effective; column++) ...[
                      if (column > 0) const SizedBox(width: Spacing.md),
                      Expanded(
                        child: column < row.length
                            ? _TrackGridItem(
                                track: tracks[row[column]],
                                onTap: () => onTap(tracks[row[column]]),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 一格歌曲：封面 + 曲名（加粗 ✓）+ 「艺人 · 专辑」（灰 ✓）。
class _TrackGridItem extends StatelessWidget {
  const _TrackGridItem({required this.track, required this.onTap});

  final MusicTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      track.artistDisplay,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    return Material(
      type: MaterialType.transparency,
      borderRadius: AppRadius.smCircular,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: 6,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: AppRadius.xsCircular,
                child: SizedBox.square(
                  dimension: 40,
                  child: RemoteMediaCover(
                    coverUri: track.coverUri,
                    placeholder: ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Symbols.music_note,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    cacheWidth: 80,
                    cacheHeight: 80,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.body,
                        fontWeight: AppType.weightMedium,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.caption,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
