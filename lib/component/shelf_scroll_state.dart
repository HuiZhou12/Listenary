import 'package:flutter/foundation.dart';

/// **货架的滚动状态**（2026-10-12 新增 ✓）。
///
/// 为什么要有它：参考产品的「◀ ▶」在**区块标题那一行的右侧** ✓，
/// 而"能不能往某一侧滚"只有货架自己知道 ✗。
/// ⇒ 货架把状态**报**给这个对象 ✓，区块头部**监听**它来画箭头 ✓。
///
/// 约定（与 [HorizontalShelf] 原有的覆盖层箭头同一条规则 ✓）：
/// **只在"确实还能往那一侧滚"时才渲染该箭头** ✓ ——
/// 到边界就没有可点的东西 ✓，也不会挡住第一张/最后一张卡片的点击 ✓。
class ShelfScrollState extends ChangeNotifier {
  bool _canScrollLeft = false;
  bool _canScrollRight = false;
  void Function(bool forward)? _page;

  bool get canScrollLeft => _canScrollLeft;
  bool get canScrollRight => _canScrollRight;

  /// 货架是否已注册翻页动作 ✓（没注册就说明还没有货架在用它 ⇒ 不画箭头 ✓）。
  bool get isAttached => _page != null;

  /// 由货架在滚动位置变化时调用 ✓（**只在真的变了**时通知 ✓，避免每帧重建 ✗）。
  void report({required bool canLeft, required bool canRight}) {
    if (canLeft == _canScrollLeft && canRight == _canScrollRight) return;
    _canScrollLeft = canLeft;
    _canScrollRight = canRight;
    notifyListeners();
  }

  /// 货架注册翻页动作 ✓（[forward] 为 true 表示往右翻 ✓）。
  void attach(void Function(bool forward) page) => _page = page;

  /// 货架销毁时注销 ✓；同时把两侧余量清成"都没有" ✓（否则头部会留着一个点不动的箭头 ✗）。
  void detach() {
    _page = null;
    report(canLeft: false, canRight: false);
  }

  void pageBack() => _page?.call(false);
  void pageForward() => _page?.call(true);
}
