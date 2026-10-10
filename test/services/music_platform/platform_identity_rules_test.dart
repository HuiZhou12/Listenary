import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

/// F5（P-39 / 用户 P0 裁定）：**统一平台身份**的规则与不变量。
///
/// 这是后续所有跨层改动（路由 / 聚合 / 日志 / 数据库读回 / 可用性复核）的地基：
/// 身份相等性一旦错，聚合 map、缓存键与权限都会串台。
void main() {
  test('★ P-39 内置平台身份：稳定 ID 为空、有效、持久化值就是枚举名', () {
    const identity = PlatformIdentity.builtin(MusicPlatform.netease);

    expect(identity.platform, MusicPlatform.netease);
    expect(identity.platformId, isNull, reason: '内置平台不携带稳定 ID');
    expect(identity.isCustom, isFalse);
    expect(identity.isValid, isTrue);
    expect(identity.storageValue, 'netease', reason: '内置平台按原规则落库');
  });

  test('★ P-39 两个自定义平台即使 track_id 相同，也必须是**不同曲目**', () {
    const alpha = PlatformIdentity.custom('0f9a1c2e-1111-4111-8111-aaaaaaaaaaaa');
    const beta = PlatformIdentity.custom('0f9a1c2e-2222-4222-8222-bbbbbbbbbbbb');

    final alphaRef = PlatformTrackRef.of(alpha, 'same-id');
    final betaRef = PlatformTrackRef.of(beta, 'same-id');

    expect(
      alphaRef == betaRef,
      isFalse,
      reason: '曲目身份的键是 (PlatformIdentity, trackId) ⇒ 不同自定义平台绝不相等',
    );
    expect(alphaRef.hashCode == betaRef.hashCode, isFalse);
    expect(alphaRef.identity, alpha);
    expect(betaRef.identity, beta);
    expect(
      alphaRef == PlatformTrackRef.of(alpha, 'same-id'),
      isTrue,
      reason: '同一身份同一 trackId 仍相等（不误伤）',
    );
    // 兼容路径：直接传 `platformId` 与用身份构造必须等价。
    expect(
      const PlatformTrackRef(
        platform: MusicPlatform.custom,
        platformId: '0f9a1c2e-1111-4111-8111-aaaaaaaaaaaa',
        trackId: 'same-id',
      ),
      alphaRef,
    );
  });

  test('★ P-39 无效自定义身份：缺稳定 ID ⇒ 不可用于路由（fail-closed）', () {
    const missing = PlatformIdentity.custom('');
    const blank = PlatformIdentity.custom('   ');

    expect(missing.isValid, isFalse);
    expect(blank.isValid, isFalse, reason: '空白不算有效稳定 ID');
    expect(
      PlatformTrackRef.of(missing, 't1').hasValidIdentity,
      isFalse,
      reason: '未取得有效稳定 ID 的自定义配置不得参与网络路由',
    );
    expect(
      const PlatformTrackRef(
        platform: MusicPlatform.custom,
        trackId: 't1',
      ).hasValidIdentity,
      isFalse,
      reason: '连 platformId 都没给 ⇒ 同样不可路由',
    );
  });

  test('★ P-39 读回规则：已知内置名按原规则，其他值原样保留为稳定 ID（不回落网易云）', () {
    expect(
      PlatformIdentity.tryParse('netease'),
      const PlatformIdentity.builtin(MusicPlatform.netease),
    );
    expect(
      PlatformIdentity.tryParse(' qq '),
      const PlatformIdentity.builtin(MusicPlatform.qq),
    );
    expect(
      PlatformIdentity.tryParse('kugou'),
      const PlatformIdentity.builtin(MusicPlatform.kugou),
    );

    const legacyValue = 'MyOwnProxy_2024'; // 历史数据里认不出的平台值
    final parsed = PlatformIdentity.tryParse(legacyValue);
    expect(parsed, isNotNull, reason: '历史值必须能安全保留原始身份');
    expect(parsed!.platform, MusicPlatform.custom);
    expect(parsed.platformId, legacyValue, reason: '原样保留、不做大小写归一，也不推断');
    expect(
      parsed.platform,
      isNot(MusicPlatform.netease),
      reason: '认不出的值**绝不回落网易云**',
    );

    // `custom` 一词本身没有稳定 ID ⇒ 身份无效（调用方必须 fail-closed）。
    expect(PlatformIdentity.tryParse('custom'), isNull);
    expect(PlatformIdentity.tryParse(''), isNull);
    expect(PlatformIdentity.tryParse(null), isNull);
  });

  test('★ P-39 持久化往返：storageValue 读回来必须得到同一身份（读写成对）', () {
    const values = <PlatformIdentity>[
      PlatformIdentity.builtin(MusicPlatform.netease),
      PlatformIdentity.builtin(MusicPlatform.qq),
      PlatformIdentity.builtin(MusicPlatform.kugou),
      PlatformIdentity.custom('0f9a1c2e-3333-4333-8333-cccccccccccc'),
      PlatformIdentity.custom('Legacy-Mixed-Case-ID'),
    ];

    for (final identity in values) {
      expect(
        PlatformIdentity.tryParse(identity.storageValue),
        identity,
        reason: '写入值 ${identity.storageValue} 必须能读回同一身份',
      );
    }
  });

  test('★ P-39 身份与展示信息无关：改展示名 / Base URL 不影响相等性', () {
    const id = '0f9a1c2e-4444-4444-8444-dddddddddddd';
    const identity = PlatformIdentity.custom(id);

    // 展示名与 Base URL 属于**条目配置**，不进入身份：
    // 同样的 id ⇒ 相等；不同的 id ⇒ 即使名字一样也不相等。
    expect(identity == const PlatformIdentity.custom(id), isTrue);
    expect(
      identity ==
          const PlatformIdentity.custom('0f9a1c2e-5555-4555-8555-eeeeeeeeeeee'),
      isFalse,
    );
    expect(identity.debugLabel, 'custom:$id', reason: 'debugLabel 只用于诊断，不参与比较');
  });

  test('★ P-39 builtinMusicPlatforms 不含 custom（界面枚举内置平台用）', () {
    expect(builtinMusicPlatforms, isNot(contains(MusicPlatform.custom)));
    expect(
      builtinMusicPlatforms,
      containsAll(<MusicPlatform>[
        MusicPlatform.netease,
        MusicPlatform.qq,
        MusicPlatform.kugou,
      ]),
    );
    expect(MusicPlatform.values, contains(MusicPlatform.custom));
  });
}
