import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';

/// **主页问候头**（2026-10-12 新增 ✓）。
///
/// 位置：主页**最顶端**，靠左、无头像 ✓（用户指定 ✓）。
/// 结构：**大字加粗主标题在上、浅色小字在下**（2026-10-17 调整 ✓ —— 此前是反的 ✗）。
///
/// 为什么调过来：全站其它地方都是"**标题在上、副标题在下**"（页壳、区块头、卡片）✓，
/// 只有这里把小的放上面 ⇒ 视觉上和整个体系不成一套 ✓。而且主页**不再画页标题块**
/// （用户 2026-10-17 指令 ✓）⇒ 这一块就是页面的**唯一一级标题** ✓，顺序必须与页壳一致 ✓。
///
/// 六段时间与文案是用户给定的 ✓（`06:00-09:00` 清晨 … `22:00-05:00` 深夜 ✓ ——
/// 注意**深夜跨零点** ✓，判定顺序不能写反 ✗）。
///
/// `{{user_name}}` 目前是**内嵌占位**「佬友」✓ —— 用户裁定 ✓：
/// 先用这个开发期占位 ✓，等**凭据（cookie）推荐能力**上线后换成**账号昵称** ✓
///（见 `docs/AI_PROGRESS.md` 的待办 ✓）。
///
/// 时间自己要会走 ✓：组件内每分钟看一次表 ✓，跨段（例如 09:00 到点 ✓）时**自动换文案** ✓，
/// 不用等用户重进页面 ✓。
class HomeGreetingHeader extends StatefulWidget {
  const HomeGreetingHeader({
    super.key,
    this.userName = defaultUserName,
    this.now,
    this.returningAfter,
    this.action,
    this.padding = const EdgeInsets.only(
      left: Spacing.lg,
      right: Spacing.lg,
      top: Spacing.xl,
      bottom: Spacing.lg,
    ),
  });

  /// 开发期占位名 ✓（用户裁定 ✓：先用「佬友」，cookie 上线后换成账号昵称 ✓）。
  static const String defaultUserName = '佬友';

  /// 显示名 ✓（`{{user_name}}` 的实参 ✓）。
  final String userName;

  /// 注入"现在"（测试用 ✓）；为 null 时用真实时间并**每分钟自动刷新** ✓。
  final DateTime? now;

  /// 距离上次打开过了多久 ✓：超过 [longAbsence] 就切成「好久不见」✓。
  final Duration? returningAfter;

  /// 问候行右侧的**页级动作**（主页放刷新 ✓）。
  ///
  /// 为什么挂在这里而不是页壳：主页**不再画页标题块** ✓ ⇒ 页壳那一行没了，
  /// 动作只能跟内容一起排 ✓；放这一行的右端，与「查看全部」的右对齐习惯一致 ✓。
  final Widget? action;

  /// 外边距。独立成参数是因为它现在会被放进**横幅**里 ✓（横幅通栏、文字要离边 24）；
  /// 直接写在组件里的话，上层就只能再包一层 Padding 去抵消 ✓。
  final EdgeInsetsGeometry padding;

  /// 超过这个时长没打开 ⇒ 「好久不见，甚是想念」✓（用户给的口径：3 天 ✓）。
  static const Duration longAbsence = Duration(days: 3);

  @override
  State<HomeGreetingHeader> createState() => _HomeGreetingHeaderState();
}

class _HomeGreetingHeaderState extends State<HomeGreetingHeader> {
  Timer? _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = widget.now ?? DateTime.now();
    if (widget.now == null) {
      // 每分钟看一次表 ✓：跨段时自动换文案 ✓（不为每一秒重建 ✗）。
      _timer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => setState(() => _now = DateTime.now()),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final greeting = greetingFor(
      now: _now,
      userName: widget.userName,
      returningAfter: widget.returningAfter,
    );
    return Padding(
      padding: widget.padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // **大字在上** ✓：与页壳的"标题 + 副标题"同一套层级（2026-10-17 调整 ✓）。
                Semantics(
                  header: true,
                  child: Text(
                    greeting.title,
                    style: TextStyle(
                      color: scheme.onSurface,
                      // 大号 + 加粗 ✓（用户指定 ✓）。
                      fontSize: AppType.display,
                      fontWeight: AppType.weightBold,
                    ),
                  ),
                ),
                // 下方浅色小字（这一段可能为空 ⇒ 不留空行 ✓）。
                if (greeting.eyebrow case final eyebrow?) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    eyebrow,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: AppType.body,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (widget.action case final action?) ...[
            const SizedBox(width: Spacing.md),
            action,
          ],
        ],
      ),
    );
  }
}

/// 问候语的纯函数部分 ✓（**可单独测** ✓ —— 时间段边界最容易写错 ✗）。
({String? eyebrow, String title}) greetingFor({
  required DateTime now,
  String userName = HomeGreetingHeader.defaultUserName,
  Duration? returningAfter,
}) {
  // ① 好久没来 ⇒ 优先说这个 ✓（比"现在几点"更重要 ✓）。
  if (returningAfter != null &&
      returningAfter > HomeGreetingHeader.longAbsence) {
    return (eyebrow: '这段时间都没见你', title: '好久不见，甚是想念');
  }

  final minutes = now.hour * 60 + now.minute;
  // ② 时段（顺序：**先判跨零点的深夜** ✓，再按时间递增 ✓）。
  if (minutes >= 6 * 60 && minutes < 9 * 60) {
    return (eyebrow: 'MORNING VIBES', title: '早安，$userName');
  }
  if (minutes >= 9 * 60 && minutes < 11 * 60 + 30) {
    return (eyebrow: '准备进入状态了吗', title: '上午好，$userName');
  }
  if (minutes >= 11 * 60 + 30 && minutes < 14 * 60) {
    return (eyebrow: '小憩片刻，充个电吧', title: '午安，$userName');
  }
  if (minutes >= 14 * 60 && minutes < 18 * 60) {
    return (eyebrow: '伴你度过专注时光', title: '下午好，$userName');
  }
  if (minutes >= 18 * 60 && minutes < 22 * 60) {
    return (eyebrow: '卸下一天的疲惫', title: '晚上好，$userName');
  }
  // 22:00–05:59 ⇒ 深夜 ✓（跨零点 ✓）。
  return (eyebrow: '夜深了，世界安静下来了', title: '要来一首助眠曲吗？');
}
