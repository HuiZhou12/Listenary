import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 页面里的一个**内容区块**：区块头（标题 + 可选副标题 + 可选「查看全部」）+ 内容。
///
/// 主页与探索页都要用同一种区块头，所以它是公共组件，而不是某一页的私有件 ——
/// 留在页面里必然会被复制成两份、然后各自走偏。
class ContentSection extends StatelessWidget {
  const ContentSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? subtitle;

  /// 为空时不渲染操作按钮（既有区块头就是这个行为）。
  final String? actionLabel;
  final VoidCallback? onAction;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      // 层级：页标题(pageTitle 20) > **区块标题(subtitle 16)** > 卡片标题(body 14)。
                      // 这里原本用 body(14)，与卡片标题**同号** ⇒ 区块之间看不出层次。
                      style: const TextStyle(
                        fontSize: AppType.subtitle,
                        fontWeight: AppType.weightSemibold,
                      ),
                    ),
                    if (subtitle case final subtitle?) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: AppType.caption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (actionLabel != null && onAction != null)
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          child,
        ],
      ),
    );
  }
}

/// 区块内的**行内空/不可用提示**：小图标 + 一行说明。
///
/// 与页面级的 `QuietEmptyState` 分工不同：这个用于"页面里某一块暂时没内容"，
/// 不能把一个居中大空态塞进区块里（会把整页撑成空页面）。
class InlineEmptyHint extends StatelessWidget {
  const InlineEmptyHint({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// 区块内的**行内失败提示**：错误图标 + 安全文案 + 可选重试。
///
/// 与 [InlineEmptyHint] 分开是刻意的：**"没有内容"和"读取失败"必须长得不一样**，
/// 否则用户会把一次网络失败读成"这个平台没有这首歌"。
class InlineFailureHint extends StatelessWidget {
  const InlineFailureHint({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.error_outline, size: 16, color: scheme.error),
        const SizedBox(width: Spacing.sm),
        Expanded(child: Text(message, style: TextStyle(color: scheme.error))),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: Text(retryLabel)),
      ],
    );
  }
}
