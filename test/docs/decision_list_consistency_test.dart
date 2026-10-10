import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **文档一致性守卫**：同一件事写在多处时，**必须一致**。
///
/// 为什么要有这个测试：本阶段反复栽在同一件事上 —— **同一份信息散在两处，改了一处**：
/// - R34 一个数字散在 4 份文档；R41 一条归因散在 4 处；R43 grill 17 条只跟了 6 条；
/// - R56 把待决项拆成"索引 + 详情"两处，**当轮就预言它会漂**；**R62 去核，果然漂了 3 处**
///   （索引漏了 `R47`、F8 的数字停在旧值、编号 7/8 顺序颠倒）；
/// - R53/R54 验收清单的**总数**改了两次（52 → 53 → 55），每次都要手工全仓找。
///
/// ⇒ 与其每次靠"记得两边都改"，不如**把它变成会红的断言**。本文件守三件事：
/// 1. 索引与详情列**同一组**待决项（集合与数量）；
/// 2. `F8` 的**提交范围数字**在两处相同（R62 漂的就是它）；
/// 3. 验收清单声明的**总数**等于它的**实际条目数**（R53/R54 漂的就是它）。
///
/// 文件都在 `docs/` 下（本仓库私有、可能被裁剪）⇒ 不存在时**跳过并说明**，
/// 而不是假装通过（"报通过"和"报失败"一样会骗人，R62 已经吃过一次）。
void main() {
  const progressPath = 'docs/AI_PROGRESS.md';
  const briefPath = 'docs/specs/home-explore-decision-brief.md';
  const checklistPath = 'docs/dev/manual-acceptance-home-explore.md';

  final briefRow = RegExp(r'^\| \*\*([A-Z0-9]+)\*\* \|');
  final numberedOrBullet = RegExp(r'^(?:\d+\.|-)\s+\*\*(F\d+|Q\d+|N\d+|R\d+)');

  List<String> idsFromProgress(String text) {
    final lines = text.split('\n');
    var inside = false;
    final ids = <String>[];
    for (final line in lines) {
      if (line.startsWith('**等待用户决定')) {
        inside = true;
        continue;
      }
      if (inside && line.startsWith('**环境/凭据状态')) break;
      if (!inside) continue;
      final match = numberedOrBullet.firstMatch(line.trim());
      if (match != null) ids.add(match.group(1)!);
    }
    return ids;
  }

  List<String> idsFromBrief(String text) {
    final lines = text.split('\n');
    var inside = false;
    final ids = <String>[];
    for (final line in lines) {
      if (RegExp(r'^## 0\.').hasMatch(line)) {
        inside = true;
        continue;
      }
      if (inside && line.startsWith('## ')) break;
      if (!inside) continue;
      final match = briefRow.firstMatch(line);
      if (match != null) ids.add(match.group(1)!);
    }
    return ids;
  }

  test('索引（AI_PROGRESS §4）与详情（Decision Brief §0）列出同一组待决项', () {
    final progressFile = File(progressPath);
    final briefFile = File(briefPath);
    if (!progressFile.existsSync() || !briefFile.existsSync()) {
      // ignore: avoid_print
      print('跳过：$progressPath 或 $briefPath 不存在（docs/ 可能被裁剪）');
      return;
    }

    final indexIds = idsFromProgress(progressFile.readAsStringSync());
    final briefIds = idsFromBrief(briefFile.readAsStringSync());

    // 先保证"两边都真的解析到了东西"——否则空 == 空 会让这个测试变成摆设。
    expect(
      indexIds,
      isNotEmpty,
      reason: '没从 $progressPath §4 解析出任何条目（是不是标题改了？）',
    );
    expect(
      briefIds,
      isNotEmpty,
      reason: '没从 $briefPath §0 解析出任何条目（是不是小节标题或表格格式改了？）',
    );

    expect(
      indexIds.toSet(),
      briefIds.toSet(),
      reason:
          '索引与详情必须列同一组待决项。'
          '只在索引里：${indexIds.toSet().difference(briefIds.toSet())}；'
          '只在详情里：${briefIds.toSet().difference(indexIds.toSet())}。'
          '（改一处就够了吗？R62 已经证明不够。）',
    );
    expect(indexIds.length, briefIds.length, reason: '两处条目数必须一致（不能有重复项）');
  });

  test('F8 的"提交范围"数字在索引与详情里必须一致（R62 漂的就是它）', () {
    final progressFile = File(progressPath);
    final briefFile = File(briefPath);
    if (!progressFile.existsSync() || !briefFile.existsSync()) {
      // ignore: avoid_print
      print('跳过：决策文档不存在（docs/ 可能被裁剪）');
      return;
    }

    /// 抓"修改文件数"与"新增 Dart 数"。
    ///
    /// **必须锚定到 F8 那一条**，不能在全文里取第一次出现 —— 报告与历史条目里会**引用旧数字**
    /// （例如某轮报告写着"F8 仍写（39 个修改文件 + 24 个新 Dart）"），全文取第一次会**误报**。
    /// 锚点：索引里是 `4. **F8 …`，详情里是 `**待提交范围**`。
    (int, int)? numbersOf(String text, RegExp anchor) {
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!anchor.hasMatch(lines[i].trim())) continue;
        // 该条目可能跨行，取这一行与下一行一起找。
        final block = lines.skip(i).take(2).join('\n');
        final modified = RegExp(
          r'(\d+)\s*个\s*(?:已跟踪文件被修改|修改文件)',
        ).firstMatch(block);
        final added = RegExp(
          r'(\d+)\s*个\s*(?:新增 Dart 文件|新 Dart 文件)',
        ).firstMatch(block);
        if (modified == null || added == null) continue;
        return (int.parse(modified.group(1)!), int.parse(added.group(1)!));
      }
      return null;
    }

    final indexNumbers = numbersOf(
      progressFile.readAsStringSync(),
      RegExp(r'^\d+\. \*\*F8'),
    );
    final briefNumbers = numbersOf(
      briefFile.readAsStringSync(),
      RegExp(r'\*\*待提交范围\*\*'),
    );
    expect(indexNumbers, isNotNull, reason: '没从索引里解析出 F8 的提交范围数字');
    expect(briefNumbers, isNotNull, reason: '没从详情里解析出 F8 的提交范围数字');
    expect(
      indexNumbers,
      briefNumbers,
      reason:
          'F8 的提交范围两处必须相同（R62 就是"改了详情、没改索引"）。'
          '索引：$indexNumbers；详情：$briefNumbers。',
    );
  });

  test('人工验收清单声明的总数 == 实际条目数（R53/R54 漂的就是它）', () {
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
      reason: '清单声明的总数与实际条目数不符（R53/R54 就是这里漂的）',
    );
  });

  test('清单里**每一组**的声明数量 == 该组实际条目数（R53/R54 也是这一类）', () {
    final file = File(checklistPath);
    if (!file.existsSync()) {
      // ignore: avoid_print
      print('跳过：$checklistPath 不存在（docs/ 可能被裁剪）');
      return;
    }
    final text = file.readAsStringSync();

    // 统计行里的分组数字：`主页 **11**（H1–H11）＋探索 **18**（…）＋窄窗 **4** …`
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
      // id 之后必须是空白或 `|`，这样 §7 记录表里的区间行（`| S1–S4（…） |`）不会被算进来。
      actual[group] = RegExp(
        '^\\| $prefix\\d+b?[\\s|]',
        multiLine: true,
      ).allMatches(text).length;
    });

    expect(
      actual,
      declared,
      reason: '某一组的声明数量与实际条目数不符（R53/R54 就是这里漂的）',
    );
  });

  test('两份自检文档里的"test N passed"必须与当前数字一致（R75：它们停在 1149/1165）', () {
    final progressFile = File(progressPath);
    if (!progressFile.existsSync()) {
      // ignore: avoid_print
      print('跳过：$progressPath 不存在（docs/ 可能被裁剪）');
      return;
    }
    // 「当前数字」以 AI_PROGRESS §1 的那行为准（本阶段唯一实时维护的总数）。
    final currentMatch = RegExp(
      r'flutter test`\s*→\s*\*\*(\d+) passed\*\*',
    ).firstMatch(progressFile.readAsStringSync());
    expect(currentMatch, isNotNull, reason: '没从 $progressPath §1 解析出当前测试总数');
    final current = int.parse(currentMatch!.group(1)!);

    for (final path in const [
      'docs/specs/home-explore-acceptance-audit.md',
      'docs/specs/home-explore-goal-audit.md',
    ]) {
      final file = File(path);
      if (!file.existsSync()) {
        // ignore: avoid_print
        print('跳过：$path 不存在（docs/ 可能被裁剪）');
        continue;
      }
      // 只看**当前状态**的说法；行内含"基线"的按基线记录看待（例如"基线转绿（981 passed）"）。
      final stale = <String>[];
      for (final line in file.readAsLinesSync()) {
        if (line.contains('基线')) continue;
        for (final match in RegExp(r'(\d+)\s*passed').allMatches(line)) {
          final value = int.parse(match.group(1)!);
          if (value != current) stale.add('$value');
        }
      }
      expect(
        stale,
        isEmpty,
        reason:
            '$path 里有与当前（$current）不一致的测试总数：${stale.join(', ')}。'
            '这两份是自检文档，读者会照它判断"现在多少条"。',
      );
    }
  });
}
