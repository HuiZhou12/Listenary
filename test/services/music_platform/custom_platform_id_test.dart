import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

/// F5-P-39（P0 规则③/④）：新建自定义平台用的**标准 UUID v4** 生成。
void main() {
  final uuidV4 = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  test('★ P-39 生成的 ID 是标准 UUID v4：小写、带连字符、版本/变体位正确', () {
    for (var i = 0; i < 200; i++) {
      final id = generateCustomPlatformId();
      expect(id, matches(uuidV4), reason: '必须是标准 UUID v4 小写形态：$id');
      expect(id, id.toLowerCase());
      expect(id, hasLength(36));
    }
  });

  test('★ P-39 注入可复现的 Random 时结果确定（便于测试与排查）', () {
    final first = generateCustomPlatformId(Random(42));
    final second = generateCustomPlatformId(Random(42));
    expect(first, second);
    expect(first, matches(uuidV4));

    final third = generateCustomPlatformId(Random(43));
    expect(third, isNot(first), reason: '不同种子不应产生同一 ID');
  });

  test('★ P-39 newCustom 产出**有效**身份，且与 tryParse 读回一致（读写成对）', () {
    final identity = PlatformIdentity.newCustom();
    expect(identity.platform, MusicPlatform.custom);
    expect(identity.isValid, isTrue, reason: '新建必须有稳定 ID，否则不可路由');
    expect(
      PlatformIdentity.tryParse(identity.storageValue),
      identity,
      reason: '落库值必须能读回同一身份',
    );
  });

  test('★ P-39 与展示信息无关：同名条目不同 ID ⇒ 不同身份（不得静默并入）', () {
    final a = PlatformIdentity.newCustom(Random(1));
    final b = PlatformIdentity.newCustom(Random(2));
    expect(a == b, isFalse);
    expect(PlatformTrackRef.of(a, 't') == PlatformTrackRef.of(b, 't'), isFalse);
  });
}