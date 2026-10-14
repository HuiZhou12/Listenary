import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/core/design_tokens.dart';

/// **待接入的货架展位**（2026-10-12 新增 ✓）。
///
/// 用户要求：主页按 YouTube Music 那张图的**结构**重置 ✓，缺数据的先**做出展位** ✓，
/// 等"读取官方接口"的地基补上再填内容 ✓。
///
/// 纪律不变 ✓：展位**不塞假内容** ✗ —— 它会明确写出"**这块要接什么**"（例如"官方推荐接口，
/// 需要登录 Cookie"✓），让人一眼看出它**还没接** ✓，而不是以为"平台没给数据" ✗。
class HomePlaceholderShelf extends StatelessWidget {
  const HomePlaceholderShelf({
    super.key,
    required this.title,
    required this.subtitle,
    required this.source,
    this.icon = Symbols.pending,
  });

  /// 货架名（照图 ✓，例如「猜你喜欢」）。
  final String title;

  /// 一句话说明这块将来装什么（照图里的副标题风格 ✓）。
  final String subtitle;

  /// **它要接哪个接口/能力** ✓ —— 展位上如实写出来 ✓。
  final String source;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ContentSection(
      title: title,
      subtitle: subtitle,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.lg,
        ),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: AppRadius.mdCircular,
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Text(
                // 明确说"还没接" ✓ + 接什么 ✓（不假装是空数据 ✓）。
                '这块还没接：$source',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
