import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_source_label.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 卡片上的一个悬停操作。
class RemoteMediaCardAction {
  const RemoteMediaCardAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
}

/// **远端内容卡片**：正方形封面 + 标题 + 元信息行（详情 + 来源标记）+（可选）页脚。
///
/// 为什么只有一种卡片：能进卡片的都是**集合类内容**（歌单 / 专辑 / 榜单），它们的
/// 信息形状是同一套（封面、名字、一行元信息、来源）。给每种类型各写一个几乎相同的
/// 卡片，只会让"来源标记"和"尺寸"在两个地方各自走偏。
///
/// 元信息行沿用 [OnlineTrackRow] 的既有做法：详情用 `Flexible` 先省略，来源是行尾的
/// 小圆点 + 低对比小字（[OnlineSourceLabel]）—— 平台是辅助信息，**永远不占标题行**。
class RemoteMediaCard extends StatefulWidget {
  const RemoteMediaCard({
    super.key,
    required this.width,
    required this.title,
    required this.coverUri,
    this.details = '',
    this.sourceLabel,
    this.onTap,
    this.placeholderIcon = Symbols.queue_music,
    this.actions = const [],
    this.footer,
    this.isNowPlaying = false,
    this.semanticLabel,
  });

  /// 卡片宽度；封面是等宽正方形，整卡高度由 [extentFor] 唯一决定。
  final double width;

  final String title;

  /// 元信息行里的详情（例如"创建者 · 12 首"）。
  final String details;

  /// 平台展示名；为 null 且 [details] 为空时整行不占高度。
  final String? sourceLabel;

  final Uri? coverUri;
  final VoidCallback? onTap;
  final IconData placeholderIcon;

  /// 悬停时覆盖在封面底部的操作（不参与静态布局，因此不会让文字跳动）。
  final List<RemoteMediaCardAction> actions;

  /// 静态页脚（例如「订阅」按钮）。
  final Widget? footer;

  final bool isNowPlaying;

  /// 无障碍朗读用的整体描述；为 null 时退化为标题。
  final String? semanticLabel;

  // --- 布局常量：卡片与货架共用，避免两处各算一次后漂移 ---------------------

  static const double _coverGap = 6;
  static const double _titleGap = 2;
  static const double _titleHeight = 18;
  /// 元信息行的高度：**两行 caption**（2026-10-12 ✓）。
  ///
  /// 参考产品的卡片副标题会**换到第二行** ✓（一行就截断太可惜 ✓）。
  /// ⚠️ 它仍是一个**常量高度**：`各行高度之和 == 声明高度` 的构造不变 ✓
  /// ⇒ 多这一行**不会**让货架溢出 ✓（只是每张卡固定多占一行高度 ✓，短副标题时留白 ✓）。
  static const double _metaHeight = 30;
  static const double _footerGap = 4;
  static const double _footerHeight = 36;

  /// 卡片总高度。**卡片自己按它构建，横向货架也按它设高度** —— 单一来源。
  ///
  /// 上一版把横滑区域的高度写成常量 216，一旦卡片内容变高就会溢出（还为此专门加了
  /// 窄窗回归守卫）。改成由卡片声明尺寸、货架照抄；并且卡片内部**每一行都装进
  /// 定高盒子**，所以"各行高度之和 == 声明高度"是构造出来的，不依赖字体度量。
  static double extentFor({
    required double width,
    bool hasMeta = true,
    bool hasFooter = false,
  }) {
    var height = width + _coverGap + _titleHeight;
    if (hasMeta) height += _titleGap + _metaHeight;
    if (hasFooter) height += _footerGap + _footerHeight;
    return height;
  }

  /// **横向货架里**的卡片宽度。
  ///
  /// 档位与 `ResponsiveBuilder` 的三档**同一套阈值**（≤640 / <1100 / ≥1100），
  /// 因此不再各自写一个"看起来差不多"的断点：那种重复正是两处慢慢走偏的起点。
  static double widthFor(Size size) => size.width <= 640
      ? 124.0
      : (size.width < 1100 ? 140.0 : 156.0);

  @override
  State<RemoteMediaCard> createState() => _RemoteMediaCardState();
}

class _RemoteMediaCardState extends State<RemoteMediaCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sourceLabel = widget.sourceLabel;
    final hasMeta = widget.details.isNotEmpty || sourceLabel != null;
    final height = RemoteMediaCard.extentFor(
      width: widget.width,
      hasMeta: hasMeta,
      hasFooter: widget.footer != null,
    );
    final titleColor = widget.isNowPlaying ? scheme.primary : scheme.onSurface;
    final metadataColor = widget.isNowPlaying
        ? scheme.primary.withValues(alpha: 0.78)
        : scheme.onSurfaceVariant;

    return SizedBox(
      width: widget.width,
      height: height,
      child: Semantics(
        label: widget.semanticLabel ?? widget.title,
        button: widget.onTap != null,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: AppRadius.smCircular,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: AppRadius.smCircular,
              hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: AppRadius.smCircular,
                    child: SizedBox.square(
                      dimension: widget.width,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          RemoteMediaCover(
                            coverUri: widget.coverUri,
                            placeholder: ColoredBox(
                              color: scheme.surfaceContainerHighest,
                              child: Icon(
                                widget.placeholderIcon,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            cacheWidth: (widget.width * 2).round(),
                            cacheHeight: (widget.width * 2).round(),
                          ),
                          // 悬停操作覆盖在封面**底部**：覆盖层不参与静态布局，
                          // 所以文字不会因为悬停而位移，来源标记也不会被顶掉。
                          if (widget.actions.isNotEmpty)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: AnimatedOpacity(
                                duration: MotionDuration.xFast,
                                opacity: _hovered ? 1 : 0,
                                child: _buildActionStrip(scheme),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: RemoteMediaCard._coverGap),
                  SizedBox(
                    height: RemoteMediaCard._titleHeight,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: AppType.body,
                          fontWeight: AppType.weightMedium,
                        ),
                      ),
                    ),
                  ),
                  if (hasMeta) ...[
                    const SizedBox(height: RemoteMediaCard._titleGap),
                    SizedBox(
                      height: RemoteMediaCard._metaHeight,
                      child: Row(
                        // 两行副标题时，**来源标记贴在第一行** ✓（居中会显得浮在半空 ✗）。
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 详情先省略，来源标记始终留在行尾（与曲目行同一套规则）。
                          if (widget.details.isNotEmpty)
                            Flexible(
                              child: Text(
                                widget.details,
                                // **两行**（2026-10-12 ✓，与参考一致 ✓）：超出仍然省略 ✓。
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: metadataColor,
                                  fontSize: AppType.caption,
                                ),
                              ),
                            ),
                          if (sourceLabel != null) ...[
                            if (widget.details.isNotEmpty)
                              const SizedBox(width: Spacing.sm),
                            OnlineSourceLabel(
                              label: sourceLabel,
                              color: metadataColor,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (widget.footer case final footer?) ...[
                    const SizedBox(height: RemoteMediaCard._footerGap),
                    SizedBox(
                      height: RemoteMediaCard._footerHeight,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: footer,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionStrip(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.86),
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppRadius.sm),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final action in widget.actions)
            IconButton(
              tooltip: action.tooltip,
              onPressed: action.onPressed,
              visualDensity: VisualDensity.compact,
              iconSize: 20,
              color: action.color,
              icon: Icon(action.icon),
            ),
        ],
      ),
    );
  }
}
