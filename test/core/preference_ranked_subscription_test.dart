import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';

/// **名次集合订阅**（R78）：从榜单订阅进来的歌单，详情页要显示**行首序号**。
///
/// 为什么要用偏好存这个判据：`online_playlists` 是**按列**存的，
/// 而 `online_library_schema_contract_test.dart` 强制 `user_version = 5`（零迁移契约）
/// ⇒ 加列会让契约测试变红。存偏好新增的是"键的值"，**不动 DB schema** ✓。
void main() {
  test('标记幂等，且 isRankedSubscription 只认已标记的 localId', () {
    final preference = AppPreference();

    expect(preference.rankedSubscriptions, isEmpty);
    expect(preference.isRankedSubscription(7), isFalse);

    preference.markRankedSubscription(7);
    preference.markRankedSubscription(7); // 幂等：重复标记不应产生重复项
    preference.markRankedSubscription(9);

    expect(preference.rankedSubscriptions, ['7', '9']);
    expect(preference.isRankedSubscription(7), isTrue);
    expect(preference.isRankedSubscription(9), isTrue);
    expect(preference.isRankedSubscription(8), isFalse, reason: '没标记过的不该被判为名次集合');
  });

  test('加载路径能读回标记（存-取闭环）', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{
      'rankedSubscriptions': ['12', '34'],
    });

    expect(preference.isRankedSubscription(12), isTrue);
    expect(preference.isRankedSubscription(34), isTrue);
    expect(preference.isRankedSubscription(56), isFalse);
  });

  test('旧偏好（没有这个键）不报错，且判据为空', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{'startPage': 5});

    expect(preference.rankedSubscriptions, isEmpty);
    expect(preference.isRankedSubscription(1), isFalse);
  });

  test('脏数据（类型不对）不会让它炸，也不会伪造出标记', () {
    final preference = AppPreference();

    preference.applyStoredMap(<String, dynamic>{
      'rankedSubscriptions': 'not-a-list',
    });

    expect(preference.isRankedSubscription(1), isFalse);
  });
}
