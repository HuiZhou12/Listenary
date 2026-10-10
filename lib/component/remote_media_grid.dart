import 'package:flutter/material.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/design_tokens.dart';

/// 远端内容卡片的**自适应网格**。
///
/// 为什么把这条链放在这里：网格的 `mainAxisExtent` **必须等于卡片的实际高度**，
/// 否则会裁切或溢出；而卡片高度又取决于单元格宽度，单元格宽度取决于列数，列数取决于
/// 可用宽度。"列数 → 卡宽 → 卡高"只要有一处手写就可能对不上，因此收敛到一个组件里，
/// 页面上就不可能算错（已有测试断言"渲染高度 == 声明高度"）。
///
/// 列数下限是 2：窄窗口下宁可卡片变小，也不要挤成一列。
class RemoteMediaGrid extends StatelessWidget {
  const RemoteMediaGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.maxCardWidth = 168,
    this.hasFooter = true,
    this.padding = EdgeInsets.zero,
  });

  final int itemCount;

  /// 回调里给出**算好的单元格宽度**，调用方按它构造卡片（不要再自己算一次）。
  final Widget Function(BuildContext context, int index, double cardWidth)
  itemBuilder;

  /// 单张卡片的宽度上限；超过就换行加列。
  final double maxCardWidth;

  /// 卡片是否带页脚（影响卡片高度，必须与 `itemBuilder` 里实际给的一致）。
  final bool hasFooter;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = Spacing.md;
        var columns = (constraints.maxWidth / (maxCardWidth + spacing)).floor();
        if (columns < 2) columns = 2;
        final cardWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: RemoteMediaCard.extentFor(
              width: cardWidth,
              hasFooter: hasFooter,
            ),
          ),
          itemCount: itemCount,
          itemBuilder: (context, index) => itemBuilder(context, index, cardWidth),
        );
      },
    );
  }
}
