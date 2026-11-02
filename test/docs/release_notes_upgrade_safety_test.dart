import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **R16（Q5 / Spec §4.5）**：发布说明的升级安全义务必须**机器可断言**。
///
/// 为什么需要这条：`play_count` 迁到 `app.sqlite` 之后存在两个**用户可见**的
/// 行为变化，只能靠发布说明传达：
/// 1. **降级分叉** —— 装回旧版本后，新版本产生的播放次数在旧版不可见
///    （Spec §4.5 ①②③）；
/// 2. **升级安全** —— 本次升级会改曲库数据文件，**程序不会自动备份**，
///    用户必须自己备份 `library.sqlite` 与 `db/app.sqlite`（Spec §4.5 ④⑤）。
///
/// 这两段文字如果漏写，用户会在毫无提示的情况下丢掉可恢复性。把它写成断言，
/// 比"记得每次发版都补一句"可靠。
///
/// 断言口径是**关键词存在性**，不比对整段行文：措辞可以改，事实不能丢。
void main() {
  const notesPath = '3.5-b-release-notes.txt';
  late String notes;

  setUpAll(() {
    final file = File(notesPath);
    expect(file.existsSync(), isTrue, reason: '找不到发布说明 $notesPath');
    notes = file.readAsStringSync();
  });

  group('§4.5 ①②③ 降级分叉三句话', () {
    test('① 本地播放次数改存到应用库', () {
      expect(
        notes,
        contains('播放次数改存到应用库'),
        reason: '必须说明播放次数换了存放位置（app.sqlite）',
      );
    });

    test('② 历史次数已一次性导入、统计页显示不变', () {
      expect(notes, contains('历史次数已一次性导入'));
      expect(notes, contains('统计页显示不变'));
    });

    test('③ 回退旧版后新产生的次数在旧版不可见', () {
      expect(notes, contains('在旧版不可见'), reason: '必须点明降级后两侧计数不可见，不得含糊');
    });

    test('不得用「无影响」类表述掩盖分叉', () {
      // Spec §4.5 禁止条款：不许写成「数据已迁移完成、无影响」。
      for (final banned in <String>['无影响', '没有任何影响', '数据已完整迁移且无影响']) {
        expect(notes, isNot(contains(banned)), reason: '禁止掩盖计数分叉的表述：「$banned」');
      }
    });
  });

  group('§4.5 ④⑤ 升级安全（手动备份与降级处置）', () {
    test('明确「程序不会自动备份」', () {
      expect(notes, contains('程序不会自动备份'), reason: '必须打破「升级会帮我备份」的默认预期');
    });

    test('给出需要备份的文件位置', () {
      expect(notes, contains('library.sqlite'), reason: '必须点名曲库数据文件');
      expect(notes, contains('db/app.sqlite'), reason: '必须点名应用库文件及其所在子目录');
      expect(notes, contains('ListenaryData'), reason: '便携版数据目录必须可定位');
    });

    test('给出旧版回退的预期与兜底步骤', () {
      expect(notes, contains('旧版可以直接打开'), reason: '降级说明必须给出可预期结论');
      expect(notes, contains('覆盖回去'), reason: '若旧版打开异常，必须有恢复步骤（用备份覆盖）');
    });

    test('降级结论标注了待实测边界（不冒充已验证）', () {
      // Spec rev 3 允许先采用静态结论，但必须显式标注「待验证」，
      // 不得把未做过的真机回退演练写成既成事实。
      expect(
        notes,
        anyOf(contains('待验证'), contains('待实测'), contains('真机回退演练')),
        reason: '静态结论必须标注尚未实测，不得表述为运行时验收完成',
      );
    });
  });

  group('守卫自身有效性', () {
    test('the release notes are non-trivial (guard is not vacuous)', () {
      // 防止空文件或只留标题时上面所有 contains 都靠巧合通过。
      expect(notes.length, greaterThan(300));
      expect(
        RegExp(r'^###', multiLine: true).allMatches(notes).length,
        greaterThanOrEqualTo(4),
        reason: '至少要有「变更 / 备份 / 回退 / 版本守卫」四个小节',
      );
    });
  });
}
