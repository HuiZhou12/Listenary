import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

/// 已收藏爱心的强调色，与主题 primary 区分更明显。
const Color _favoriteColor = Color(0xFFE0245E);

/// 在线曲目的「正在播放」判定：当前播放来源为在线，且在线队列的当前曲目
/// 与本行曲目是同一个 [PlatformTrackRef]（按值相等，不比对象身份）。
/// 与本地 `audio_tile.dart` 的 `resolveAudioTileFocus` 保持一致：
/// 只比对曲目身份，不区分播放/暂停，暂停时同样保持高亮。
bool resolveOnlineTrackFocus({
  required ActivePlaybackSessionSource? activeSource,
  required PlatformTrackRef? remoteNowPlayingRef,
  required PlatformTrackRef trackRef,
}) =>
    activeSource == ActivePlaybackSessionSource.remote &&
    remoteNowPlayingRef == trackRef;

/// 供在线列表页调用：判断 [trackRef] 是否为当前正在播放的在线曲目。
///
/// 这里集中读取播放状态，调用方（各在线列表页）只把结果作为
/// [OnlineTrackRow.isNowPlaying] 传入，组件本身不依赖 provider。
/// 用可空类型查找，页面未注册播放 provider（例如组件级测试）时返回 false 而不抛异常。
bool isOnlineTrackNowPlaying(BuildContext context, PlatformTrackRef trackRef) {
  final activeSource = context.watch<ActivePlaybackSession?>()?.value.source;
  final remoteNowPlayingRef = activeSource == ActivePlaybackSessionSource.remote
      ? context.watch<RemotePlaybackQueue?>()?.value.currentItem?.ref
      : null;
  return resolveOnlineTrackFocus(
    activeSource: activeSource,
    remoteNowPlayingRef: remoteNowPlayingRef,
    trackRef: trackRef,
  );
}

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
    this.isNowPlaying = false,
    this.sourceLabel,
    this.leadingIndex,
    this.detailParts = const [],
    this.semanticLabel,
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

  /// 本行是否为当前在线播放曲目；由调用方判定（见 [isOnlineTrackNowPlaying]）。
  final bool isNowPlaying;

  /// **来源标签**（平台展示名，D6/D8）：多平台聚合结果里同一行必须能看出它来自哪个平台。
  ///
  /// 为 null 时不渲染任何标签（单平台列表沿用既有观感）。
  final String? sourceLabel;

  /// **行首序号**（可选）：只有"有排序语义"的列表（榜单/专辑）才给；
  /// 普通歌单传 null ⇒ 不渲染序号（与参考产品的规则一致）。
  final int? leadingIndex;

  /// **详情行的分段**（2026-10-12）：每段可带自己的点击目标。
  ///
  /// 只有"确实带 id"的那一段才给 `onTap`（艺人名要 `artistIds`、专辑名要 `albumIds` ✓）；
  /// 没给的部分就是**纯文本** —— 界面上不出现"看着能点、其实点不动"的东西 ✓。
  /// 为空时退化成 [details] 一行普通文字 ✓。
  final List<({String text, VoidCallback? onTap, String? tooltip})> detailParts;

  /// **读屏标签**（2026-10-12）：参考产品的曲目行是"一个带完整标签的按钮" ✓
  ///（形如 `播放"<曲名> - <艺人> - <时长>"`）⇒ 调用方按同一套格式给标签 ✓。
  /// 为空时读屏只能逐段读出标题/详情/时长（不再是"一个按钮" ✓）。
  final String? semanticLabel;

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
    final isNowPlaying = widget.isNowPlaying;
    // 与本地 AudioTile 的「正在播放」配色一致（primary 底色 + primary 文字）。
    final titleColor = isNowPlaying
        ? scheme.primary
        : enabled
        ? scheme.onSurface
        : scheme.onSurfaceVariant;
    final metadataColor = isNowPlaying
        ? scheme.primary.withValues(alpha: 0.78)
        : enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.55);
    final backgroundColor = isNowPlaying
        ? scheme.primary.withAlpha(20)
        : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      // **读屏语义**（2026-10-12）：参考产品的曲目行是"一个带完整标签的按钮" ——
      // 形如 `播放"<曲名> - <艺人> - <时长>"` ✓；我们此前只有 InkWell（没有标签、没有 button 角色 ✗）。
      // 用 `Semantics`（container 默认 false ⇒ **不吞掉**行内艺人/专辑两个可点段 ✓）。
      child: Semantics(
        label: widget.semanticLabel,
        button: widget.onTap != null,
        child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: MotionDuration.base,
          curve: MotionCurve.standard,
          height: 64,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: AppRadius.smCircular,
            border: isNowPlaying
                ? Border.all(color: scheme.primary.withAlpha(89))
                : null,
          ),
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
                    // 行首序号（可选）：**名次集合**（榜单）与专辑这类"有排序语义"的列表才给，
                    // 普通歌单不给 —— 与参考产品的规则一致（榜单/专辑有序号，普通歌单没有）。
                    if (widget.leadingIndex case final index?) ...[
                      SizedBox(
                        width: 28,
                        child: Text(
                          '$index',
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            color: metadataColor,
                            fontSize: AppType.caption,
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                    ],
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
                          // 标题独占一行：来源标记不在这里占位（W6：不得挤压标题）。
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
                          // 副标题行：详情 + **轻量的来源标记**（W6）。
                          // 来源不做成固定宽度的徽章（那会把详情挤成一小条），
                          // 而是行尾的小圆点 + 小号低对比文字，详情用 Flexible 先省略。
                          Row(
                            children: [
                              Flexible(
                                // 详情行分段：可点段带下划线 + 悬停提示；不可点段是普通文字 ✓。
                                // **平台标识并进同一串**（2026-10-12 用户指定 ✓）：读起来就是
                                // `歌手 · 专辑 · 平台` ✓ —— 它以前是行尾的独立徽章 ✗，
                                // 那样会飘到最右侧、与详情断开 ✓（用户明确否掉了那种排法 ✗）。
                                child: widget.detailParts.isEmpty
                                    ? Text(
                                        widget.sourceLabel == null
                                            ? widget.details
                                            : [
                                                widget.details,
                                                widget.sourceLabel!,
                                              ].where((s) => s.isNotEmpty).join(
                                                ' · ',
                                              ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: metadataColor),
                                      )
                                    : Row(
                                        children: [
                                          for (
                                            var i = 0;
                                            i <
                                                widget.detailParts.length +
                                                    (widget.sourceLabel == null
                                                        ? 0
                                                        : 1);
                                            i++
                                          ) ...[
                                            if (i > 0)
                                              Text(
                                                ' · ',
                                                style: TextStyle(
                                                  color: metadataColor,
                                                ),
                                              ),
                                            Flexible(
                                              child: i <
                                                      widget
                                                          .detailParts
                                                          .length
                                                  ? _DetailSegment(
                                                      part: widget
                                                          .detailParts[i],
                                                      color: metadataColor,
                                                    )
                                                  // 平台段：纯文字、不可点 ✓（点它没有去处 ✓）。
                                                  : Text(
                                                      widget.sourceLabel!,
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: metadataColor,
                                                      ),
                                                    ),
                                            ),
                                          ],
                                        ],
                                      ),
                              ),
                            ],
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
      ),
    );
  }
}

