import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:flutter/material.dart';

/// title, actions, body
///
/// 提供基本的响应式布局：
///
/// 小屏幕时，标题在上、操作按钮在下，互不挤压；
/// 中大屏幕时，标题和操作按钮在同一行排列。
///
/// **[title] 可空**（2026-10-12）：有些页面自己就有"大标题"（例如艺人页的 hero 里
/// 已经写着艺人名 ✓）⇒ 页壳再画一遍就是**同一个名字出现两次** ✗。
/// 传 `null` 时页壳**不渲染标题块**（也不画那条分隔渐变 ✓），正文直接从顶部开始 ✓。
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    this.title,
    this.subtitle,
    this.actions = const [],
    required this.body,
  });

  final String? title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasHeader = title != null || actions.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 16.0,
        vertical: 8.0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasHeader) ...[
            ResponsiveBuilder(
              builder: (context, screenType) {
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: switch (screenType) {
                    ScreenType.small => _buildSmallLayout(scheme),
                    ScreenType.medium ||
                    ScreenType.large =>
                      _buildWideLayout(scheme),
                  },
                );
              },
            ),
            Container(
              height: 10,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    scheme.surfaceContainer.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ],
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _buildSmallLayout(ColorScheme scheme) {
    if (actions.isEmpty) {
      return _titleWidget(scheme);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) _titleWidget(scheme),
        const SizedBox(height: 16.0),
        Wrap(spacing: 8.0, runSpacing: 8.0, children: actions),
      ],
    );
  }

  Widget _buildWideLayout(ColorScheme scheme) {
    if (actions.isEmpty) {
      return _titleWidget(scheme);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (title != null) Expanded(child: _titleWidget(scheme)),
        if (title != null) const SizedBox(width: 16.0),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8.0,
              runSpacing: 8.0,
              children: actions,
            ),
          ),
        ),
      ],
    );
  }

  Widget _titleWidget(ColorScheme scheme) {
    // **语义层级**：参考产品的页面标题是 `heading [level=1]`（如专辑页「世界」✓、艺人页「G.E.M. 鄧紫棋」✓）
    // ⇒ 这里标成 header，读屏用户才分得出"这是整页的标题"（纯文本是读不出来的 ✗）。
    final title = this.title ?? '';
    if (subtitle == null) {
      return Semantics(
        header: true,
        child: Text(
          title,
          style: TextStyle(
            fontSize: AppType.display,
            fontWeight: AppType.weightSemibold,
            color: scheme.onSurface,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: TextStyle(
              fontSize: AppType.display,
              fontWeight: AppType.weightSemibold,
              color: scheme.onSurface,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 6.0),
        Text(
          subtitle!,
          style: TextStyle(
            fontSize: AppType.body,
            color: scheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
