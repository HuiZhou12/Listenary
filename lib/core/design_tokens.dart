import 'package:flutter/material.dart';

abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double bottomNav = 96;
}

abstract final class AppRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;

  static final BorderRadius xsCircular = BorderRadius.circular(xs);
  static final BorderRadius smCircular = BorderRadius.circular(sm);
  static final BorderRadius mdCircular = BorderRadius.circular(md);
}

/// **列表框的行高**（滚动布局用的固定高度）。
///
/// 为什么只收这一个：`ListView.itemExtent` / `SliverFixedExtentList.itemExtent` 一旦
/// 与行内实际高度脱钩，整个列表就会裁切或错位 —— 它此前在 `uni_page` 与
/// `uni_detail_page` 各写一遍 `64`，改一处漏一处就会变成"同一首歌在这页 64、那页别的值"。
///
/// ⚠️ 这里刻意**不收**行组件自身的高度：曲目行（`online_track_row`）是"外间距 2 + 内盒
/// 64"＝实际**占 68**，与"滚动格子给 64"不是同一个语义 ⇒ 硬并成一个常量反而会造出新错。
abstract final class AppExtent {
  /// 列表 / 详情页里一行内容占的滚动格子高度。
  static const double listRow = 64;
}

/// **同一排动作按钮的统一规格**（详情页的「播放全部 / 随机播放 / 刷新 …」）。
///
/// 为什么要有它：这些按钮是**并排**出现的，高度一旦不一致就是肉眼可见的杂乱 ——
/// 而主题里只定了圆角与内边距（见 `entry.dart`），**高度**得每个按钮自己给 ⇒ 此前这份
/// `fixedSize + padding` 被复制了 8 份（含 `uni_page_components`），谁漏给一次就复现
/// 一次"一排按钮高矮不一" ✓。
///
/// 只覆盖"主操作按钮"这一种：`folders_page` 的视图切换、`playlists_page` 的对话框按钮
/// 等虽然也写了 40，但它们是**另一种语境**（不是同一排主操作）⇒ 本轮不去动它们 ✓。
abstract final class AppButtonStyle {
  static const ButtonStyle primaryAction = ButtonStyle(
    fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
  );
}

abstract final class AppType {
  static const double microlabel = 10;
  static const double caption = 12;
  static const double body = 14;
  static const double subtitle = 16;
  static const double sectionTitle = 18;
  static const double pageTitle = 20;
  static const double hero = 24;
  static const double display = 32;

  static const FontWeight weightRegular = FontWeight.w400;
  static const FontWeight weightMedium = FontWeight.w500;
  static const FontWeight weightSemibold = FontWeight.w600;
  static const FontWeight weightBold = FontWeight.w700;
}

abstract final class Alpha {
  static const double hover = 0.04;
  static const double focus = 0.04;
}
