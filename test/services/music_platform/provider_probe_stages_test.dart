import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_verification.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';

/// **F3-1 验收**：四阶段状态机 + 置信度映射表（Spec §13.4.2）+ 推荐排序（R4）。
///
/// 这一片要钉死两件事，它们都是**真实缺陷**而不是文档洁癖：
/// 1. **"未尝试"不得报成失败** —— 此前 `confidence` 把"一个请求都没发"直接归成 `failed`，
///    等于把"没试过"说成"试过且失败"（与 D-F3-5 的意图自相矛盾）；
/// 2. **结论不得依赖"分数"** —— 此前 `confidence` 用 `score < 2` 判"未能确认"、
///    用 `score > bestScore` 挑推荐候选（"分高者胜"）。F3-3a 起 `score` 字段**已移除**，
///    这里改为断言**契约字段**（阶段 / 置信度 / 排序），并在 `provider_probe_test.dart`
///    的源码守卫里禁止任何"比分"写法回流。
void main() {
  ProviderProbeOutcome outcomeOf({
    ProviderProbeStatus status = ProviderProbeStatus.attempted,
    int? statusCode = 200,
    int mappedItemCount = 3,
    OnlineMusicErrorKind? failureKind,
    String? mappingIncompleteReason,
    bool credentialMissingForAuth = false,
    String? notAttemptedReason,
    ProviderProbeCandidateSource source =
        ProviderProbeCandidateSource.userConfig,
  }) => ProviderProbeOutcome(
    candidateId: 'cand',
    label: '候选',
    source: source,
    capability: OnlineMusicCapability.search,
    status: status,
    statusCode: statusCode,
    mappedItemCount: mappedItemCount,
    failureKind: failureKind,
    mappingIncompleteReason: mappingIncompleteReason,
    credentialMissingForAuth: credentialMissingForAuth,
    notAttemptedReason: notAttemptedReason,
  );

  DeclarativeVerificationStageStatus stageOf(
    ProviderProbeOutcome outcome,
    DeclarativeVerificationStage stage,
  ) => outcome.stageStatus(stage);

  group('映射表逐行（Spec §13.4.2）', () {
    test('① 配置校验失败 ⇒ 配置阶段失败、余下未运行、算失败', () {
      final outcome = outcomeOf(
        status: ProviderProbeStatus.notSent,
        statusCode: null,
      );

      expect(
        stageOf(outcome, DeclarativeVerificationStage.config),
        DeclarativeVerificationStageStatus.failed,
      );
      for (final stage in const [
        DeclarativeVerificationStage.transport,
        DeclarativeVerificationStage.judgement,
        DeclarativeVerificationStage.mapping,
      ]) {
        expect(
          stageOf(outcome, stage),
          DeclarativeVerificationStageStatus.notRun,
          reason: '前序已失败 ⇒ 不得说这些阶段"失败"（那是谎称试过）',
        );
      }
      expect(outcome.firstFailedStage, DeclarativeVerificationStage.config);
      expect(outcome.confidence, DeclarativeVerificationConfidence.failed);
      expect(outcome.countsAsFailure, isTrue);
    });

    test('② 传输失败（没有状态码）⇒ 传输阶段失败，判定/映射未运行', () {
      final outcome = outcomeOf(
        statusCode: null,
        mappedItemCount: 0,
        failureKind: OnlineMusicErrorKind.network,
      );

      expect(
        stageOf(outcome, DeclarativeVerificationStage.config),
        DeclarativeVerificationStageStatus.passed,
      );
      expect(
        stageOf(outcome, DeclarativeVerificationStage.transport),
        DeclarativeVerificationStageStatus.failed,
      );
      expect(
        stageOf(outcome, DeclarativeVerificationStage.judgement),
        DeclarativeVerificationStageStatus.notRun,
      );
      expect(
        stageOf(outcome, DeclarativeVerificationStage.mapping),
        DeclarativeVerificationStageStatus.notRun,
      );
      expect(outcome.firstFailedStage, DeclarativeVerificationStage.transport);
      expect(outcome.confidence, DeclarativeVerificationConfidence.failed);
    });

    test('③ HTTP 到达但判定失败 ⇒ 判定阶段失败，映射未运行（HTTP 200 不覆盖结论）', () {
      final outcome = outcomeOf(
        statusCode: 200,
        mappedItemCount: 0,
        failureKind: OnlineMusicErrorKind.businessFailure,
      );

      expect(
        stageOf(outcome, DeclarativeVerificationStage.transport),
        DeclarativeVerificationStageStatus.passed,
      );
      expect(
        stageOf(outcome, DeclarativeVerificationStage.judgement),
        DeclarativeVerificationStageStatus.failed,
      );
      expect(
        stageOf(outcome, DeclarativeVerificationStage.mapping),
        DeclarativeVerificationStageStatus.notRun,
      );
      expect(outcome.firstFailedStage, DeclarativeVerificationStage.judgement);
      expect(
        outcome.confidence,
        DeclarativeVerificationConfidence.failed,
        reason: '业务判定失败**不是** low/未能确认',
      );
    });

    test('④ 必需映射项缺失 ⇒ 映射阶段失败 + 未能确认（并带证据）', () {
      final outcome = outcomeOf(
        mappedItemCount: 2,
        mappingIncompleteReason: '缺少字段 artists.name',
      );

      expect(
        stageOf(outcome, DeclarativeVerificationStage.mapping),
        DeclarativeVerificationStageStatus.failed,
      );
      expect(outcome.firstFailedStage, DeclarativeVerificationStage.mapping);
      expect(outcome.confidence, DeclarativeVerificationConfidence.unconfirmed);
      expect(
        outcome.mappingIncompleteReason,
        isNotNull,
        reason: 'R3：未能确认必须带"差哪一项"的证据',
      );
    });

    test('⑤ 映射合法但结果为空 ⇒ 四阶段通过、未能确认（不是失败）', () {
      final outcome = outcomeOf(mappedItemCount: 0);

      for (final stage in DeclarativeVerificationStage.values) {
        expect(
          stageOf(outcome, stage),
          DeclarativeVerificationStageStatus.passed,
        );
      }
      expect(outcome.firstFailedStage, isNull);
      expect(
        outcome.confidence,
        DeclarativeVerificationConfidence.unconfirmed,
        reason: '空结果既不能算成功，也不能算失败',
      );
      expect(outcome.countsAsFailure, isFalse);
    });

    test('⑥ 四阶段全通且有必需输出 ⇒ 已验证可用', () {
      final outcome = outcomeOf(mappedItemCount: 25);

      for (final stage in DeclarativeVerificationStage.values) {
        expect(
          stageOf(outcome, stage),
          DeclarativeVerificationStageStatus.passed,
        );
      }
      expect(outcome.firstFailedStage, isNull);
      expect(outcome.confidence, DeclarativeVerificationConfidence.verified);
    });

    test('⑦ ★ 未尝试（预算耗尽）⇒ 四阶段"未运行"、**不是失败**', () {
      final outcome = outcomeOf(
        status: ProviderProbeStatus.notAttempted,
        statusCode: null,
        mappedItemCount: 0,
        notAttemptedReason: '未尝试：请求预算耗尽',
      );

      for (final stage in DeclarativeVerificationStage.values) {
        expect(
          stageOf(outcome, stage),
          DeclarativeVerificationStageStatus.notRun,
        );
      }
      expect(outcome.firstFailedStage, isNull);
      expect(
        outcome.confidence,
        isNot(DeclarativeVerificationConfidence.failed),
        reason: '★ 本片修掉的缺陷：此前"一个请求都没发"被归成 failed',
      );
      expect(outcome.countsAsFailure, isFalse);
      expect(outcome.wasAttempted, isFalse);
    });

    test('⑧ 认证条件未满足 ⇒ 阶段全过但只能"未能确认"', () {
      final outcome = outcomeOf(
        mappedItemCount: 3,
        credentialMissingForAuth: true,
      );

      for (final stage in DeclarativeVerificationStage.values) {
        expect(
          stageOf(outcome, stage),
          DeclarativeVerificationStageStatus.passed,
        );
      }
      expect(outcome.confidence, DeclarativeVerificationConfidence.unconfirmed);
    });
  });

  group('R4：结论只由契约字段决定（`score` 已在 F3-3a 移除）', () {
    test('映射不全 ⇒ 未能确认；四阶段全通 ⇒ 已验证（与任何"分数"无关）', () {
      expect(
        outcomeOf(
          mappedItemCount: 3,
          mappingIncompleteReason: '缺少字段 name',
        ).confidence,
        DeclarativeVerificationConfidence.unconfirmed,
      );
      expect(
        outcomeOf(mappedItemCount: 3).confidence,
        DeclarativeVerificationConfidence.verified,
      );
    });
  });

  group('R4：初稿推荐按可解释排序，不再"分高者胜"', () {
    test('已验证可用 > 映射不全 > 不可用', () {
      expect(probeDraftRank(outcomeOf(mappedItemCount: 3)), 2);
      expect(
        probeDraftRank(
          outcomeOf(mappedItemCount: 3, mappingIncompleteReason: '缺字段'),
        ),
        1,
      );
      expect(probeDraftRank(outcomeOf(mappedItemCount: 0)), 0);
    });

    test('失败 / 未尝试 / 认证未满足 / 空结果都不可作初稿', () {
      expect(
        probeDraftRank(outcomeOf(failureKind: OnlineMusicErrorKind.network)),
        0,
      );
      expect(
        probeDraftRank(
          outcomeOf(
            status: ProviderProbeStatus.notAttempted,
            statusCode: null,
            notAttemptedReason: '未尝试：请求预算耗尽',
          ),
        ),
        0,
      );
      expect(probeDraftRank(outcomeOf(credentialMissingForAuth: true)), 0);
      expect(probeDraftRank(outcomeOf(mappedItemCount: 0)), 0);
    });

    test('★ 排序只看契约字段（映射不全降级为 1，与任何"分数"无关）', () {
      expect(
        probeDraftRank(
          outcomeOf(mappedItemCount: 3, mappingIncompleteReason: '缺字段'),
        ),
        lessThan(probeDraftRank(outcomeOf(mappedItemCount: 3))),
      );
    });
  });

  group('F3-3c 阶段汇总（证明了什么 / 卡在哪一步 / 为什么推荐它）', () {
    test('四种结论分别计数，且**未尝试不计入失败**', () {
      final summary = providerProbeSummaryOf([
        outcomeOf(mappedItemCount: 3), // verified
        outcomeOf(
          mappedItemCount: 2,
          mappingIncompleteReason: '缺字段',
        ), // unconfirmed
        outcomeOf(
          statusCode: 500,
          failureKind: OnlineMusicErrorKind.unavailable,
        ),
        outcomeOf(
          status: ProviderProbeStatus.notAttempted,
          statusCode: null,
          notAttemptedReason: '未尝试：请求预算耗尽',
        ),
      ]);

      expect(summary.verifiedCount, 1);
      expect(summary.unconfirmedCount, 1);
      expect(summary.failedCount, 1);
      expect(summary.notAttemptedCount, 1);
      expect(
        summary.failedStageCounts[DeclarativeVerificationStage.judgement],
        1,
        reason: 'HTTP 500 ⇒ 卡在判定',
      );
    });

    test('汇总文案含计数、卡点与推荐理由（且不写"分数最高"）', () {
      final summary = providerProbeSummaryOf([
        outcomeOf(mappedItemCount: 3),
        outcomeOf(statusCode: null, failureKind: OnlineMusicErrorKind.network),
      ]);

      final text = summary.describe();
      expect(text, startsWith('结论：'));
      expect(text, contains('1 个已验证可用'));
      expect(text, contains('1 个验证失败'));
      expect(text, contains('卡点：传输×1'));
      expect(text, contains('推荐「'));
      expect(text, contains('四阶段全通'));
      expect(text, isNot(contains('分数')));
    });

    test('推荐依据是可解释排序：已验证 > 映射不全（不按出现顺序）', () {
      final summary = providerProbeSummaryOf([
        outcomeOf(mappedItemCount: 2, mappingIncompleteReason: '缺字段'),
        outcomeOf(mappedItemCount: 5),
      ]);

      expect(summary.recommendationReason, contains('四阶段全通'));
      expect(summary.recommendedProvenance, contains('搜索'));
    });

    test('全部未尝试 ⇒ 没有任何"失败"计数', () {
      final summary = providerProbeSummaryOf([
        outcomeOf(
          status: ProviderProbeStatus.notAttempted,
          statusCode: null,
          notAttemptedReason: '未尝试：请求预算耗尽',
        ),
      ]);

      expect(summary.failedCount, 0);
      expect(summary.hasRecommendation, isFalse);
      expect(summary.describe(), contains('1 个未尝试'));
    });

    test('空候选 ⇒ 明说"未发出任何请求"', () {
      expect(providerProbeSummaryOf(const []).describe(), contains('未发出任何请求'));
    });
  });

  group('阶段词表（界面文案的地基）', () {
    test('四个阶段与四种状态都有中文标签', () {
      expect(
        DeclarativeVerificationStage.values
            .map(declarativeVerificationStageLabel)
            .toList(),
        ['配置', '传输', '判定', '映射'],
      );
      expect(
        DeclarativeVerificationStageStatus.values
            .map(declarativeVerificationStageStatusLabel)
            .toList(),
        ['通过', '失败', '未运行', '不适用'],
      );
    });
  });
}
