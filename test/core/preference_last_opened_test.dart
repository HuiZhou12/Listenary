import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';

/// **上次打开时间**（2026-10-12 新增 ✓）：主页问候头据此判断「好久不见（超过 3 天）✓」。
///
/// 守三件事 ✓：① 全新安装**没有**记录 ⇒ 不说"好久不见" ✓；② 存过就读得回来（跨时区稳定 ✓）；
/// ③ 存坏了（非法字符串）**当作没有记录** ✓ —— 不猜一个时间 ✓（猜错就会平白无故冒出一句"好久不见" ✗）。
void main() {
  test('全新安装（没有任何偏好键）⇒ 没有"上次打开时间"', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{});

    expect(preference.lastOpenedAt, isNull);
  });

  test('存过就读得回来，且是 UTC 的同一时刻', () {
    final preference = AppPreference();
    final moment = DateTime.utc(2026, 10, 12, 8, 30);

    preference.applyStoredMap(<String, dynamic>{
      'lastOpenedAt': moment.toIso8601String(),
    });

    expect(preference.lastOpenedAt, moment);
    expect(preference.lastOpenedAt!.isUtc, isTrue);
  });

  test('存坏了（非法字符串）⇒ 当作没有记录，不猜时间', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{'lastOpenedAt': '不是时间'});

    expect(preference.lastOpenedAt, isNull);
  });

  test('写出去的键是 UTC ISO 字符串（人类可读、跨时区稳定）', () {
    final preference = AppPreference();
    final moment = DateTime.utc(2026, 10, 12, 8, 30);
    preference.lastOpenedAt = moment;

    final map = preference.buildPreferenceMap();

    expect(map['lastOpenedAt'], moment.toIso8601String());
  });
}
