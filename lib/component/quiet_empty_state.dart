import 'package:flutter/material.dart';

import 'package:pure_music/core/design_tokens.dart';

/// 空态占位（图标 + 标题 + 说明 [+ 动作]）。
///
/// **全应用共用**：默认布局是"图标在左、文字在右"的横排，调用点不要改它。
/// 需要"图标上 / 标题中 / 说明下"的居中列时传 [centered] = true
/// （首个用户：搜索弹窗里的空态 —— 弹窗内是视觉焦点，横排会偏离中轴）。
class QuietEmptyState extends StatelessWidget {
  const QuietEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.padding = const EdgeInsets.all(24.0),
    this.maxWidth = 420.0,
    this.centered = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  /// 是否走居中列布局（图标上 / 标题中 / 说明下）。默认 false = 既有横排。
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final texts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Text(
          title,
          textAlign: centered ? TextAlign.center : null,
          style: textTheme.titleMedium?.copyWith(
            color: scheme.onSurface,
            fontWeight: AppType.weightSemibold,
          ),
        ),
        const SizedBox(height: 4.0),
        Text(
          message,
          textAlign: centered ? TextAlign.center : null,
          style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (action != null) ...[
          const SizedBox(height: 14.0),
          action!,
        ],
      ],
    );

    return Center(
      child: SingleChildScrollView(
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: centered
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(icon, size: 28.0, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 14.0),
                    texts,
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 28.0, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 14.0),
                    Flexible(child: texts),
                  ],
                ),
        ),
      ),
    );
  }
}
