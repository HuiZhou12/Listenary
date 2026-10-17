import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';

/// **主页横幅**（2026-10-17 新增 ✓）：用户自己填的本地图片路径。
///
/// 守四件事 ✓：① 全新安装**没有**横幅 ⇒ 主页回落页面底色 ✓；② 存过就读得回来 ✓；
/// ③ 空串/非法值**当作没设置** ✓（不留一个半截路径去让界面报错 ✗）；
/// ④ 改完横幅时**可监听值同步** ✓ —— 设置页改完，主页不用重进就能看到 ✓。
void main() {
  test('全新安装（没有这个键）⇒ 没有横幅', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{});

    expect(preference.homeBannerPath, isNull);
    expect(preference.homeBannerPathListenable.value, isNull);
  });

  test('存过就读得回来，且可监听值同步（设置页改完主页立刻能看到）', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{
      'homeBannerPath': r'C:\Pictures\banner.png',
    });

    expect(preference.homeBannerPath, r'C:\Pictures\banner.png');
    expect(preference.homeBannerPathListenable.value, r'C:\Pictures\banner.png');
  });

  test('空串 / 非字符串 ⇒ 当作没设置（不猜路径）', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{'homeBannerPath': '   '});
    expect(preference.homeBannerPath, isNull);

    preference.applyStoredMap(<String, dynamic>{'homeBannerPath': 42});
    expect(preference.homeBannerPath, isNull);
  });

  test('写出去的键就是当前横幅', () {
    final preference = AppPreference();
    preference.setHomeBannerPath(r'C:\Pictures\banner.png');

    expect(
      preference.buildPreferenceMap()['homeBannerPath'],
      r'C:\Pictures\banner.png',
    );
  });

  test('清除横幅（setHomeBannerPath(null)）⇒ 键写成 null，可监听值也清空', () {
    final preference = AppPreference();
    preference.setHomeBannerPath(r'C:\Pictures\banner.png');

    preference.setHomeBannerPath(null);

    expect(preference.homeBannerPath, isNull);
    expect(preference.homeBannerPathListenable.value, isNull);
    expect(preference.buildPreferenceMap()['homeBannerPath'], isNull);
  });
}
