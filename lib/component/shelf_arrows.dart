import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/shelf_scroll_state.dart';
import 'package:pure_music/core/design_tokens.dart';

/// **货架的「◀ ▶」**（2026-10-12 新增 ✓）：放在**区块标题行的右侧** ✓（参考产品的做法 ✓）。
///
/// 与 [HorizontalShelf] 里那对"浮在卡片上"的箭头不同 ✗：这里是**头部的一部分** ✓，
/// 不覆盖任何卡片 ✓，也不占货架高度 ✓。
///
/// 显示规则与那条一致 ✓：**只在"确实还能往那一侧滚"时才渲染** ✓；
/// 货架没接上（[ShelfScrollState.isAttached] 为假 ✓）时**整块不渲染** ✗
/// —— 免得留下一个点不动的箭头 ✓。
class ShelfArrows extends StatelessWidget {
  const ShelfArrows({super.key, required this.state});

  final ShelfScrollState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (!state.isAttached) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.canScrollLeft)
              _ShelfArrowButton(
                icon: Symbols.chevron_left,
                tooltip: '上一页',
                color: scheme.onSurfaceVariant,
                onPressed: state.pageBack,
              ),
            if (state.canScrollRight)
              _ShelfArrowButton(
                icon: Symbols.chevron_right,
                tooltip: '下一页',
                color: scheme.onSurfaceVariant,
                onPressed: state.pageForward,
              ),
          ],
        );
      },
    );
  }
}

class _ShelfArrowButton extends StatelessWidget {
  const _ShelfArrowButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      color: color,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(Spacing.xs),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
