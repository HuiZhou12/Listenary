import 'dart:io';

import 'package:flutter/material.dart';

/// 主页顶部**横幅背景**（2026-10-17 ✓）。
///
/// **只负责背景**：一张用户自选的图 + 两层 alpha 遮罩。它**不认识**任何业务区块 ✓
///（把"第一个区块的头"塞进来是错的 ✗ —— 那会破坏 `ContentSection` 的内聚性：
/// 第一个区块隐藏时难道还要去吞第二个区块的头？✓）。
///
/// 它铺满**调用方给的那一块**（主页的"名片带"整条宽）✓；图片本身只占右侧一段
/// （[imageWidthFactor]）并淡出到左侧与底部 ⇒ 左边的问候语永远落在干净处 ✓。
///
/// 两层遮罩（`BlendMode.dstIn`，直接改图片自己的 alpha ✓ —— 换深浅主题
/// **不需要改任何颜色** ✓）：
/// 1. **斜向**：左下 → 右上，左侧 25% 完全透明（问候语那块必须纯净 ✓）；
/// 2. **底部收口**：bottom → top 的前 35% 淡出，消除生硬横切线 ✓。
class HomeHeroBanner extends StatelessWidget {
  const HomeHeroBanner({
    super.key,
    this.bannerPath,
    this.imageWidthFactor = 0.72,
  });

  /// 用户横幅的本地图片路径（偏好键 `homeBannerPath` ✓）。
  ///
  /// 为 null / 空 / 文件已不存在 ⇒ 什么都不画 ✓（页面底色露出来 ✓）。
  final String? bannerPath;

  /// 图片占这一条带子的宽度比例 ✓（左侧留给问候语，不做"全宽压暗" ✗）。
  final double imageWidthFactor;

  /// 斜向遮罩：左侧 25% 完全透明 ⇒ 问候语区域 100% 纯净，右侧透出图片 ✓。
  static const LinearGradient diagonalMask = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [Colors.transparent, Colors.transparent, Colors.black],
    stops: [0.0, 0.25, 0.9],
  );

  /// 底部收口：底部 35% 淡出，让图片无缝融进下方区块 ✓。
  static const LinearGradient bottomMask = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Colors.transparent, Colors.black],
    stops: [0.0, 0.35],
  );

  @override
  Widget build(BuildContext context) {
    final path = bannerPath;
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      // 背景不参与点击 ✓（不挡下面的卡片与按钮）。
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: imageWidthFactor,
          heightFactor: 1,
          child: ClipRect(
            child: ShaderMask(
              // 外层：底部收口 ✓。
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => bottomMask.createShader(rect),
              child: ShaderMask(
                // 内层：斜向淡出 ✓。
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => diagonalMask.createShader(rect),
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  // 优先保留图片**右侧**的视觉中心 ✓（左侧要留给文字）。
                  alignment: Alignment.centerRight,
                  // 文件没了 / 不是图片 ⇒ 什么都不画 ✓，不抛错 ✓。
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
