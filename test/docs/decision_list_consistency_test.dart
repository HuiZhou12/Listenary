import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **文档一致性守卫**：同一件事写在多处时，**必须一致**。
///
/// 为什么要有这个测试：本阶段反复栽在同一件事上 —— **同一份信息散在两处，改了一处**。
/// ⇒ 与其每次靠"记得两边都改"，不如**把它变成会红的断言**。
///
/// 本文件守这些事（2026-10-12 收尾：本任务的设计文档按"完成即删"清理 ✓，
/// 因此原先守 `docs/specs/home-explore-*.md` 通过数与"无孤儿文档"的两条**随之删除** ✓）：
/// 1. `AI_PROGRESS` §1 文档地图里登记的路径**都真实存在**（读者照着找得到）；
/// 2. 验收清单声明的**总数**等于它的**实际条目数**；
/// 3. 清单里**每一组**的声明数量等于该组实际条目数。
///
/// 文件都在 `docs/` 下（本仓库私有、可能被裁剪）⇒ 不存在时**跳过并说明**，
/// 而不是假装通过（"报通过"和"报失败"一样会骗人）。
///
/// 取某个 `## ` 小节直到下一个 `## ` 的正文（用于只在该小节内做断言，避免被历史段落误伤）。
String _sectionOf(String text, String heading) {
  final start = text.indexOf(heading);
  if (start < 0) return '';
  final rest = text.substring(start + heading.length);
  final next = rest.indexOf('\n## ');
  return next < 0 ? rest : rest.substring(0, next);
}

void main() {
  const progressPath = 'docs/AI_PROGRESS.md';
  const checklistPath = 'docs/dev/manual-acceptance-home-explore.md';

  test('AI_PROGRESS §1 文档地图里登记的路径都真实存在', () {
    final progressFile = File(progressPath);
    if (!progressFile.existsSync()) {
      // ignore: avoid_print
      print('跳过：$progressPath 不存在（docs/ 可能被裁剪）');
      return;
    }

    final section = _sectionOf(progressFile.readAsStringSync(), '## 1. 文档地图');
    expect(section, isNotEmpty, reason: '没找到 $progressPath 的"§1 文档地图"小节');

    // 只查**表格行**：§1 里还可能有"已删文档"的历史说明，那里的路径是**已删记录**，
    // 不是"照着去读"的登记项。
    final table = section
        .split('\n')
        .where((line) => line.trimLeft().startsWith('|'))
        .join('\n');
    expect(table, isNotEmpty, reason: '§1 文档地图里没有表格行（格式改了？）');

    // 地图里的路径写成反引号包起来的 `docs/...`；带通配（`*.json`）的跳过。
    final paths = RegExp(r'`(docs/[^`]+)`')
        .allMatches(table)
        .map((m) => m.group(1)!)
        .where((p) => !p.contains('*'))
        .toSet();
    expect(paths, isNotEmpty, reason: '文档地图里没解析出任何 docs/ 路径（表格格式改了？）');

    final missing = [
      for (final p in paths)
        if (!File(p).existsSync() && !Directory(p).existsSync()) p,
    ];
    expect(
      missing,
      isEmpty,
      reason: '文档地图登记了不存在的路径：${missing.join(', ')}（读者会照着找，找不到就是骗人）',
    );
  });

  test('人工验收清单声明的总数 == 实际条目数', () {
    final file = File(checklistPath);
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('跳过：$checklistPath 不存在（docs/ 可能被裁剪）');
      return;
    }
    final text = file.readAsStringSync();

    final stated = RegExp(r'＝\s*\*\*(\d+)\*\*\s*项').firstMatch(text);
    expect(stated, isNotNull, reason: '清单里没找到"＝ **N** 项"那行统计');

    // 条目行形如 `| H1 | …`、`| E13b | …`、`| T1 真的没有内容 | …`。
    // §7 记录表里的**区间行**（如 `| S1–S4（含 S3b） |`）也以 id 开头，所以逐行过滤掉它们。
    final idRow = RegExp(r'^\| ([HENDSTR]\d+b?)(.)');
    var rows = 0;
    for (final line in text.split('\n')) {
      final match = idRow.firstMatch(line);
      if (match == null) continue;
      final next = match.group(2)!;
      if (next == '–' || next == '—') continue; // 区间行，不是条目
      if (next != ' ' && next != '|') continue; // 只认 `| H1 |` 与 `| T1 说明 |`
      rows++;
    }

    expect(rows, greaterThan(0), reason: '没数出任何条目行（表格格式是不是改了？）');
    expect(
      rows,
      int.parse(stated!.group(1)!),
      reason: '清单声明的总数与实际条目数不符',
    );
  });

  test('清单里**每一组**的声明数量 == 该组实际条目数', () {
    final file = File(checklistPath);
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('跳过：$checklistPath 不存在（docs/ 可能被裁剪）');
      return;
    }
    final text = file.readAsStringSync();

    // 统计行里的分组数字：`主页 **12**（H1–H12）＋探索 **16**（…）＋窄窗 **4** …`
    final declared = <String, int>{};
    for (final match in RegExp(
      r'(主页|探索|窄窗|高 DPI|三态|来源|回归)\s*\*\*(\d+)\*\*',
    ).allMatches(text)) {
      declared[match.group(1)!] = int.parse(match.group(2)!);
    }
    expect(
      declared.keys.toSet(),
      {'主页', '探索', '窄窗', '高 DPI', '三态', '来源', '回归'},
      reason: '统计行里的分组名与预期不符（少了或多了某一组）',
    );

    const prefixOf = {
      '主页': 'H',
      '探索': 'E',
      '窄窗': 'N',
      '高 DPI': 'D',
      '三态': 'T',
      '来源': 'S',
      '回归': 'R',
    };
    final actual = <String, int>{};
    prefixOf.forEach((group, prefix) {
      // 条目行：`| H1 | …`、`| E13b | …`、`| T1 真的没有内容 | …`；
      // id 之后必须是空白或 `|`，这样 §7 记录表里的区间行不会被算进来。
      actual[group] = RegExp(
        '^\\| $prefix\\d+b?[\\s|]',
        multiLine: true,
      ).allMatches(text).length;
    });

    expect(actual, declared, reason: '某一组的声明数量与实际条目数不符');
  });
}
