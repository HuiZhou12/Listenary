import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pure_music/core/design_tokens.dart';

/// **主页问候头**（2026-10-12 新增 ✓）。
///
/// 位置：主页**最顶端**，靠左、无头像 ✓（用户指定 ✓）。
/// 结构：上方**浅色小字**（可空 ✓）+ 下方**加粗大字主标题** ✓。
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
  });

  /// 开发期占位名 ✓（用户裁定 ✓：先用「佬友」，cookie 上线后换成账号昵称 ✓）。
  static const String defaultUserName = '佬友';

  /// 显示名 ✓（`{{user_name}}` 的实参 ✓）。
  final String userName;

  /// 注入"现在"（测试用 ✓）；为 null 时用真实时间并**每分钟自动刷新** ✓。
  final DateTime? now;

  /// 距离上次打开过了多久 ✓：超过 [longAbsence] 就切成「好久不见」✓。
  final Duration? returningAfter;

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
      padding: const EdgeInsets.only(
        left: Spacing.lg,
        right: Spacing.lg,
        top: Spacing.xl,
        bottom: Spacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 上方浅色小字（这一段可能为空 ⇒ 不留空行 ✓）。
          if (greeting.eyebrow case final eyebrow?) ...[
            Text(
              eyebrow,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: AppType.body,
              ),
            ),
            const SizedBox(height: Spacing.xs),
          ],
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
