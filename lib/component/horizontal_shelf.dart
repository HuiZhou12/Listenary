import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/content_section.dart';
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
class HorizontalShelf extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (loading) return _buildPlaceholders(context);
    // 失败**优先于**空：先有错误就不该说"没有内容"。
    if (errorMessage case final message?) {
      return InlineFailureHint(message: message, onRetry: onRetry);
    }
    if (itemCount == 0) {
      return InlineEmptyHint(
        icon: emptyIcon,
        message: emptyMessage ?? '这里暂时没有内容。',
      );
    }
    return SizedBox(
      height: itemHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
        itemBuilder: itemBuilder,
      ),
    );
  }

  Widget _buildPlaceholders(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: itemHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: placeholderCount,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.md),
        itemBuilder: (context, index) => Semantics(
          label: '正在加载',
          child: SizedBox(
            width: itemWidth,
            height: itemHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: itemWidth,
                  height: itemWidth,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                    borderRadius: AppRadius.smCircular,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Container(
                  width: itemWidth * 0.72,
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
