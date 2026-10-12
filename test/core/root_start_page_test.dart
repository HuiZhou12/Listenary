import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/paths.dart';

/// **根路径 `/` = 启动页**（2026-10-12 修正 ✓）。
///
/// 修正前：`/` 的 redirect **硬编码**成「音频」✗，而启动页的默认值是
/// [HOME_START_PAGE_INDEX]（**主页**）✓ —— 两套口径不一致，而且没有任何测试钉住 ✗。
/// 现在两者同源（都走 [startPageLocationFor] ✓），这条测试把"同源"钉住 ✓。
void main() {
  test('根路径落到"启动页"，且默认启动页就是主页', () {
    expect(START_PAGES[HOME_START_PAGE_INDEX], HOME_PAGE);
    // 默认下标（= AppPreference 的字段默认值 ✓）⇒ 根路径应该落到主页 ✓。
    expect(startPageLocationFor(HOME_START_PAGE_INDEX), HOME_PAGE);
    // 用户改成别的启动页 ⇒ 根路径跟着改 ✓。
    expect(startPageLocationFor(0), AUDIOS_PAGE);
  });

  test('下标越界时夹到边界（不抛、也不跳到无关页面）', () {
    expect(startPageLocationFor(-5), START_PAGES.first);
    expect(startPageLocationFor(999), START_PAGES.last);
  });
}
