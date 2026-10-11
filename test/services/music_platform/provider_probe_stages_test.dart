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
/// 2. **`score` 不得决定结论** —— 此前 `confidence` 用 `score < 2` 判"未能确认"、
///    用 `score > bestScore` 挑推荐候选（"分高者胜"）。
void main() {
  ProviderProbeOutcome outcomeOf({
    ProviderProbeStatus status = ProviderProbeStatus.attempted,
    int? statusCode = 200,
    int mappedItemCount = 3,
    OnlineMusicErrorKind? failureKind,
    String? mappingIncompleteReason,
    bool credentialMissingForAuth = false,
    String? notAttemptedReason,
    int score = 0,
    ProviderProbeCandidateSource source =
        ProviderProbeCandidateSource.userConfig,
  }) => ProviderProbeOutcome(
    candidateId: 'cand',
    label: '候选',
    score: score,
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

  group('R4：score 不得决定结论', () {
    test('score=2 但映射不全 ⇒ 仍为"未能确认"（旧实现会判成已验证）', () {
      final outcome = outcomeOf(
        score: 2,
        mappedItemCount: 3,
        mappingIncompleteReason: '缺少字段 name',
      );

      expect(outcome.confidence, DeclarativeVerificationConfidence.unconfirmed);
    });

    test('score=0 但四阶段全通 ⇒ 仍为"已验证可用"（旧实现会判成未能确认）', () {
      final outcome = outcomeOf(score: 0, mappedItemCount: 3);

      expect(outcome.confidence, DeclarativeVerificationConfidence.verified);
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

    test('★ 排序与 score 无关（score 高但映射不全 ⇒ 仍低于已验证）', () {
      final highScoreButIncomplete = outcomeOf(
        score: 2,
        mappedItemCount: 3,
        mappingIncompleteReason: '缺字段',
      );

      expect(
        probeDraftRank(highScoreButIncomplete),
        lessThan(probeDraftRank(outcomeOf(score: 0, mappedItemCount: 3))),
      );
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
