import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';

/// 默认落地页 = **聚合主页**（用户 2026-10-08 确认：主页是多平台聚合体系的主要入口）。
///
/// 这里守住**两处**默认值必须一致：字段初始值 + `applyStoredMap` 的 `defaultValue`。
/// 只改其中一处会让默认值失效（加载路径会用 `defaultValue: 0` 覆盖字段默认值）。
void main() {
  test('全新安装（没有任何偏好键）默认落在聚合主页', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{});

    expect(preference.startPage, app_paths.HOME_START_PAGE_INDEX);
    expect(
      app_paths.START_PAGES[preference.startPage],
      app_paths.HOME_PAGE,
      reason: '默认落地页必须真的是主页',
    );
  });

  test('字段默认值与加载默认值一致（防止只改一处）', () {
    expect(
      AppPreference().startPage,
      app_paths.HOME_START_PAGE_INDEX,
      reason: '字段初始值也必须是主页，否则"未走过加载路径"的场景会落回音乐页',
    );
  });

  test('用户存过的启动页仍然生效，不被新默认值覆盖（不做迁移）', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{'startPage': 0});

    expect(preference.startPage, 0, reason: '老配置里显式存过 0（音乐页）时应保持不动');
  });

  test('越界的启动页下标被 clamp 到表内', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{'startPage': 99});

    expect(preference.startPage, app_paths.START_PAGES.length - 1);
  });
}
