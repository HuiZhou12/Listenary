import 'package:flutter/widgets.dart';
import 'package:pure_music/component/remote_media_card.dart';

/// **横向货架的卡片几何**：宽与高都在这里算，页面与货架组件都不自己算。
///
/// 为什么要有它：同一套"封面整体放大 15%"的取宽规则此前被复制过 **4 份**
/// （探索页 ×2、主页、艺人页），专辑货架里又是第 5 份 ⇒ 任何一次尺寸调整都可能只改到
/// 其中几处，表现就是"同一页两排卡片封面不一样大"。
///
/// 两条硬约束（别在这里"顺手优化" ✗）：
/// - **`RemoteMediaCard.widthFor` / `extentFor` 的数值不能改**：它们被
///   `test/component/remote_media_card_test.dart` 当作数值契约钉住（124/140/156、198/238/164）；
///   这里只是**调用并放大**，不重新定义。
/// - **网格（`RemoteMediaGrid`）不走这条规则**：网格的卡片宽度由格子决定
///   （`maxCardWidth = 168` 是另一套语义），货架的放大系数不该套到网格上。
abstract final class ShelfGeometry {
  /// 货架卡片相对基础卡宽的放大系数（R100 起"封面整体放大 15%"✓）。
  static const double upscale = 1.15;

  /// 货架里一张卡片的宽度（按当前视口）。
  static double cardWidth(BuildContext context) =>
      RemoteMediaCard.widthFor(MediaQuery.sizeOf(context)) * upscale;

  /// 货架里一张卡片的高度 —— **必须用它算 `HorizontalShelf.itemHeight`**：
  /// 货架高度一旦与卡片实际高度不一致，卡片就会被裁掉 ✓。
  static double cardExtent({required double width, bool hasFooter = false}) =>
      RemoteMediaCard.extentFor(width: width, hasFooter: hasFooter);
}
