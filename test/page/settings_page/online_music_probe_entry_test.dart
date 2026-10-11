import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/settings_page/online_music_capability_editor.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_inputs.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_plan.dart';
import 'package:pure_music/services/music_platform/declarative/provider_probe.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// **F3-4b 验收（widget 级）**：探测入口**不再按能力隐藏**。
///
/// 直接 pump 能力编辑器对话框（不经设置页的面板导航），因此这条断言只关心里面的事，
/// 不会被面板的滚动/视口问题干扰。
void main() {
  Future<void> pumpEditor(
    WidgetTester tester,
    OnlineMusicCapability capability,
  ) async {
    final definition = OnlineMusicProviderDefinition.custom(
      id: 'selfData',
      baseUrl: 'https://self.invalid',
      requiresCredential: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnlineMusicCapabilityEditorDialog(
            definition: definition,
            capability: capability,
            initialBinding: const OnlineMusicUnsupportedCapabilityBinding(),
            onProbePlan: () async => const ProviderProbePlan(
              candidates: [],
              inputs: DeclarativeProbeInputs(),
              requiresCredential: false,
              hasCredential: false,
            ),
            onProbe: (_) async => const ProviderProbeReport(outcomes: []),
            onTest: (_, _) async => throw UnimplementedError(),
            onIsCredentialConfigured: (_) async => false,
            onSaveCredential: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final capability in const [
    OnlineMusicCapability.chartList, // 可探测（不需要实体 ID）
    OnlineMusicCapability.lyric, // 需要实体 ID：入口也要在，点下后说明原因
    OnlineMusicCapability.stream,
  ]) {
    testWidgets('★ ${capability.name} 也提供「探测该服务」（不隐藏入口）', (tester) async {
      await pumpEditor(tester, capability);

      expect(
        find.widgetWithText(TextButton, '探测该服务'),
        findsOneWidget,
        reason: 'F3-4：${capability.name} 不得隐藏探测入口（旧实现是 if (_isSearch)）',
      );
      // 试跑入口一直都在（需要实体 ID 的能力靠它验证）。
      expect(find.widgetWithText(TextButton, '试跑'), findsOneWidget);
    });
  }
}
