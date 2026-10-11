import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/settings_page/online_music_probe_plan_dialog.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_inputs.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_plan.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// **F3-2b 验收**：探测前的**计划披露**与**输入编辑**（Spec §13.2 R7 / §9.4 / §10 决策 5）。
///
/// 钉两件事：
/// 1. 事前说清"测哪些候选 / 用什么输入（含默认值）/ 是否需要凭据"；
/// 2. **取消或非法输入 ⇒ 一个请求都不发**（对话框返回 null / 拒绝关闭）。
void main() {
  ProviderProbeCandidate searchCandidate() => ProviderProbeCandidate(
    id: 'user:search',
    label: '条目自身配置',
    source: ProviderProbeCandidateSource.userConfig,
    capability: OnlineMusicCapability.search,
    binding: OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/search'),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('data.songs'),
      ),
    ),
  );

  ProviderProbeCandidate chartCandidate() => ProviderProbeCandidate(
    id: 'user:chartList',
    label: '条目自身配置',
    source: ProviderProbeCandidateSource.userConfig,
    capability: OnlineMusicCapability.chartList,
    binding: OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/toplist'),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('data.list'),
      ),
    ),
  );

  group('计划模型（纯数据）', () {
    test('列出候选（顺序 = 执行顺序）与输入（含默认值披露）', () {
      final plan = ProviderProbePlan(
        candidates: [searchCandidate(), chartCandidate()],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
      );

      expect(plan.candidateLines, hasLength(2));
      expect(plan.candidateLines.first, contains('搜索'));
      expect(plan.candidateLines.last, contains('榜单'));

      final text = plan.describe();
      expect(text, contains('将按顺序测试 2 个候选'));
      expect(text, contains('最多 $providerProbeMaxRequests 次请求'));
      expect(text, contains('关键词使用默认值'));
      expect(text, contains('凭据：该条目不需要 Key'));
    });

    test('声明需要 Key 但没配 ⇒ 明说"最多未能确认"，不伪造成功', () {
      final plan = ProviderProbePlan(
        candidates: [searchCandidate()],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: true,
        hasCredential: false,
      );

      expect(plan.probesWithoutCredential, isTrue);
      expect(plan.describe(), contains('尚未配置'));
      expect(plan.describe(), contains('未能确认'));
    });

    test('已配置 Key ⇒ 明说会使用它', () {
      final plan = ProviderProbePlan(
        candidates: [searchCandidate()],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: true,
        hasCredential: true,
      );

      expect(plan.probesWithoutCredential, isFalse);
      expect(plan.describe(), contains('使用该条目已配置的 Key'));
    });

    test('被拦下（非法地址 / 无候选）⇒ 明确说"不会发起探测"', () {
      const plan = ProviderProbePlan(
        candidates: [],
        inputs: DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
        blockedReason: '服务地址无效：服务地址无效',
      );
      expect(plan.isBlocked, isTrue);
      expect(plan.describe(), startsWith('不会发起探测：'));
    });

    test('候选很多时只预览前几个（并给出总数）', () {
      final plan = ProviderProbePlan(
        candidates: [
          searchCandidate(),
          searchCandidate(),
          searchCandidate(),
          searchCandidate(),
          searchCandidate(),
        ],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
      );

      final preview = plan.candidateLinesPreview(limit: 3);
      expect(preview, hasLength(4));
      expect(preview.last, contains('共 5 个候选'));
    });
  });

  group('计划对话框（widget）', () {
    Widget host(void Function(BuildContext) onOpen) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => onOpen(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('取消 ⇒ 返回 null（调用方据此**不发请求**）', (tester) async {
      DeclarativeProbeInputs? result;
      var closed = false;
      final plan = ProviderProbePlan(
        candidates: [searchCandidate()],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
      );

      await tester.pumpWidget(
        host((context) async {
          result = await showDialog<DeclarativeProbeInputs>(
            context: context,
            builder: (_) => OnlineMusicProbePlanDialog(plan: plan),
          );
          closed = true;
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('探测前确认'), findsOneWidget);
      expect(find.textContaining('将按顺序测试'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result, isNull);
    });

    testWidgets('留空 ⇒ 返回空输入（= 用默认值，并会在结论里注明）', (tester) async {
      DeclarativeProbeInputs? result;
      final plan = ProviderProbePlan(
        candidates: [searchCandidate()],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
      );

      await tester.pumpWidget(
        host((context) async {
          result = await showDialog<DeclarativeProbeInputs>(
            context: context,
            builder: (_) => OnlineMusicProbePlanDialog(plan: plan),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始探测'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.keyword, isNull);
      expect(result!.limit, isNull);
    });

    testWidgets('填写输入 ⇒ 原样带出', (tester) async {
      DeclarativeProbeInputs? result;
      final plan = ProviderProbePlan(
        candidates: [searchCandidate()],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
      );

      await tester.pumpWidget(
        host((context) async {
          result = await showDialog<DeclarativeProbeInputs>(
            context: context,
            builder: (_) => OnlineMusicProbePlanDialog(plan: plan),
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), '海阔天空');
      await tester.enterText(find.byType(TextField).at(1), '5');
      await tester.tap(find.text('开始探测'));
      await tester.pumpAndSettle();

      expect(result!.keyword, '海阔天空');
      expect(result!.limit, 5);
    });

    testWidgets('★ 非法每页数量 ⇒ 报错且**对话框不关闭**（不发请求）', (tester) async {
      DeclarativeProbeInputs? result;
      var closed = false;
      final plan = ProviderProbePlan(
        candidates: [searchCandidate()],
        inputs: const DeclarativeProbeInputs(),
        requiresCredential: false,
        hasCredential: false,
      );

      await tester.pumpWidget(
        host((context) async {
          result = await showDialog<DeclarativeProbeInputs>(
            context: context,
            builder: (_) => OnlineMusicProbePlanDialog(plan: plan),
          );
          closed = true;
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(1), '0');
      await tester.tap(find.text('开始探测'));
      await tester.pumpAndSettle();

      expect(closed, isFalse);
      expect(result, isNull);
      expect(find.textContaining('必须是正整数'), findsOneWidget);
    });
  });
}