/// 结果行的**来源标签**：告诉用户这一行来自哪个平台（D6 / I1）。
///
/// W6 之后不再是固定宽度的徽章：它改成副标题行尾的"小圆点 + 小号低对比文字"，
/// 见 [_OnlineTrackRowState.build]；详情文本用 Flexible 先省略，标题行完全不受影响。
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

/// 详情行的一段：**悬停时**才有下划线与"可点"提示 ✓（2026-10-12 用户要求：
/// 初始状态**不要**自带下划线 ✗ —— 那会让整行看起来像链接堆 ✓）；不可点的段始终是普通文字 ✓。
class _DetailSegment extends StatefulWidget {
  const _DetailSegment({required this.part, required this.color});

  final ({String text, VoidCallback? onTap, String? tooltip}) part;
  final Color color;

  @override
  State<_DetailSegment> createState() => _DetailSegmentState();
}

class _DetailSegmentState extends State<_DetailSegment> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.part.onTap;
    final text = Text(
      widget.part.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: widget.color,
        decoration: onTap == null || !_hovered
            ? null
            : TextDecoration.underline,
        decorationColor: widget.color,
      ),
    );
    if (onTap == null) return text;
    final link = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.xsCircular,
        child: text,
      ),
    );
    final tooltip = widget.part.tooltip;
    return tooltip == null ? link : Tooltip(message: tooltip, child: link);
  }
}

String formatOnlineTrackDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
