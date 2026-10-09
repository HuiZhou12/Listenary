import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/platform_capability_view.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// 平台能力视图是**诊断信息**：默认收起（不应占据首屏），展开后逐个平台列出能力与
/// 不可用原因；服务未就绪时如实说明，而不是假装没有平台。
void main() {
  final fullCapabilities = OnlineMusicCapabilities(
    searchablePlatforms: const [MusicPlatform.netease],
    resolvablePlatforms: const [MusicPlatform.netease],
    lyricPlatforms: const [MusicPlatform.netease],
    unavailableSearchReasons: const {
      MusicPlatform.qq: '缺少播放解析能力，因此不会参与搜索',
    },
  );

  Future<void> pumpView(
    WidgetTester tester, {
    OnlineMusicCapabilities? capabilities,
    bool initiallyExpanded = false,
    VoidCallback? onConfigure,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlatformCapabilityView(
            capabilities: capabilities,
            initiallyExpanded: initiallyExpanded,
            onConfigure: onConfigure ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认收起：不渲染平台行', (tester) async {
    await pumpView(tester, capabilities: fullCapabilities);

    expect(find.text('平台能力'), findsOneWidget);
    expect(find.text('未配置'), findsNothing);
    expect(find.text('缺少播放解析能力，因此不会参与搜索'), findsNothing);
  });

  testWidgets('展开后列出每个平台的能力与不可用原因', (tester) async {
    await pumpView(
      tester,
      capabilities: fullCapabilities,
      initiallyExpanded: true,
    );

    for (final platform in MusicPlatform.values) {
      expect(find.text(musicPlatformLabel(platform)), findsWidgets);
    }
    // 网易云可用 ⇒ 五项能力标签都在。
    for (final row in platformCapabilityRows) {
      expect(find.text(row.label), findsWidgets, reason: '${row.label} 能力标签');
    }
    // QQ 被门槛挡下 ⇒ 显示原因而不是"未配置"；酷狗完全没配置 ⇒ 显示"未配置"。
    expect(find.text('缺少播放解析能力，因此不会参与搜索'), findsOneWidget);
    expect(find.text('未配置'), findsOneWidget);
  });

  testWidgets('服务未就绪时如实说明，并仍然保留去配置入口', (tester) async {
    var configured = 0;
    await pumpView(
      tester,
      capabilities: null,
      initiallyExpanded: true,
      onConfigure: () => configured++,
    );

    expect(find.textContaining('在线音乐服务尚未就绪'), findsOneWidget);
    // 能力未知 ⇒ 三个平台都显示"未配置"，不假装可用。
    expect(find.text('未配置'), findsNWidgets(MusicPlatform.values.length));

    await tester.tap(find.text('去配置'));
    expect(configured, 1);
  });

  testWidgets('收起状态下点标题即可展开', (tester) async {
    await pumpView(tester, capabilities: fullCapabilities);
    expect(find.text('未配置'), findsNothing);

    await tester.tap(find.text('平台能力'));
    await tester.pumpAndSettle();
    expect(find.text('未配置'), findsOneWidget);
  });
}
