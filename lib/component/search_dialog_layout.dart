import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 搜索弹窗的外壳（2026-11-04 视觉重设计）。
///
/// 从 `AlertDialog` 换成 `Dialog`：圆角与底色由全应用 `dialogTheme` 统一给出
/// （`lib/entry.dart`：12 圆角 + `surface`），内部节奏完全由这里与
/// `search_dialog.dart` 接管 —— `AlertDialog` 那套 24/16 混用的
/// titlePadding / contentPadding 不再参与布局。
///
/// 与全应用自绘对话框同一套形状（先例：`folder_manager_dialog.dart` 的「管理文件夹」、
/// `lyric_source_view.dart` 的「搜索歌词」）：`insetPadding` 24 + 内层 16 全周。
class SearchDialogFrame extends StatelessWidget {
  const SearchDialogFrame({
    super.key,
    required this.title,
    required this.child,
  });

  final Widget title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 64).clamp(280.0, 900.0).toDouble();
    final height = (size.height - 180).clamp(300.0, 720.0).toDouble();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: Spacing.xl,
        vertical: Spacing.xl,
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.lg),
                child: title,
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class SearchCategoryButton extends StatelessWidget {
  const SearchCategoryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    this.count,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: TextStyle(
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
                fontSize: AppType.caption,
                fontWeight: AppType.weightMedium,
              ),
            ),
          ],
        ],
      ),
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(
          selected ? scheme.onSecondaryContainer : scheme.onSurface,
        ),
        backgroundColor: WidgetStatePropertyAll(
          selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest,
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: selected ? scheme.primary : scheme.outline),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    );
  }
}
