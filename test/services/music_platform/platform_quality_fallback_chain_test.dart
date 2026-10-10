import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

/// F5（P-68）：`platformQualityFallbackChain` 的**直接**测试。
///
/// 契约来源是**实现 + 实现文档**（`online_music_quality_tiers.dart:257-269`），不是函数名的猜测：
/// - `tiers` 为空 ⇒ 返回 `null`，表示调用方保持"引入档位模型之前的行为"（内部档位原样透传）；
/// - 否则按 `internalLevel` 的 `musicQualityRank`（= 在 [MusicQuality.values] 里的下标）排序；
///   起点 = `selectPlatformQuality(期望档)` 命中档（命中不了则"不高于期望的最接近档"）；
///   终点 = 下限（按 `requestValue` **或** `internalLevel` 匹配，且必须**低于**起点），
///   否则为**平台最低档**；返回起点→终点的**内部档位**。
///
/// ⚠️ 内部档位名取自 `MusicQuality`：`standard / exhigh / lossless / hires / jymaster / sky / jyeffect`。
void main() {
  // 网易云风格：请求值即内部档位名。
  const neteaseLike = <PlatformQualityTier>[
    PlatformQualityTier(
      internalLevel: 'standard',
      displayLabel: '标准',
      requestValue: 'standard',
    ),
    PlatformQualityTier(
      internalLevel: 'exhigh',
      displayLabel: '高品',
      requestValue: 'exhigh',
    ),
    PlatformQualityTier(
      internalLevel: 'lossless',
      displayLabel: '无损',
      requestValue: 'lossless',
    ),
  ];

  // QQ 风格：内部档位相同，但**平台请求值**是它自己的 `128/320/flac`。
  const qqLike = <PlatformQualityTier>[
    PlatformQualityTier(
      internalLevel: 'standard',
      displayLabel: '标准',
      requestValue: '128',
    ),
    PlatformQualityTier(
      internalLevel: 'exhigh',
      displayLabel: 'HQ',
      requestValue: '320',
    ),
    PlatformQualityTier(
      internalLevel: 'lossless',
      displayLabel: 'SQ',
      requestValue: 'flac',
    ),
  ];

  test('★ F5-P-68 平台没有档位声明 ⇒ 返回 null（调用方保持既有行为）', () {
    expect(
      platformQualityFallbackChain(
        tiers: const <PlatformQualityTier>[],
        requestedQuality: 'lossless',
      ),
      isNull,
      reason: '调用方（remote_playback_queue_controller.dart:221 之后）据此走内部档位透传',
    );
  });

  test('★ F5-P-68 回退顺序稳定：期望档 → 下限，且重复调用结果一致', () {
    final first = platformQualityFallbackChain(
      tiers: neteaseLike,
      requestedQuality: 'lossless',
      fallbackQuality: 'exhigh',
    );
    expect(first, ['lossless', 'exhigh']);

    expect(
      platformQualityFallbackChain(
        tiers: neteaseLike,
        requestedQuality: 'lossless',
        fallbackQuality: 'exhigh',
      ),
      first,
      reason: '同输入必须给出同一顺序',
    );
    // 下限也可以用**平台请求值**表达（上一首平台实际返回的档位）。
    expect(
      platformQualityFallbackChain(
        tiers: qqLike,
        requestedQuality: 'lossless',
        fallbackQuality: '320',
      ),
      ['lossless', 'exhigh'],
      reason: 'requestValue（320）与 internalLevel（exhigh）都要能当下限',
    );
  });

  test('★ F5-P-68 期望档在该平台不存在 ⇒ 从"不高于期望的最接近档"起步', () {
    const twoTiers = <PlatformQualityTier>[
      PlatformQualityTier(
        internalLevel: 'standard',
        displayLabel: '标准',
        requestValue: '128',
      ),
      PlatformQualityTier(
        internalLevel: 'exhigh',
        displayLabel: 'HQ',
        requestValue: '320',
      ),
    ];

    expect(
      platformQualityFallbackChain(
        tiers: twoTiers,
        requestedQuality: 'lossless',
      ),
      ['exhigh', 'standard'],
      reason: '没有无损 ⇒ 起点是最接近且不高于期望的 exhigh（不是跳到更高，也不是直接到底）',
    );
  });

  test('★ F5-P-68 下限缺失或不低于期望 ⇒ 终点 = 平台最低档', () {
    expect(
      platformQualityFallbackChain(
        tiers: neteaseLike,
        requestedQuality: 'exhigh',
        fallbackQuality: 'not-a-tier',
      ),
      ['exhigh', 'standard'],
      reason: '下限找不到 ⇒ 降到平台最低档',
    );
    expect(
      platformQualityFallbackChain(
        tiers: neteaseLike,
        requestedQuality: 'exhigh',
        fallbackQuality: 'lossless',
      ),
      ['exhigh', 'standard'],
      reason: '下限不低于期望 ⇒ 不作为终点（否则链会包含更高档）',
    );
  });

  test('★ F5-P-68 平台之间不共享档位能力：链只由**本平台**的声明决定', () {
    const onlyStandard = <PlatformQualityTier>[
      PlatformQualityTier(
        internalLevel: 'standard',
        displayLabel: '标准',
        requestValue: '128',
      ),
    ];

    expect(
      platformQualityFallbackChain(
        tiers: onlyStandard,
        requestedQuality: 'lossless',
      ),
      ['standard'],
      reason: '只声明了一档 ⇒ 链里绝不能出现它没声明的档位（不借用别的平台的能力）',
    );
    expect(
      platformQualityFallbackChain(
        tiers: neteaseLike,
        requestedQuality: 'lossless',
      ),
      ['lossless', 'exhigh', 'standard'],
      reason: '同一期望档在声明更全的平台上得到更长的链 ⇒ 两条链互不影响',
    );
  });

  test('★ F5-P-68 未知 internalLevel 的实测行为（rank=-1 ⇒ 排到最前）：只记录、不固化', () {
    // 暴露的实测事实：`musicQualityRank` 用 `MusicQuality.values.indexWhere(...)` ⇒
    // **认不出的档位名返回 -1**，排序时被当成"最低"放到最前。
    // 契约没有规定"未知档位应当如何" ⇒ 本用例只把实测行为记录下来，
    // **不**据此断言成规范（授权要求：契约含糊先记录分歧）。
    const withUnknown = <PlatformQualityTier>[
      PlatformQualityTier(
        internalLevel: 'standard',
        displayLabel: '标准',
        requestValue: 'standard',
      ),
      PlatformQualityTier(
        internalLevel: 'madeUpLevel',
        displayLabel: '未知档位',
        requestValue: 'weird',
      ),
      PlatformQualityTier(
        internalLevel: 'lossless',
        displayLabel: '无损',
        requestValue: 'lossless',
      ),
    ];

    final chain = platformQualityFallbackChain(
      tiers: withUnknown,
      requestedQuality: 'lossless',
    );

    // 实测：排序后 = [madeUpLevel(-1), standard(0), lossless(2)] ⇒ 链 = ['lossless','standard','madeUpLevel']。
    expect(chain, ['lossless', 'standard', 'madeUpLevel']);
    // ⚠️ 分歧记录：未知档位名是否应在**配置校验**阶段被拒绝（而不是静默当成最低档），
    //    属于契约空白 ⇒ 留待裁定；本轮不扩大范围去改校验。
  });
}
