import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

/// 已收藏爱心的强调色，与主题 primary 区分更明显。
const Color _favoriteColor = Color(0xFFE0245E);

class OnlineTrackRow extends StatefulWidget {
  const OnlineTrackRow({
    super.key,
    required this.track,
    required this.details,
    required this.enabled,
    required this.onTap,
    this.onAddToPlaylist,
    this.onRemove,
    this.showFavorite = false,
    this.favorite = false,
    this.onToggleFavorite,
  });

  final MusicTrack track;
  final String details;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onRemove;
  final bool showFavorite;
  final bool favorite;
  final VoidCallback? onToggleFavorite;

  @override
  State<OnlineTrackRow> createState() => _OnlineTrackRowState();
}

class _OnlineTrackRowState extends State<OnlineTrackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = widget.track;
    final enabled = widget.enabled;
    final titleColor = enabled ? scheme.onSurface : scheme.onSurfaceVariant;
    final metadataColor = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: SizedBox(
          height: 64,
          child: Material(
            type: MaterialType.transparency,
            borderRadius: AppRadius.smCircular,
            child: InkWell(
              onTap: widget.onTap,
              hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
              borderRadius: AppRadius.smCircular,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
                child: Row(
                  children: [
                    _OnlineTrackCover(
                      key: ValueKey('online-track-cover-${track.ref.trackId}'),
                      coverUri: track.coverUri,
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: titleColor,
                              fontSize: AppType.subtitle,
                              fontWeight: AppType.weightMedium,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.details,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: metadataColor),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Spacing.md),
                    // 右侧操作区：未悬浮显示时长，悬浮时由操作按钮替换，避免内容前移。
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 120),
                      child: _hovered
                          ? Row(
                              key: const ValueKey('row-actions'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.onAddToPlaylist != null)
                                  IconButton(
                                    tooltip: '添加到歌单',
                                    onPressed: widget.onAddToPlaylist,
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Symbols.playlist_add,
                                      size: 20,
                                    ),
                                  ),
                                if (widget.showFavorite)
                                  IconButton(
                                    tooltip: widget.favorite ? '取消收藏' : '收藏',
                                    onPressed: widget.onToggleFavorite,
                                    visualDensity: VisualDensity.compact,
                                    color: widget.favorite
                                        ? _favoriteColor
                                        : null,
                                    icon: Icon(
                                      widget.favorite
                                          ? Symbols.favorite
                                          : Symbols.favorite_border,
                                      size: 20,
                                    ),
                                  ),
                                if (widget.onRemove != null)
                                  IconButton(
                                    tooltip: '从歌单移除',
                                    onPressed: widget.onRemove,
                                    visualDensity: VisualDensity.compact,
                                    color: scheme.error,
                                    icon: const Icon(
                                      Symbols.remove_circle_outline,
                                      size: 20,
                                    ),
                                  ),
                              ],
                            )
                          : track.duration != Duration.zero
                          ? Text(
                              formatOnlineTrackDuration(track.duration),
                              key: const ValueKey('row-duration'),
                              style: TextStyle(color: metadataColor),
                            )
                          : const SizedBox.shrink(key: ValueKey('row-none')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OnlineTrackCover extends StatelessWidget {
  const _OnlineTrackCover({super.key, required this.coverUri});

  final Uri? coverUri;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Icon(
        Symbols.music_note,
        size: 22,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
      ),
    );
    return ClipRRect(
      borderRadius: AppRadius.smCircular,
      child: SizedBox.square(
        dimension: 48.0,
        child: RemoteMediaCover(
          coverUri: coverUri,
          placeholder: placeholder,
          cacheWidth: 96,
          cacheHeight: 96,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

String formatOnlineTrackDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
