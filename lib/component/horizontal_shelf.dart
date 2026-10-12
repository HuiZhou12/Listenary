import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';

/// **横向货架**：一条可横滑的内容栏，自带加载 / 空 / 失败三态。
///
/// 高度由调用方按卡片自己声明的 `extentFor(...)` 传入（见 `RemoteMediaCard`），
/// **不在这里写常量**：横滑区域的高度一旦与卡片实际高度脱钩就会溢出。
///
/// 三态刻意区分（这是本阶段最容易做错的地方）：
/// - [loading] → 占位块（纯 token 色块，不引第三方骨架屏依赖）；
/// - [errorMessage] → 失败提示 + 重试（**与"空"文案不同**）；
/// - [emptyMessage] 且没有任何条目 → 空提示（中性，不给重试按钮）。
///
/// V2-6（2026-10-12）：参考产品的每个横向区块都带「上一个 / 下一个」箭头，这里补上 ——
/// 但**只在"确实还能往那一侧滚"时才渲染**该箭头：
/// - 避免遮挡第一张/最后一张卡片的点击（禁用态若仍渲染，就会挡住它）；
/// - 也符合"到边界就没有可点的东西"的直觉。
/// 箭头是**覆盖层**（不占布局高度）⇒ 不会改变调用方按卡片算出的货架高度 ✓。
class HorizontalShelf extends StatefulWidget {
  const HorizontalShelf({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemWidth,
    required this.itemHeight,
    this.loading = false,
    this.errorMessage,
    this.onRetry,
    this.emptyMessage,
    this.emptyIcon = Symbols.inbox,
    this.placeholderCount = 5,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  final double itemWidth;
  final double itemHeight;

  final bool loading;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final String? emptyMessage;
  final IconData emptyIcon;
  final int placeholderCount;

  @override
  State<HorizontalShelf> createState() => _HorizontalShelfState();
}

class _HorizontalShelfState extends State<HorizontalShelf> {
  final ScrollController _controller = ScrollController();

  /// 两侧是否还有可滚的余量；由滚动位置变化刷新。
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncArrows);
  }

  @override
  void didUpdateWidget(HorizontalShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 条目数量变化（加载更多 / 切换分类）后重新判断箭头可用性。
    if (oldWidget.itemCount != widget.itemCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrows());
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_syncArrows);
    _controller.dispose();
    super.dispose();
  }

  void _syncArrows() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final canLeft = position.pixels > position.minScrollExtent + 1;
    final canRight = position.pixels < position.maxScrollExtent - 1;
    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  /// 翻一"屏"：按视口宽度的 80% 走，留一点上下文，避免跳得太远。
  void _page(bool forward) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final step = position.viewportDimension * 0.8;
    final target = (position.pixels + (forward ? step : -step)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _controller.animateTo(
      target,
      duration: MotionDuration.fast,
      curve: MotionCurve.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 首帧之后同步一次箭头状态：内容本来就溢出时，用户还没滚动，
    // 滚动监听不会触发 ⇒ 否则箭头要等第一次滚动才出现。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrows());
    if (widget.loading) return _buildPlaceholders(context);
    // 失败**优先于**空：先有错误就不该说"没有内容"。
    if (widget.errorMessage case final message?) {
      return InlineFailureHint(message: message, onRetry: widget.onRetry);
    }
    if (widget.itemCount == 0) {
      return InlineEmptyHint(
        icon: widget.emptyIcon,
        message: widget.emptyMessage ?? '这里暂时没有内容。',
      );
    }
    return SizedBox(
      height: widget.itemHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
              itemBuilder: widget.itemBuilder,
            ),
          ),
          // 覆盖层箭头：只在那一侧真的还有内容时出现（见类文档）。
          if (_canScrollLeft)
            _ShelfArrow(
              icon: Symbols.chevron_left,
              tooltip: '上一个',
              onPressed: () => _page(false),
              alignment: Alignment.centerLeft,
            ),
          if (_canScrollRight)
            _ShelfArrow(
              icon: Symbols.chevron_right,
              tooltip: '下一个',
              onPressed: () => _page(true),
              alignment: Alignment.centerRight,
            ),
        ],
      ),
    );
  }

  Widget _buildPlaceholders(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: widget.itemHeight,
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: widget.placeholderCount,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
        itemBuilder: (context, index) => Semantics(
          label: '正在加载',
          child: SizedBox(
            width: widget.itemWidth,
            height: widget.itemHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: widget.itemWidth,
                  height: widget.itemWidth,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: AppRadius.smCircular,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Container(
                  width: widget.itemWidth * 0.72,
                  height: AppType.body,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.45,
                    ),
                    borderRadius: AppRadius.xsCircular,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 货架两侧的**覆盖式翻页箭头**（不参与布局 ⇒ 不改变货架高度）。
class _ShelfArrow extends StatelessWidget {
  const _ShelfArrow({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.alignment,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        child: Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.92),
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            icon: Icon(icon),
            iconSize: AppType.pageTitle,
            visualDensity: VisualDensity.compact,
          ),
        ),
      ),
    );
  }
}
