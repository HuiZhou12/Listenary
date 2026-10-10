import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 行尾的**来源标记**：小圆点 + 小号低对比文字。
///
/// 为什么做成这样（Spec §19.6）：多平台聚合后每一行都必须能看出"来自哪个平台"，
/// 但来源是**辅助信息**，不能用固定宽度的徽章把标题/艺人挤成一小条。
/// 因此它只是一段小号、低对比的行尾文字；调用方负责把它放在可省略文本之后。
class OnlineSourceLabel extends StatelessWidget {
  const OnlineSourceLabel({
    super.key,
    required this.label,
    required this.color,
  });

  /// 平台展示名（[musicPlatformLabel] 的结果或等价文案）。
  final String label;

  /// 当前行的元信息颜色；圆点与文字都由它派生（保持既有设计 token 体系）。
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 4,
          height: 4,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.7),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: Spacing.xs),
        Text(
          label,
          key: const ValueKey('online-source-label'),
          maxLines: 1,
          style: TextStyle(
            color: color.withValues(alpha: 0.8),
            fontSize: AppType.caption,
          ),
        ),
      ],
    );
  }
}
