import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **守卫：`dispose()` 里不得查 `context` / `Provider.of`。**
///
/// 为什么需要它：`State.dispose()` 执行时 element 已经 deactivated，此时
/// `context.read/watch` 或 `Provider.of` 会命中框架断言
/// "Looking up a deactivated widget's ancestor is unsafe" —— 也就是**每次离开该页面
/// 都会报一次断言**（debug 下直接红屏/异常，release 下行为未定义）。
///
/// 正确做法：在 `initState` / `didChangeDependencies` 里把控制器存进字段，
/// 在 `dispose` 里用那个字段摘监听。
///
/// 这个缺陷曾经真实存在于 `favorites_detail_page`（在收藏页补页面级测试时被暴露出来，
/// **它在那里已经存在很久、没有任何测试碰到**）。这里把它变成不可回归的规则。
///
/// 扫描是**文本级**的（与 `online_music_dependency_boundary_test` 同一套思路）：
/// 从 `void dispose()` 起，直到缩进回到类成员层级（`^  \}$`）为止，都属于该方法体。
/// 因此 `found` 的下界断言很重要 —— 它防止正则失配让这条守卫变成空转。
void main() {
  test('dispose() 不得查 context（会触发 deactivated ancestor 断言）', () {
    const roots = ['lib'];
    final lookup = RegExp(r'context\.(read|watch|maybeRead|maybeWatch)\s*(<|\()'
        r'|Provider\.of\s*(<|\()');
    final disposeStart = RegExp(r'^\s*void dispose\(\)');
    final methodEnd = RegExp(r'^  \}\s*$');

    final violations = <String>[];
    var disposeCount = 0;

    for (final root in roots) {
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          if (!disposeStart.hasMatch(lines[index])) continue;
          disposeCount++;
          final path = entity.path.replaceAll(r'\', '/');
          for (var cursor = index + 1; cursor < lines.length; cursor++) {
            if (methodEnd.hasMatch(lines[cursor])) break;
            if (lookup.hasMatch(lines[cursor])) {
              violations.add('$path:${cursor + 1}  ${lines[cursor].trim()}');
            }
          }
        }
      }
    }

    expect(
      disposeCount,
      greaterThan(20),
      reason: '扫描本身必须真的找到 dispose 方法，否则这条守卫是空转的',
    );
    expect(
      violations,
      isEmpty,
      reason:
          '以下 dispose() 在 element 已 deactivated 后查 context，'
          '每次离开该页面都会报断言。请把控制器存进字段：\n${violations.join('\n')}',
    );
  });
}
