import 'dart:io';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/page/settings_page/online_music_capability_editor.dart';
import 'package:pure_music/page/settings_page/online_music_settings.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';
// P-29：诊断出口（窄接口 + 已本地化/已脱敏的 DTO）。
import 'package:pure_music/services/music_platform/online_music_diagnostics.dart';

const _apiKey = 'chksz_SETTINGS_TEST_ONLY';

void main() {
  Future<void> pumpPanel(
    WidgetTester tester,
    OnlineMusicProviderSettingsController controller, {
    bool active = true,
    OnlineMusicService? service,
  }) async {
    // 视口高度跟着**能力数量**走：2026-10-12 能力增至 14 项后，2600 已经装不下整个面板 ✗
  // ⇒ 断言会因为"惰性列表还没构建到那一段"而找不到控件 ✓。
  tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final onlineMusic =
        service ??
        createOnlineMusicComposition(
          settings: controller.activeSettings,
          portableBuild: true,
        ).service;
    addTearDown(onlineMusic.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<
                OnlineMusicProviderSettingsController
              >.value(value: controller),
              Provider<OnlineMusicService>.value(value: onlineMusic),
            ],
            child: OnlineMusicSettingsPanel(active: active),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 把能力表单滚到指定文案出现为止。
  ///
  /// 表单是 `ListView`（**惰性构建**）⇒ 视口外的控件根本没进 widget 树；
  /// 不先滚动就断言"找不到"，会把"没构建"误当成"不存在"（假绿）。
  /// 用最朴素的 `drag` 循环：不依赖 `scrollUntilVisible` 的 scrollable 解析
  /// （本对话框里有多个可滚动区域）。
  Future<void> scrollCapabilityFormTo(
    WidgetTester tester,
    String label, {
    int maxAttempts = 12,
  }) async {
    expect(
      find.byKey(capabilityFormKey),
      findsOneWidget,
      reason: '能力表单（带 capabilityFormKey 的列表）应当存在',
    );
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (find.text(label).evaluate().isNotEmpty) break;
      await tester.drag(find.byKey(capabilityFormKey), const Offset(0, -320));
      await tester.pumpAndSettle();
    }
    expect(find.text(label), findsOneWidget, reason: '把「$label」滚进视口后应当能找到它');
  }

  /// 滚到某个控件再点它（避免"视口外 = 找不到"的假失败）。
  Future<void> tapInCapabilityForm(WidgetTester tester, String label) async {
    await scrollCapabilityFormTo(tester, label);
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('renders the confirmed default configuration', (tester) async {
    final controller = _controller();

    await pumpPanel(tester, controller);

    expect(find.text('服务提供商'), findsOneWidget);
    expect(find.text(defaultOnlineMusicProviderId), findsWidgets);
    // W8：defaultProvider 已不参与路由，界面上不再有任何「· 默认」标记。
    expect(find.textContaining('· 默认'), findsNothing);
    expect(find.text('修改将在下次启动时生效'), findsNothing);
    expect(find.text('添加提供商'), findsOneWidget);
    // S8：能力分配 / 默认提供商两块被每个平台一张卡取代。
    expect(find.text('能力分配'), findsNothing);
    expect(find.text('默认提供商'), findsNothing);
    expect(find.text('平台'), findsOneWidget);
    for (final platform in builtinMusicPlatforms) {
      expect(find.text(musicPlatformLabel(platform)), findsOneWidget);
    }
    // 每个平台卡内五行能力（search / 歌单详情 / 歌单列表 / lyric / stream）。
    for (final capability in OnlineMusicCapability.values) {
      expect(
        find.text(onlineMusicCapabilityLabel(capability)),
        findsNWidgets(builtinMusicPlatforms.length),
        reason: '${capability.name} 在每个平台卡里都要有一行',
      );
    }
    expect(find.text('播放音质'), findsOneWidget);
    // W7：默认音质一项改为**偏好级别**，并带各平台对应档位的只读映射。
    expect(find.text('偏好级别'), findsOneWidget);
    expect(find.text('默认音质'), findsNothing);
    expect(find.textContaining('各平台对应档位（只读）'), findsOneWidget);
    expect(find.textContaining('网易云：标准 / 高品'), findsOneWidget);
    // 只有一个条目时不提供删除。
    expect(find.byTooltip('删除'), findsNothing);
    controller.dispose();
  });

  testWidgets('warns that changes need a restart', (tester) async {
    final controller = _controller(
      configured: OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'auth': {'kind': 'none'},
          },
        ],
      }),
    );

    await pumpPanel(tester, controller);

    expect(find.text('修改将在下次启动时生效'), findsOneWidget);
    expect(find.text('selfData'), findsWidgets);
    expect(find.textContaining('· 默认'), findsNothing);
    expect(find.textContaining('不需要 API Key'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('adding a provider validates the id and the service address', (
    tester,
  ) async {
    final controller = _controller();
    await pumpPanel(tester, controller);

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 空标识 + 非法地址：内联报错且对话框不关闭。
    await tester.enterText(find.byType(TextField).at(0), '');
    await tester.enterText(find.byType(TextField).at(1), 'ftp://invalid');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请填写标识'), findsOneWidget);
    expect(find.text('服务地址必须以 http:// 或 https:// 开头'), findsOneWidget);

    // 与既有条目重名也要被拒绝。
    await tester.enterText(
      find.byType(TextField).at(0),
      defaultOnlineMusicProviderId,
    );
    await tester.enterText(find.byType(TextField).at(1), 'http://127.0.0.1:9');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('该标识已被占用'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'selfData');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(controller.settings.providers.map((provider) => provider.id), [
      defaultOnlineMusicProviderId,
      'selfData',
    ]);
    expect(find.text('selfData'), findsWidgets);
    expect(find.byTooltip('删除'), findsWidgets);
    controller.dispose();
  });

  testWidgets('deleting a provider falls back to the remaining entry', (
    tester,
  ) async {
    final controller = _controller(
      configured: OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'a',
            'auth': {'kind': 'none'},
          },
          {
            'id': 'b',
            'auth': {'kind': 'none'},
          },
        ],
        'defaultProvider': 'b',
        'capabilities': {'stream': 'b'},
      }),
    );
    await pumpPanel(tester, controller);

    expect(find.byTooltip('删除'), findsNWidgets(2));
    await tester.tap(find.byTooltip('删除').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    expect(controller.settings.providers.single.id, 'a');
    expect(controller.settings.defaultProviderId, 'a');
    expect(
      controller.settings.resolvedProviderIdFor(OnlineMusicCapability.stream),
      'a',
    );
    controller.dispose();
  });

  testWidgets('configures a per-entry API key', (tester) async {
    final credentials = _FakeCredentialAccess();
    final controller = _controller(credentials: credentials);
    await pumpPanel(tester, controller);

    expect(find.textContaining('需要 API Key · 未配置'), findsOneWidget);
    await tester.tap(find.text('配置'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _apiKey);
    // 按钮的可用性由输入内容决定，因此需要一次重建后再点击。
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(credentials.saved, {
      OnlineMusicProviderDefinition.defaultCredentialReference: _apiKey,
    });
    expect(find.textContaining('需要 API Key · 已配置'), findsOneWidget);
    expect(find.byTooltip('清除 API Key'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('editing a provider validates the service address', (
    tester,
  ) async {
    final controller = _controller();
    await pumpPanel(tester, controller);

    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    expect(find.textContaining('编辑提供商'), findsOneWidget);
    // 标识创建后不可改。
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).enabled,
      isFalse,
    );

    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请填写服务地址'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).at(1),
      'http://127.0.0.1:9999',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(
      controller.settings.providers.single.baseUrl,
      'http://127.0.0.1:9999',
    );
    expect(find.textContaining('http://127.0.0.1:9999'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('clears a configured per-entry API key', (tester) async {
    final credentials = _FakeCredentialAccess();
    credentials.saved[OnlineMusicProviderDefinition
            .defaultCredentialReference] =
        _apiKey;
    final controller = _controller(credentials: credentials);
    await pumpPanel(tester, controller);

    expect(find.textContaining('需要 API Key · 已配置'), findsOneWidget);
    await tester.tap(find.byTooltip('清除 API Key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(credentials.saved, isEmpty);
    expect(find.textContaining('需要 API Key · 未配置'), findsOneWidget);
    expect(find.byTooltip('清除 API Key'), findsNothing);
    controller.dispose();
  });

  testWidgets('configures two entries independently', (tester) async {
    final credentials = _FakeCredentialAccess();
    final controller = _controller(credentials: credentials);
    await pumpPanel(tester, controller);

    await controller.addProvider(
      OnlineMusicProviderDefinition.custom(
        id: 'selfData',
        baseUrl: 'https://self.invalid',
        requiresCredential: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('配置'), findsNWidgets(2));
    await tester.tap(find.text('配置').at(1));
    await tester.pumpAndSettle();
    // 对话框标题能看出正在配置哪个条目。
    expect(find.textContaining('配置 selfData 的'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'chksz_SECOND_TEST_ONLY');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(credentials.saved, {
      deriveOnlineMusicCredentialReference('selfData'):
          'chksz_SECOND_TEST_ONLY',
    });
    controller.dispose();
  });

  testWidgets(
    'opens the capability list and fills the ChkSz-compatible template',
    (tester) async {
      final controller = _controller();
      await pumpPanel(tester, controller);

      await tester.tap(find.byTooltip('能力配置'));
      await tester.pumpAndSettle();

      expect(find.textContaining('能力配置 · '), findsOneWidget);
      // 五个能力都要有配置入口（W4：缺少探测模板不是隐藏理由）。
      for (final capability in OnlineMusicCapability.values) {
        expect(
          find.text(onlineMusicCapabilityLabel(capability)),
          findsWidgets,
          reason: '${capability.name} 必须有配置入口',
        );
      }
      expect(find.text('歌单详情'), findsWidgets);
      expect(find.text('歌单列表'), findsWidgets);
      // S7b-3：不再有"第二阶段" —— 全部能力都可以进配置。
      expect(find.text('第二阶段'), findsNothing);
      expect(find.text('配置'), findsWidgets);

      // 能力清单变长 ⇒ 按钮可能在惰性列表里还没被构建 ✗ ⇒ 先滚动查找 ✓。
      await tester.scrollUntilVisible(
        find.text('一键按 ChkSz 兼容方式填充'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('一键按 ChkSz 兼容方式填充'));
      await tester.pumpAndSettle();

      // F1 P-20：现在是**先确认再动手**（旧实现点了就改，无确认无撤销）。
      expect(find.text('按 ChkSz 兼容方式填充？'), findsOneWidget);
      expect(find.textContaining('当前的配置会被覆盖'), findsOneWidget);
      await tester.tap(find.text('填充'));
      await tester.pumpAndSettle();

      final definition = controller.settings.providers.single;
      // 用显式白名单而不是"遍历所有能力再跳过几个"：新增能力时后者会错误地要求它
      // 也被填成内置实现（见 online_music_binding_test 的同款说明）。
      const chkszCapabilities = {
        OnlineMusicCapability.search,
        OnlineMusicCapability.playlist,
        OnlineMusicCapability.lyric,
        OnlineMusicCapability.stream,
      };
      for (final capability in chkszCapabilities) {
        expect(
          definition.bindingFor(capability),
          isA<OnlineMusicBuiltinCapabilityBinding>(),
        );
      }
      // ChkSz 没有歌单列表 / 榜单接口 ⇒ 一键填充不会假装它支持。
      for (final capability in OnlineMusicCapability.values) {
        if (chkszCapabilities.contains(capability)) continue;
        expect(
          definition.bindingFor(capability),
          isA<OnlineMusicUnsupportedCapabilityBinding>(),
          reason: '$capability 没有 ChkSz 接口，不得被填成 builtin',
        );
      }
      controller.dispose();
    },
  );

  testWidgets('the capability editor validates before saving', (tester) async {
    final controller = _controller();
    await pumpPanel(tester, controller);

    await tester.tap(find.byTooltip('能力配置'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(AlertDialog), matching: find.text('配置'))
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('请求'), findsOneWidget);
    expect(find.text('探测该服务'), findsOneWidget);

    // 清空请求路径后保存：结果区给出明确报错，且对话框不关闭。
    await tester.enterText(
      find
          .ancestor(
            of: find.text('请求路径（相对 baseUrl，可用 {trackId}）'),
            matching: find.byType(TextField),
          )
          .first,
      '',
    );
    await tester.pumpAndSettle();
    // F1-d 起表单多了「请求体」区块 ⇒ 表单变长，而它是**惰性 ListView**：
    // 视口外的控件根本没进 widget 树，要断言下面的区块就得先滚过去。
    await scrollCapabilityFormTo(tester, '响应');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请求路径不能为空'), findsOneWidget);
    // 对话框**没有关闭** —— 用"表单还在"判断，而不是用顶部区块标题：
    // 上一步为断言「响应」已经把表单滚下去，视口外的控件（惰性 ListView）不在树里。
    expect(find.byKey(capabilityFormKey), findsOneWidget);
    controller.dispose();
  });

  testWidgets('the capability editor can probe and test', (tester) async {
    final transport = _StubTransport();
    final controller = _controller(probeTransportFactory: (_) => transport);
    await pumpPanel(tester, controller);

    await tester.tap(find.byTooltip('能力配置'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(AlertDialog), matching: find.text('配置'))
          .first,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('试跑'));
    await tester.pumpAndSettle();
    expect(find.textContaining('试跑'), findsWidgets);

    await tester.tap(find.text('探测该服务'));
    await tester.pumpAndSettle();
    // F3-2b 的刻意语义变更：探测**先出计划**（候选 / 输入 / 凭据需求）并由用户确认，
    // 点下按钮即发请求的旧行为已取消 —— 因此这里多一步"开始探测"。
    await tester.tap(find.text('开始探测'));
    await tester.pumpAndSettle();
    expect(transport.probeCalls, greaterThan(0));
    controller.dispose();
  });

  // ---------------------------------------------------------------- UI polish

  Finder searchPathField() => find
      .ancestor(
        of: find.text('请求路径（相对 baseUrl，可用 {trackId}）'),
        matching: find.byType(TextField),
      )
      .first;

  Finder readOnlyResultField() => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.readOnly,
  );

  Widget wrapPanel(
    OnlineMusicProviderSettingsController controller, {
    bool active = true,
  }) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
      body: MultiProvider(
        providers: [
          ChangeNotifierProvider<OnlineMusicProviderSettingsController>.value(
            value: controller,
          ),
          Provider<OnlineMusicService>.value(
            value: createOnlineMusicComposition(
              settings: controller.activeSettings,
              portableBuild: true,
            ).service,
          ),
        ],
        child: OnlineMusicSettingsPanel(active: active),
      ),
    ),
  );

  Future<void> openSearchEditor(WidgetTester tester) async {
    await tester.tap(find.byTooltip('能力配置'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(AlertDialog), matching: find.text('配置'))
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('试跑结果放在限高可滚动的只读区域里，操作栏不受影响', (tester) async {
    final controller = _controller(
      probeTransportFactory: (_) => _StubTransport(),
    );
    await pumpPanel(tester, controller);
    await openSearchEditor(tester);

    await tester.tap(find.text('试跑'));
    await tester.pumpAndSettle();

    // 结果不是铺开的裸文本，而是只读、可展开滚动的文本框。
    final result = readOnlyResultField();
    expect(result, findsOneWidget);
    final field = tester.widget<TextField>(result);
    expect(field.expands, isTrue);
    expect(field.maxLines, isNull);

    // 失败原因确实写进了结果区（可读、可复制）。
    expect(field.controller!.text, isNotEmpty);
    expect(field.controller!.text, contains('必填字段映射'));

    // 结果区高度有界：落在设计区间内，不会随内容增长。
    final bounded = find.ancestor(of: result, matching: find.byType(SizedBox));
    final resultHeight = tester.widget<SizedBox>(bounded.first).height!;
    expect(resultHeight, greaterThanOrEqualTo(72.0));
    expect(resultHeight, lessThanOrEqualTo(168.0));

    // 结果再长也不挤压表单：表单滚动区仍有实际高度。
    expect(
      tester.getSize(find.byKey(capabilityFormKey)).height,
      greaterThan(0.0),
    );

    // 底部操作栏在滚动区之外，始终可用。
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('试跑'), findsOneWidget);
    expect(tester.getSize(find.text('保存')).height, greaterThan(0));

    // 探测会写入逐候选的多行明细：内容更长时结论不变。
    await tester.tap(find.text('探测该服务'));
    await tester.pumpAndSettle();
    // F3-2b：先确认计划，再真正发请求。
    await tester.tap(find.text('开始探测'));
    await tester.pumpAndSettle();
    final longDetail = tester
        .widget<TextField>(readOnlyResultField())
        .controller!
        .text;
    expect(longDetail, contains('·'));
    expect(longDetail.split('\n').length, greaterThan(1));
    expect(
      tester.getSize(find.byKey(capabilityFormKey)).height,
      greaterThan(0.0),
    );
    expect(find.text('保存'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('配置不完整时明确失败，且原因可读', (tester) async {
    final controller = _controller(
      probeTransportFactory: (_) => _StubTransport(),
    );
    await pumpPanel(tester, controller);
    await openSearchEditor(tester);

    await tester.enterText(searchPathField(), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('试跑'));
    await tester.pumpAndSettle();

    expect(find.textContaining('无法试跑'), findsOneWidget);
    expect(find.textContaining('请求路径不能为空'), findsOneWidget);
    // 明确失败而不是静默通过：对话框仍在。
    expect(find.text('保存'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('窄窗口没有横向溢出，且枚举选项全部可达', (tester) async {
    final controller = _controller(
      probeTransportFactory: (_) => _StubTransport(),
    );
    await pumpPanel(tester, controller);
    // 明确指定缩放，避免沿用默认 dpr=3 把 520 物理像素变成 ~173 逻辑像素。
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    await openSearchEditor(tester);
    expect(tester.takeException(), isNull);

    // 表单是惰性列表：窗口窄时下方控件还没构建，需要先滚到可见。
    final formScrollable = find
        .descendant(
          of: find.byKey(capabilityFormKey),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('加查询参数'),
      120.0,
      scrollable: formScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加查询参数'));
    await tester.pumpAndSettle();

    // 取值来源改成菜单：不需要横向滚动就能看到当前值，且 8 个选项一次可及。
    await tester.scrollUntilVisible(
      find.text('取值来源'),
      120.0,
      scrollable: formScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .ancestor(
            of: find.text('取值来源'),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    await tester.pumpAndSettle();
    for (final label in [
      '搜索关键词',
      '每页数量',
      '偏移量',
      '页码',
      '游标',
      '曲目 ID',
      '歌单 ID',
      '音质',
    ]) {
      // 当前取值会在按钮上再显示一次，因此这里只要求「存在且可达」。
      expect(find.text(label), findsWidgets);
    }
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('凭据读取在后台静默完成，不插入任何加载行', (tester) async {
    final credentials = _FakeCredentialAccess()..gate = Completer<void>();
    final controller = _controller(credentials: credentials);
    // 视口高度跟着**能力数量**走：2026-10-12 能力增至 14 项后，2600 已经装不下整个面板 ✗
  // ⇒ 断言会因为"惰性列表还没构建到那一段"而找不到控件 ✓。
  tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrapPanel(controller));
    await tester.pump();

    // 读取尚未完成：页面里既没有进度条，也没有任何"读取中"文案占位。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('读取中'), findsNothing);
    expect(find.textContaining('正在读取'), findsNothing);
    final loadingDy = tester.getTopLeft(find.text('添加提供商')).dy;

    credentials.gate!.complete();
    await tester.pump();
    await tester.pump();

    // 读取完成后页面结构没有任何变化（也就没有位移）；
    // 只有行内副标题从"需要 API Key"补上真实状态。
    expect(tester.getTopLeft(find.text('添加提供商')).dy, loadingDy);
    expect(find.textContaining('需要 API Key · 未配置'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('凭据读取失败时才出现提示与重试', (tester) async {
    final credentials = _FakeCredentialAccess()..failReads = true;
    final controller = _controller(credentials: credentials);

    await pumpPanel(tester, controller);

    expect(find.text('无法读取在线音乐配置'), findsOneWidget);
    expect(find.byTooltip('重试'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('JSON 视图带缩进，能看出层次', (tester) async {
    final controller = _controller(
      probeTransportFactory: (_) => _StubTransport(),
    );
    await pumpPanel(tester, controller);
    await openSearchEditor(tester);

    await tester.tap(find.text('JSON'));
    await tester.pumpAndSettle();

    final jsonField = find.byWidgetPredicate(
      (widget) => widget is TextField && !widget.readOnly,
    );
    final text = tester.widget<TextField>(jsonField).controller!.text;
    expect(text, contains('\n'));
    expect(text, contains('"request"'));
    expect(text, contains('  '));
    controller.dispose();
  });

  // ---------------------------------------------------------------- 平台卡（S8）

  Finder platformCard(MusicPlatform platform) => find
      .ancestor(
        of: find.text(musicPlatformLabel(platform)),
        matching: find.byType(Card),
      )
      .first;

  testWidgets('平台卡：停用平台后显示"已停用"，且最后一个启用平台不能关掉', (tester) async {
    final controller = _controller();
    await pumpPanel(tester, controller);

    expect(find.text('已停用'), findsNothing);
    expect(find.byType(Switch), findsNWidgets(builtinMusicPlatforms.length));

    // 关掉酷狗（卡顺序 = builtinMusicPlatforms 顺序）。
    await tester.tap(find.byType(Switch).at(2));
    await tester.pumpAndSettle();
    expect(controller.settings.isPlatformEnabled(MusicPlatform.kugou), isFalse);
    expect(find.text('已停用'), findsOneWidget);

    // 再关掉 QQ，只剩网易云。
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    expect(controller.settings.isPlatformEnabled(MusicPlatform.qq), isFalse);
    expect(find.text('已停用'), findsNWidgets(2));

    // 空集只能表示"全部启用"，所以最后一个平台不允许被关掉。
    expect(tester.widget<Switch>(find.byType(Switch).at(0)).onChanged, isNull);
    expect(
      builtinMusicPlatforms.where(controller.settings.isPlatformEnabled).length,
      1,
    );
    controller.dispose();
  });

  testWidgets('平台卡：卡内为某能力指定 Provider 会写成该组合的显式候选', (tester) async {
    final controller = _controller(
      configured: OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'neA',
            'contentPlatform': 'netease',
            'auth': {'kind': 'none'},
          },
          {
            'id': 'neB',
            'contentPlatform': 'netease',
            'auth': {'kind': 'none'},
          },
        ],
      }),
    );
    await pumpPanel(tester, controller);

    // 没有显式指定时显示"自动"，并说明自动会用哪个条目。
    expect(find.textContaining('自动：按条目顺序使用 neA'), findsWidgets);

    await tester.tap(
      find
          .descendant(
            of: platformCard(MusicPlatform.netease),
            matching: find.text('neB'),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(
      controller.settings.routing[MusicPlatform.netease]?[OnlineMusicCapability
          .search],
      ['neB'],
    );
    expect(find.text('已指定 neB'), findsOneWidget);

    // 回到「自动」等于清除该组合的显式候选（D17:b 之后必须留这条路）。
    await tester.tap(
      find
          .descendant(
            of: platformCard(MusicPlatform.netease),
            matching: find.text('自动'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(controller.settings.routing[MusicPlatform.netease], isNull);
    controller.dispose();
  });

  testWidgets('平台卡：没有候选的能力显示"未配置"（含 P-19：内置条目只支持 4 项）', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    const unconfigured = '未配置：该平台下没有支持此能力的条目';
    // 默认只有一个 netease 条目：QQ / 酷狗的所有能力都没有候选。
    expect(
      find.descendant(
        of: platformCard(MusicPlatform.kugou),
        matching: find.text(unconfigured),
      ),
      findsNWidgets(OnlineMusicCapability.values.length),
    );
    // ⚠️ 语义变更（F1-c / P-19）：网易云卡以前在**全部 8 项**上都有候选 ——
    // 因为旧条目对任意能力都自称"内置实现"，而运行时只服务 4 项，
    // 于是界面上选得到、调用时静默 `unavailable`。
    // 现在只有**内置实现真正有的能力**才有候选，其余如实显示"未配置"。
    final missingOnNetease = OnlineMusicCapability.values
        .where(
          (capability) => !builtinOnlineMusicCapabilities.contains(capability),
        )
        .length;
    expect(
      missingOnNetease,
      // 2026-10-12：新增「推荐曲目 / 推荐歌单 / 关注的艺人」⇒ 能力 18 个、内置 4 个 ⇒ 缺 14 项 ✓。
      14,
      reason: '内置实现有 4 项、共 18 个能力 ⇒ 网易云卡应缺 14 项',
    );
    expect(
      find.descendant(
        of: platformCard(MusicPlatform.netease),
        matching: find.text(unconfigured),
      ),
      findsNWidgets(missingOnNetease),
      reason: 'P-19：不得给一个运行时必然失败的候选',
    );
    expect(
      find.text(unconfigured),
      findsNWidgets(2 * OnlineMusicCapability.values.length + missingOnNetease),
    );
  });

  testWidgets('平台卡显示运行中能力集合给出的不可用原因（D3b:a）', (tester) async {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'searchOnly',
          'contentPlatform': 'netease',
          'auth': {'kind': 'none'},
          'capabilities': {
            'search': {'kind': 'builtin', 'builtin': 'chksz'},
          },
        },
      ],
    });
    final controller = _controller(configured: settings, active: settings);

    await pumpPanel(tester, controller);

    expect(
      // P-37：运行中的事实**带来源前缀** —— 卡上同时有"运行中"与"配置态"两种状态，
      // 各自标注来源，不再用展示优先级把其中一个吃掉。
      find.text('运行中：缺少播放解析能力，因此不会参与搜索'),
      findsOneWidget,
    );
    controller.dispose();
  });

  testWidgets('编辑条目时"内容来源"创建后只读（D8b:b）', (tester) async {
    final controller = _controller();
    await pumpPanel(tester, controller);

    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();

    expect(find.textContaining('创建后不可修改'), findsWidgets);
    final segmented = tester.widget<SegmentedButton<MusicPlatform>>(
      find.byType(SegmentedButton<MusicPlatform>),
    );
    expect(segmented.onSelectionChanged, isNull);
    controller.dispose();
  });

  // ------------------------------------------------------------------ F0-4

  /// 一个**校验通过**的声明式 search 条目：编辑器的保存路径本身还有别的必填项，
  /// 用空绑定测"保存成功"会被那些必填项挡住，测不到本片的行为。
  OnlineMusicSettings declarativeSearchSettings() =>
      OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'https://self.invalid',
            'auth': {'kind': 'none'},
            'capabilities': {'search': f04SearchBindingJson()},
          },
        ],
      });

  /// 打开某个能力的编辑器（列表里的第一个「配置」= search）。
  Future<void> openCapabilityEditor(WidgetTester tester) async {
    await tester.tap(find.byTooltip('能力配置'));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(AlertDialog), matching: find.text('配置'))
          .first,
    );
    await tester.pumpAndSettle();
  }

  /// 加一行请求头并填名称。
  ///
  /// ⚠️ 表单是**惰性 `ListView`**：F1-d 加了「请求体」区块之后，「加请求头」落到视口之外
  /// （没进 widget 树）⇒ 必须先滚到位再点，否则会报"找不到"。
  Future<void> addHeaderRow(WidgetTester tester, String name) async {
    await scrollCapabilityFormTo(tester, '加请求头');
    await tester.tap(find.text('加请求头'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find
          .ancestor(of: find.text('请求头名'), matching: find.byType(TextField))
          .first,
      name,
    );
    await tester.pumpAndSettle();
  }

  Finder headerField(String label) => find
      .ancestor(of: find.text(label), matching: find.byType(TextField))
      .first;

  /// 对话框内容是可滚动的；目标按钮可能在可视区之外。
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('F0-4 勾选「敏感」后值入口变成凭据引用，并立刻提示需先填写凭据', (tester) async {
    final settings = declarativeSearchSettings();
    final controller = _controller(configured: settings, active: settings);
    await pumpPanel(tester, controller);
    await openCapabilityEditor(tester);
    await addHeaderRow(tester, 'Cookie');

    // 未勾选时：仍是普通的「值」入口，没有任何敏感相关提示。
    expect(find.text('值'), findsOneWidget);
    expect(find.text('敏感'), findsOneWidget);
    expect(find.textContaining('需先填写凭据'), findsNothing);

    await tapVisible(tester, find.text('敏感'));

    // 值入口换成凭据引用 —— 明文输入框不再存在。
    expect(find.text('凭据引用（槽位名）'), findsOneWidget);
    expect(find.text('值'), findsNothing);
    // 勾选后**立刻**提示需要先填写凭据（而不是等保存才说）。
    expect(find.textContaining('凭据未配置：需先填写凭据'), findsOneWidget);
    expect(find.textContaining('值保存在系统凭据管理器'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final definition = controller.settings.providers.single;
    final binding =
        definition.bindingFor(OnlineMusicCapability.search)
            as OnlineMusicDeclarativeCapabilityBinding;
    final header = binding.request.headers.single;
    expect(header.name, 'Cookie');
    expect(header.sensitive, isTrue, reason: '勾选必须落进配置');
    expect(header.value, isEmpty, reason: '敏感头绝不写明文值');
    expect(
      header.credentialReference,
      onlineMusicHeaderSlotName(
        providerId: definition.id,
        capability: OnlineMusicCapability.search,
        headerName: 'Cookie',
      ),
      reason: '默认派生稳定槽位名',
    );
    controller.dispose();
  });

  testWidgets('F0-4 填写凭据只写进安全槽位，配置与 JSON 视图都不留秘密', (tester) async {
    const secret = 'SECRET_COOKIE_UI_TEST_ONLY';
    final settings = declarativeSearchSettings();
    final credentials = _FakeCredentialAccess();
    final controller = _controller(
      configured: settings,
      active: settings,
      credentials: credentials,
    );
    await pumpPanel(tester, controller);
    await openCapabilityEditor(tester);
    await addHeaderRow(tester, 'Cookie');
    await tapVisible(tester, find.text('敏感'));

    await tapVisible(tester, find.text('填写凭据'));

    // 输入框是遮蔽的（界面不得明文回显秘密）。
    final secretField = tester.widget<TextField>(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .last,
    );
    expect(secretField.obscureText, isTrue);

    await tester.enterText(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .last,
      secret,
    );
    await tester.pumpAndSettle();
    // 只点凭据对话框里的「保存」（编辑器自己也有一个同名按钮）。
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('保存')),
    );
    await tester.pumpAndSettle();

    final definition = controller.settings.providers.single;
    final slot = onlineMusicHeaderSlotName(
      providerId: definition.id,
      capability: OnlineMusicCapability.search,
      headerName: 'Cookie',
    );
    // 秘密进了槽位……
    expect(credentials.saved[slot], secret);
    // ……状态随之变成已配置。
    expect(find.textContaining('凭据已配置'), findsOneWidget);
    // 界面上没有任何地方明文回显它。
    expect(find.text(secret), findsNothing);
    expect(find.textContaining(secret), findsNothing);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 配置里**只有引用**：序列化结果里不得出现秘密。
    final binding =
        controller.settings.providers.single.bindingFor(
              OnlineMusicCapability.search,
            )
            as OnlineMusicDeclarativeCapabilityBinding;
    expect(binding.request.headers.single.credentialReference, slot);
    expect(binding.request.headers.single.value, isEmpty);
    final serialized = jsonEncode(controller.settings.toJson());
    expect(serialized, isNot(contains(secret)));
    expect(serialized, contains(slot));
    controller.dispose();
  });

  testWidgets('F0-4 敏感 + 明文 ⇒ 保存被拒，且明文值不被静默丢弃', (tester) async {
    const plaintext = 'PLAINTEXT_COOKIE_UI_TEST_ONLY';
    final settings = declarativeSearchSettings();
    final credentials = _FakeCredentialAccess();
    final controller = _controller(
      configured: settings,
      active: settings,
      credentials: credentials,
    );
    await pumpPanel(tester, controller);
    await openCapabilityEditor(tester);
    await addHeaderRow(tester, 'Cookie');

    await tester.enterText(headerField('值'), plaintext);
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('敏感'));

    // 值**没有被悄悄清掉**：界面明确说它还在、且保存会被拒。
    expect(find.textContaining('这一行仍有明文值'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 保存被拦下（对话框不关闭），并给出精确原因。
    expect(find.textContaining('明文值必须清空'), findsOneWidget);
    expect(find.text('凭据引用（槽位名）'), findsOneWidget);
    // 配置没有被改写，也没有任何凭据被写进槽位。
    final binding =
        controller.settings.providers.single.bindingFor(
              OnlineMusicCapability.search,
            )
            as OnlineMusicDeclarativeCapabilityBinding;
    expect(binding.request.headers, isEmpty, reason: '保存失败就不该改动配置');
    expect(credentials.saved, isEmpty);
    controller.dispose();
  });

  // ------------------------------------------------------------------ F0-5

  /// 带明文敏感头 + 一个"值可疑但名字未命中"的条目。
  OnlineMusicSettings migrationSettings() => OnlineMusicSettings.fromJson({
    'providers': [
      {
        'id': 'selfData',
        'baseUrl': 'https://self.invalid',
        'auth': {'kind': 'none'},
        'capabilities': {
          'search': Map<String, Object?>.from(f04SearchBindingJson())
            ..['request'] = {
              ...(f04SearchBindingJson()['request']! as Map<String, Object?>),
              'headers': const [
                {
                  'name': 'Cookie',
                  'value': 'session=FAKE_COOKIE_UI_MIGRATION_TEST_ONLY',
                },
                {'name': 'X-Weird', 'value': 'Ab3Kd9Zx7Qm2Pl5R'},
              ],
            },
        },
      },
    ],
  });

  testWidgets('F0-5 迁移入口：先只给识别结果，确认后才动手（可疑项不迁移）', (tester) async {
    const cookiePlaintext = 'session=FAKE_COOKIE_UI_MIGRATION_TEST_ONLY';
    final settings = migrationSettings();
    final credentials = _FakeCredentialAccess();
    final store = _MemorySettingsStore(settings);
    final controller = OnlineMusicProviderSettingsController(
      activeSettings: settings,
      store: store,
      fallbackCredentials: credentials,
      credentialReader: credentials,
      // ⚠️ `portableBuild` 的编译期默认值是 **true**（便携版是默认产物形态），
      // 所以想覆盖"真的迁移"这条路径必须显式声明这是安装版构建。
      isPortableBuild: false,
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();

    // 第一步：**只识别**。名字命中的列出槽位，形态可疑的列成"待你裁定"。
    expect(find.text('敏感请求头：识别结果'), findsOneWidget);
    expect(find.textContaining('Cookie'), findsWidgets);
    expect(find.textContaining('待你裁定'), findsWidgets);
    expect(find.textContaining('X-Weird'), findsWidgets);
    // 界面里不得出现任何值。
    expect(find.textContaining(cookiePlaintext), findsNothing);
    // 还没动手：没有写凭据、没有改配置。
    expect(credentials.saved, isEmpty);
    expect(store.writes, 0);

    await tester.tap(find.text('开始迁移'));
    await tester.pumpAndSettle();

    // 第二步：执行并报告结果。
    expect(find.text('迁移完成'), findsOneWidget);
    expect(credentials.saved.keys.single, contains('cookie'));
    expect(credentials.saved.values.single, cookiePlaintext);
    final serialized = jsonEncode(store.value.toJson());
    expect(serialized, isNot(contains(cookiePlaintext)));
    // 可疑项**没有被迁移**：原样保留（等用户自己裁定）。
    expect(serialized, contains('Ab3Kd9Zx7Qm2Pl5R'));
  });

  testWidgets('F0-5 便携版：只提示不可迁移，不给"开始迁移"按钮', (tester) async {
    final settings = migrationSettings();
    final credentials = _FakeCredentialAccess();
    final store = _MemorySettingsStore(settings);
    final controller = OnlineMusicProviderSettingsController(
      activeSettings: settings,
      store: store,
      fallbackCredentials: credentials,
      credentialReader: credentials,
      isPortableBuild: true,
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();

    expect(find.textContaining('便携版无法安全持久保存秘密'), findsOneWidget);
    expect(find.textContaining('明文会原样保留'), findsOneWidget);
    expect(find.text('开始迁移'), findsNothing);
    expect(find.text('知道了'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    expect(credentials.saved, isEmpty);
    expect(store.writes, 0);
  });

  testWidgets('F0-6 迁移失败时标题不得说"没有需要迁移的内容"', (tester) async {
    final settings = migrationSettings();
    final credentials = _FakeCredentialAccess()..failWrites = true;
    final store = _MemorySettingsStore(settings);
    final controller = OnlineMusicProviderSettingsController(
      activeSettings: settings,
      store: store,
      fallbackCredentials: credentials,
      credentialReader: credentials,
      isPortableBuild: false,
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始迁移'));
    await tester.pumpAndSettle();

    // 全部条目写失败、回滚成功后 stopped 仍是 false ⇒ 标题**必须**看失败，
    // 否则会出现"标题说没东西要迁移、下面每行都写着失败"的自相矛盾（假阳性成功）。
    expect(find.text('迁移未完成'), findsOneWidget);
    expect(find.text('没有需要迁移的内容'), findsNothing);
    expect(find.textContaining('失败：凭据写入失败'), findsOneWidget);
    expect(store.writes, 0);
    expect(credentials.saved, isEmpty);
  });

  testWidgets('F0-6 预览的"将迁移 N 项"只数真的会被搬的项', (tester) async {
    // 一项是真的明文（会被搬），一项已经带引用（本次不动）。
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'none'},
          'capabilities': {
            'search': Map<String, Object?>.from(f04SearchBindingJson())
              ..['request'] = {
                ...(f04SearchBindingJson()['request']! as Map<String, Object?>),
                'headers': const [
                  {
                    'name': 'Cookie',
                    'value': 'session=FAKE_COOKIE_UI_MIGRATION_TEST_ONLY',
                  },
                  {
                    'name': 'Authorization',
                    'value': '',
                    'sensitive': true,
                    'reference': 'selfData/search/authorization',
                  },
                ],
              },
          },
        },
      ],
    });
    final credentials = _FakeCredentialAccess();
    final store = _MemorySettingsStore(settings);
    final controller = OnlineMusicProviderSettingsController(
      activeSettings: settings,
      store: store,
      fallbackCredentials: credentials,
      credentialReader: credentials,
      isPortableBuild: false,
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('检查'));
    await tester.pumpAndSettle();

    expect(find.text('将迁移（1 项）：'), findsOneWidget);
    expect(find.textContaining('已用安全凭据引用（1 项，本次不动）'), findsOneWidget);

    await tester.tap(find.text('开始迁移'));
    await tester.pumpAndSettle();

    // 说的 1 项就是真的搬了 1 项：不会先说 N 项、结果报"无需迁移"。
    expect(find.text('迁移完成'), findsOneWidget);
    expect(credentials.saved.keys.single, contains('cookie'));
  });

  // ------------------------------------------------------------------ F1-e（P-23）

  group('F1 P-23 新增参数行的默认取值来源（按能力，穷举）', () {
    test('★ 只有"关键词类"能力的默认是「搜索关键词」（曲目搜索 / 专辑搜索）', () {
      final defaults = {
        for (final capability in OnlineMusicCapability.values)
          capability: defaultInputSourceFor(capability),
      };

      // 每个能力都有明确默认，且都在合法值域内。
      expect(defaults, hasLength(OnlineMusicCapability.values.length));
      expect(
        defaults.values.every(OnlineMusicInputSource.values.contains),
        isTrue,
      );
      // 逐条点名（漏改能力会编译失败，这里钉住语义）。
      expect(
        defaults[OnlineMusicCapability.search],
        OnlineMusicInputSource.keyword,
      );
      expect(
        defaults[OnlineMusicCapability.playlist],
        OnlineMusicInputSource.playlistId,
      );
      expect(
        defaults[OnlineMusicCapability.lyric],
        OnlineMusicInputSource.trackId,
      );
      expect(
        defaults[OnlineMusicCapability.stream],
        OnlineMusicInputSource.trackId,
      );
      for (final capability in const [
        OnlineMusicCapability.playlistCollection,
        OnlineMusicCapability.playlistCategories,
        OnlineMusicCapability.chartList,
        OnlineMusicCapability.newSongs,
        // 2026-10-12 新增：新专辑同样是"数组类 ⇒ limit" ✓。
        OnlineMusicCapability.newAlbums,
      ]) {
        expect(defaults[capability], OnlineMusicInputSource.limit);
      }
      // **缺陷本体**：修复前"一律 keyword"，于是歌单详情里新增的参数会把
      // 搜索关键词当成歌单 ID 发出去。现在 keyword 只属于**关键词类**能力：
      // 曲目搜索 ✓ 与专辑搜索 ✓（2026-10-12 新增的后者同样是关键词能力 ✓）。
      expect(
        defaults.entries
            .where((entry) => entry.value == OnlineMusicInputSource.keyword)
            .map((entry) => entry.key)
            .toList(),
        [OnlineMusicCapability.search, OnlineMusicCapability.searchAlbums, OnlineMusicCapability.searchArtists],
      );
    });
  });

  /// 打开**指定能力**的编辑器（能力列表按枚举顺序渲染，索引即枚举下标）。
  Future<void> openCapabilityEditorFor(
    WidgetTester tester,
    OnlineMusicCapability capability,
  ) async {
    await tester.tap(find.byTooltip('能力配置'));
    await tester.pumpAndSettle();
    final buttons = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('配置'),
    );
    expect(
      buttons,
      findsNWidgets(OnlineMusicCapability.values.length),
      reason: '能力列表应当每个能力一行（索引才能对应枚举下标）',
    );
    await tester.tap(
      buttons.at(OnlineMusicCapability.values.indexOf(capability)),
    );
    await tester.pumpAndSettle();
    // 确认真的进了编辑器（标题形如「播放解析 · chksz」）：
    // 否则后面"找不到某个控件"的断言会指向错误的原因。
    expect(
      find.textContaining('${onlineMusicCapabilityLabel(capability)} · '),
      findsOneWidget,
      reason: '${capability.name} 的能力编辑器没有打开',
    );
  }

  testWidgets('F1 P-23 播放解析里「加查询参数」不再默认「搜索关键词」', (tester) async {
    final controller = _controller();
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.stream);

    await tapInCapabilityForm(tester, '加查询参数');

    // 决定性断言：修复前新行的取值来源就是「搜索关键词」。
    expect(find.text('搜索关键词'), findsNothing);
    // 该能力的默认是曲目 ID（字段映射里也有一个同名标签，故用 findsWidgets）。
    expect(find.text('曲目 ID'), findsWidgets);
    controller.dispose();
  });

  testWidgets('F1 P-23 搜索里「加查询参数」仍然默认「搜索关键词」', (tester) async {
    final controller = _controller();
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

    await tapInCapabilityForm(tester, '加查询参数');

    expect(find.text('搜索关键词'), findsOneWidget);
    controller.dispose();
  });

  // ------------------------------------------------------------------ F1-a（P-01 / P-02）

  test('★ F1 P-01 模型要求「列表路径」的能力，表单就必须能填它', () {
    // 这条是 P-01 的**跨层断言**：以前表单把两个路径写成互斥二选一，
    // 于是"校验要求列表路径"的四个能力**根本没有入口写它** ⇒ 存不下也试不了。
    // 用 `validationIssues` 反推"模型要什么"，因此**新增能力也不会漏**。
    for (final capability in OnlineMusicCapability.values) {
      final fields = responsePathFieldsFor(capability);
      final issues = const OnlineMusicResponseSpec().validationIssues(
        capability,
      );
      final requiresListPath = issues.any(
        (issue) => issue.contains('必须配置列表路径'),
      );
      // **单向蕴含**：模型要求的，表单必须给入口（反向不必 —— 表单可以多给，
      // 例如歌单详情模型不"要求"列表路径，但界面必须给，否则曲目恒空）。
      if (requiresListPath) {
        expect(
          fields.listPath,
          isTrue,
          reason: '${capability.name}：模型要求列表路径，表单就必须有这个入口',
        );
      }
      expect(
        fields.listPath || fields.fieldsRootPath,
        isTrue,
        reason: '${capability.name} 至少要有一个响应路径入口',
      );
    }
    // 逐个点名（新增能力会走到上面那条蕴含断言；这里钉住当前 8 项的语义）。
    {
      const listPathOnly = (listPath: true, fieldsRootPath: false);
      const fieldsRootOnly = (listPath: false, fieldsRootPath: true);
      const both = (listPath: true, fieldsRootPath: true);
      expect(responsePathFieldsFor(OnlineMusicCapability.search), listPathOnly);
      // 歌单详情两个都要：元数据在字段根路径、曲目数组在列表路径（真实配方形状）。
      expect(responsePathFieldsFor(OnlineMusicCapability.playlist), both);
      for (final capability in const [
        OnlineMusicCapability.playlistCollection,
        OnlineMusicCapability.playlistCategories,
        OnlineMusicCapability.chartList,
        OnlineMusicCapability.newSongs,
      ]) {
        expect(
          responsePathFieldsFor(capability),
          listPathOnly,
          reason: '${capability.name} 拿到的是一个数组，只要列表路径',
        );
      }
      for (final capability in const [
        OnlineMusicCapability.lyric,
        OnlineMusicCapability.stream,
      ]) {
        expect(responsePathFieldsFor(capability), fieldsRootOnly);
      }
    }
  });

  testWidgets('F1 P-01 歌单列表：只有「列表路径」入口（旧表单只有字段根路径）', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(
      tester,
      OnlineMusicCapability.playlistCollection,
    );

    // 表单是惰性 ListView：先滚到路径区（总数路径）把相邻行建出来，
    // 否则"找不到"可能只是因为没构建 ⇒ 否定断言会变成假绿。
    // ⚠️ 惰性列表：说明在「总数路径」下方、滚动锚点用**精确匹配** ⇒ 滚到它下方的区块标题，
    // 保证说明已经进入 widget 树（是否可见不影响 contains 断言）。
    await scrollCapabilityFormTo(tester, '字段映射', maxAttempts: 40);
    expect(find.text('列表路径（如 data.songs）'), findsOneWidget);
    expect(find.text('字段根路径（如 data）'), findsNothing);
  });

  testWidgets('F1 P-01 歌单详情：两个路径入口都在，并说明各自放什么', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.playlist);

    // ⚠️ 惰性列表：说明在「总数路径」下方、滚动锚点用**精确匹配** ⇒ 滚到它下方的区块标题，
    // 保证说明已经进入 widget 树（是否可见不影响 contains 断言）。
    await scrollCapabilityFormTo(tester, '字段映射', maxAttempts: 40);
    expect(find.text('列表路径（如 data.songs）'), findsOneWidget);
    expect(find.text('字段根路径（如 data）'), findsOneWidget);
    expect(find.textContaining('元数据在「字段根路径」'), findsOneWidget);
  });

  // 8 个能力逐个走一遍「打开编辑器 → 保存 → 配置往返不丢字段」。
  // 这就是 P-01 的正面复现：修复前，非 search 能力按保存会被
  // 「必须配置列表路径」拦下（歌单详情则静默丢掉列表路径）。
  for (final capability in OnlineMusicCapability.values) {
    testWidgets('F1 P-01 ${capability.name}：配置可保存且路径不丢', (tester) async {
      final binding = validBindingFor(capability);
      expect(
        binding.validationIssues(capability),
        isEmpty,
        reason: '夹具本身必须是合法配置（否则这条测试会在错误的层面失败）',
      );
      final settings = settingsWithBinding(capability, binding);
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, capability);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('无法保存'),
        findsNothing,
        reason: '${capability.name} 的合法配置不该被校验拦下',
      );
      final saved =
          controller.settings.providers.single.bindingFor(capability)
              as OnlineMusicDeclarativeCapabilityBinding;
      expect(
        saved.response.listPath,
        binding.response.listPath,
        reason: '${capability.name} 的列表路径不得在保存时丢失',
      );
      expect(
        saved.response.fieldsRootPath,
        binding.response.fieldsRootPath,
        reason: '${capability.name} 的字段根路径不得在保存时丢失',
      );
      expect(saved, binding, reason: '整份绑定往返不变（编辑既有配置不丢字段）');
    });
  }

  testWidgets('F1 P-01 歌单详情：曲目数组路径写得住、试跑真的取到曲目', (tester) async {
    const trackCount = 3;
    final binding = validBindingFor(OnlineMusicCapability.playlist);
    final settings = settingsWithBinding(
      OnlineMusicCapability.playlist,
      binding,
    );
    final transport = _StubTransport({
      'playlist': {
        'id': 42,
        'name': '测试歌单',
        'tracks': [
          for (var i = 0; i < trackCount; i++) {'id': 100 + i, 'name': '曲目 $i'},
        ],
      },
    });
    final controller = OnlineMusicProviderSettingsController(
      activeSettings: settings,
      store: _MemorySettingsStore(settings),
      fallbackCredentials: _FakeCredentialAccess(),
      probeTransportFactory: (_) => transport,
    );
    addTearDown(controller.dispose);

    final result = await controller.testCapability(
      settings.providers.single,
      OnlineMusicCapability.playlist,
      trackId: '42',
    );

    expect(result.ok, isTrue);
    expect(
      result.mappedSummary,
      contains('$trackCount 首曲目'),
      reason: '修复前曲目恒空（列表路径写不出去）',
    );
  });

  testWidgets('F1 P-01 歌单详情缺「列表路径」时试跑必须失败，不得报成功', (tester) async {
    // 元数据配好了、但没配曲目数组路径 ⇒ 这是**配置缺项**，不是"这个歌单是空的"。
    final binding = OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/playlist/detail'),
      response: OnlineMusicResponseSpec(
        fieldsRootPath: JsonPath.tryParse('playlist'),
        fields: {
          OnlineMusicDomainField.playlistId: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('id')!],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('name')!],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      ),
    );
    expect(binding.validationIssues(OnlineMusicCapability.playlist), isEmpty);
    final settings = settingsWithBinding(
      OnlineMusicCapability.playlist,
      binding,
    );
    final transport = _StubTransport({
      'playlist': {'id': 42, 'name': '测试歌单'},
    });
    final controller = OnlineMusicProviderSettingsController(
      activeSettings: settings,
      store: _MemorySettingsStore(settings),
      fallbackCredentials: _FakeCredentialAccess(),
      probeTransportFactory: (_) => transport,
    );
    addTearDown(controller.dispose);

    final result = await controller.testCapability(
      settings.providers.single,
      OnlineMusicCapability.playlist,
      trackId: '42',
    );

    expect(result.ok, isFalse, reason: '曲目数组路径没配就不该报"试跑成功"');
    expect(result.failureReason, contains('列表路径'));
  });

  // ------------------------------------------------------------------ F1-b（P-20）

  Future<void> openFillConfirm(WidgetTester tester) async {
    await tester.tap(find.byTooltip('能力配置'));
    await tester.pumpAndSettle();
    // 能力清单会随能力数量增长（2026-10-12 起 13 项）⇒ 按钮在**惰性列表**里可能还没被构建 ✗
    // ⇒ 必须**普通滚动查找**（`ensureVisible` 对"没构建"的控件无效 ✓；
    //    `scrollCapabilityFormTo` 是"能力编辑器表单"专用 ✓，这里没有那个 key ✗）。
    await tester.scrollUntilVisible(
      find.text('一键按 ChkSz 兼容方式填充'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('一键按 ChkSz 兼容方式填充'));
    await tester.pumpAndSettle();
    expect(find.text('按 ChkSz 兼容方式填充？'), findsOneWidget);
  }

  testWidgets('★ F1 P-20 确认框里点取消 ⇒ 一个字节都不改', (tester) async {
    final playlistCollection = validBindingFor(
      OnlineMusicCapability.playlistCollection,
    );
    final settings = settingsWithBinding(
      OnlineMusicCapability.playlistCollection,
      playlistCollection,
    );
    final controller = _controller(configured: settings, active: settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openFillConfirm(tester);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    final definition = controller.settings.providers.single;
    expect(
      definition.bindingFor(OnlineMusicCapability.playlistCollection),
      playlistCollection,
      reason: '取消后既不能被覆盖、也不能被丢掉',
    );
    expect(
      definition.bindingFor(OnlineMusicCapability.search),
      isA<OnlineMusicUnsupportedCapabilityBinding>(),
      reason: '取消后不该发生任何填充',
    );
  });

  testWidgets('★ F1 P-20 确认框说明"哪些保持不变"，确认后真正的合并生效', (tester) async {
    final playlistCollection = validBindingFor(
      OnlineMusicCapability.playlistCollection,
    );
    final settings = settingsWithBinding(
      OnlineMusicCapability.playlistCollection,
      playlistCollection,
    );
    final controller = _controller(configured: settings, active: settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openFillConfirm(tester);

    // 确认文案必须逐项说清：哪几项会被覆盖 / 哪几项保持不变。
    expect(find.textContaining('当前的配置会被覆盖'), findsOneWidget);
    expect(find.textContaining('其它已配置的能力（歌单列表）保持不变'), findsOneWidget);

    await tester.tap(find.text('填充'));
    await tester.pumpAndSettle();

    final definition = controller.settings.providers.single;
    for (final capability in const [
      OnlineMusicCapability.search,
      OnlineMusicCapability.playlist,
      OnlineMusicCapability.lyric,
      OnlineMusicCapability.stream,
    ]) {
      expect(
        definition.bindingFor(capability),
        isA<OnlineMusicBuiltinCapabilityBinding>(),
      );
    }
    expect(
      definition.bindingFor(OnlineMusicCapability.playlistCollection),
      playlistCollection,
      reason: 'P-20：已配好的歌单列表不得被一键填充丢掉',
    );
  });

  // ------------------------------------------------------------------ F1-d（P-21）

  /// 打开编辑器 → 直接保存 → 返回落盘后的绑定（用于"往返不丢东西"的断言）。
  Future<OnlineMusicDeclarativeCapabilityBinding> saveRoundTrip(
    WidgetTester tester,
    OnlineMusicDeclarativeCapabilityBinding fixture, {
    OnlineMusicCapability capability = OnlineMusicCapability.search,
  }) async {
    final settings = settingsWithBinding(capability, fixture);
    final controller = _controller(configured: settings, active: settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, capability);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法保存'), findsNothing);
    return controller.settings.providers.single.bindingFor(capability)
        as OnlineMusicDeclarativeCapabilityBinding;
  }

  group('F1 P-21 参数行可编辑 required/default，且 default 不丢类型', () {
    Future<OnlineMusicDeclarativeCapabilityBinding> savedAfterOpen(
      WidgetTester tester,
      OnlineMusicDeclarativeCapabilityBinding fixture, {
      OnlineMusicCapability capability = OnlineMusicCapability.search,
    }) => saveRoundTrip(tester, fixture, capability: capability);

    testWidgets('★ 默认值的**类型**在保存后仍然正确', (tester) async {
      // 以前统一按字符串回写 ⇒ `default: 30` 保存一次变成 `"30"`（P-21）。
      for (final entry in const <String, Object>{
        'int': 30,
        'bool': false,
        'string': 'abc',
      }.entries) {
        final saved = await savedAfterOpen(
          tester,
          bindingWithParamExtras(defaultValue: entry.value),
        );
        expect(
          saved.request.query.single.defaultValue,
          entry.value,
          reason: '${entry.key} 类型的默认值不得被改成字符串',
        );
      }
    });

    testWidgets('★ 「必填」勾选框真的写进配置', (tester) async {
      final fixture = bindingWithParamExtras(required: false, defaultValue: 30);
      final settings = settingsWithBinding(
        OnlineMusicCapability.search,
        fixture,
      );
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

      expect(fixture.request.query.single.required, isFalse, reason: '夹具起点');
      await scrollCapabilityFormTo(tester, '必填');
      final requiredRow = find
          .ancestor(of: find.text('必填'), matching: find.byType(Row))
          .first;
      await tester.tap(
        find.descendant(of: requiredRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final saved =
          controller.settings.providers.single.bindingFor(
                OnlineMusicCapability.search,
              )
              as OnlineMusicDeclarativeCapabilityBinding;
      expect(saved.request.query.single.required, isTrue, reason: '勾了要写进去');
      expect(saved.request.query.single.defaultValue, 30, reason: '顺带不丢类型');
    });
  });

  group('★ F4-S1 参数行支持「固定值」（P-08 / D1:A）', () {
    testWidgets('★ 勾「固定值」填值并保存 ⇒ 配置里只有 value、没有 source', (tester) async {
      final fixture = bindingWithParamExtras(required: true, defaultValue: 30);
      final settings = settingsWithBinding(
        OnlineMusicCapability.search,
        fixture,
      );
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

      expect(
        fixture.request.query.single.source,
        isNotNull,
        reason: '夹具起点是"来源"模式',
      );
      await scrollCapabilityFormTo(tester, '固定值');
      final constantRow = find
          .ancestor(of: find.text('固定值'), matching: find.byType(Row))
          .first;
      await tester.tap(
        find.descendant(of: constantRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();

      final valueField = find.ancestor(
        of: find.text('固定值（写死，例如 30）'),
        matching: find.byType(TextField),
      );
      expect(valueField, findsOneWidget, reason: '切到固定值后必须出现固定值输入框');
      await tester.enterText(valueField, '30');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final saved =
          controller.settings.providers.single.bindingFor(
                OnlineMusicCapability.search,
              )
              as OnlineMusicDeclarativeCapabilityBinding;
      final param = saved.request.query.single;
      expect(param.value, '30', reason: '固定值要写进配置');
      expect(param.source, isNull, reason: '两者互斥：固定值模式下不得再写来源（不静默取其一）');
      expect(
        param.toJson().containsKey('source'),
        isFalse,
        reason: '写盘形状里也不该再出现 source',
      );
    });

    test('源码守卫：固定值模式必须说明「必填 / 默认值」不适用', () {
      // 这条说明是"避免设了没生效"的关键文案，但它在表单最下方、惰性列表里
      // 滚动锚点容易滚过头（S1 实测）⇒ 用源码守卫钉住，不做易碎的滚动断言。
      final source = File(
        'lib/page/settings_page/online_music_capability_editor.dart',
      ).readAsStringSync();
      expect(source, contains('固定值由你自己写死'));
      expect(source, contains('「必填 / 默认值」在这里不起作用'));
    });
  });

  group('★ F4-S2 请求头可「来自输入」（P-09 / D3 边界）', () {
    OnlineMusicDeclarativeCapabilityBinding dynamicHeaderFixture() =>
        OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/search',
            headers: [
              OnlineMusicHeaderSpec(
                name: 'X-Keyword',
                value: '',
                source: OnlineMusicInputSource.keyword,
              ),
            ],
          ),
          response: validBindingFor(OnlineMusicCapability.search).response,
        );

    Future<void> addHeader(WidgetTester tester, String name) async {
      // 表单是惰性 ListView：必须先滚到「加请求头」再点。
      await scrollCapabilityFormTo(tester, '加请求头');
      await tester.tap(find.text('加请求头'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .ancestor(of: find.text('请求头名'), matching: find.byType(TextField))
            .first,
        name,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('★ 动态头经「打开 → 保存」往返不丢 source', (tester) async {
      final saved = await saveRoundTrip(tester, dynamicHeaderFixture());

      final header = saved.request.headers.single;
      expect(
        header.source,
        OnlineMusicInputSource.keyword,
        reason: '表单保存不得把动态头悄悄变回固定值',
      );
      expect(header.value, isEmpty);
      expect(header.toJson().containsKey('source'), isTrue);
    });

    testWidgets('★ 表单里勾「来自输入」并保存 ⇒ 配置带 source、无固定值', (tester) async {
      final fixture = bindingWithParamExtras();
      final settings = settingsWithBinding(
        OnlineMusicCapability.search,
        fixture,
      );
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

      await addHeader(tester, 'X-Keyword');
      await scrollCapabilityFormTo(tester, '来自输入');
      final toggleRow = find
          .ancestor(of: find.text('来自输入'), matching: find.byType(Row))
          .first;
      await tester.tap(
        find.descendant(of: toggleRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final saved =
          controller.settings.providers.single.bindingFor(
                OnlineMusicCapability.search,
              )
              as OnlineMusicDeclarativeCapabilityBinding;
      final header = saved.request.headers.single;
      expect(
        header.source,
        defaultInputSourceFor(OnlineMusicCapability.search),
        reason: '默认来源按能力决定（与参数行同一规则，P-23）',
      );
      expect(header.value, isEmpty, reason: '动态头不带固定值（两者互斥）');
    });

    testWidgets('★ 勾上「敏感」会被强制退回固定值/引用模式（不得来自输入）', (tester) async {
      final settings = settingsWithBinding(
        OnlineMusicCapability.search,
        dynamicHeaderFixture(),
      );
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

      await scrollCapabilityFormTo(tester, '敏感');
      // 与既有 F0 用例同一手法（`tapVisible`：先滚进视口再点）。
      await tapVisible(tester, find.text('敏感'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final saved =
          controller.settings.providers.single.bindingFor(
                OnlineMusicCapability.search,
              )
              as OnlineMusicDeclarativeCapabilityBinding;
      final header = saved.request.headers.single;
      expect(header.sensitive, isTrue);
      expect(header.source, isNull, reason: '敏感头绝不能来自输入（F0 边界只加强不削弱）');
      expect(header.credentialReference, isNotNull, reason: '敏感头必须带凭据引用');
    });
  });

  group('★ F4-S9 边界文案（P-12 / D4）', () {
    test('源码守卫：界面必须写明"不支持什么"与"空值≡缺失 / 转换闭集"', () {
      // 这两条是 D3/D4 的"必须写明支持范围"落到**用户看得见的地方**；
      // 文案在惰性列表深处 ⇒ 用源码守卫钉住，不做易碎的滚动断言。
      final source = File(
        'lib/page/settings_page/online_music_capability_editor.dart',
      ).readAsStringSync();

      // P-12 / D3：不支持的认证方式必须明确报出边界。
      expect(source, contains('自动登录'), reason: 'P-12');
      expect(source, contains('动态签名'));
      expect(source, contains('令牌刷新'));
      expect(source, contains('不会被静默忽略'));
      // F4-S8 的非 ASCII 边界也写在用户看得见的地方。
      expect(source, contains('请求头值只能是 ASCII'));
      // D4：null 与缺失同义、转换是闭集，且**不会静默返回空值**。
      expect(source, contains('空值与「键不存在」同义'), reason: 'D4');
      expect(source, contains('不会静默变成空值'));
    });
  });

  group('F1 P-21 请求体可编辑（POST 类能力不再只能走 JSON）', () {
    testWidgets('★ 请求体的存在性 / 格式 / 字段都能配并且往返不变', (tester) async {
      // 有请求体 + JSON + 一个字段（含必填与默认值）。
      final fixture = bindingWithBody();
      final settings = settingsWithBinding(
        OnlineMusicCapability.search,
        fixture,
      );
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

      // 界面确实给了这些控件（滚到请求体区块）。
      await scrollCapabilityFormTo(tester, '请求体格式');

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final saved =
          controller.settings.providers.single.bindingFor(
                OnlineMusicCapability.search,
              )
              as OnlineMusicDeclarativeCapabilityBinding;
      expect(saved.request.body, isNotNull);
      expect(saved.request.body!.isForm, isFalse, reason: '夹具是 JSON');
      expect(saved.request.body!.fields.single.name, 'kw');
      expect(
        saved.request.body!.fields.single.defaultValue,
        7,
        reason: '请求体字段的默认值也要保住类型',
      );
      expect(saved.request.body!.fields.single.required, isTrue);
    });

    testWidgets('★ 切到「表单」后保存 ⇒ isForm 变真（请求体真的可编辑）', (tester) async {
      final fixture = bindingWithBody();
      final settings = settingsWithBinding(
        OnlineMusicCapability.search,
        fixture,
      );
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, OnlineMusicCapability.search);
      await scrollCapabilityFormTo(tester, '请求体格式');

      await tester.tap(find.text('表单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final saved =
          controller.settings.providers.single.bindingFor(
                OnlineMusicCapability.search,
              )
              as OnlineMusicDeclarativeCapabilityBinding;
      expect(saved.request.body!.isForm, isTrue);
    });

    testWidgets('★ 两种"没有字段"的形状不被悄悄改写', (tester) async {
      // "有 body 但字段为空"（POST 会发 `{}`）与"没有 body"（不发 body）
      // 是两条**不同的线上行为**，界面不得把它们混成一个。
      final emptyBody = await saveRoundTrip(
        tester,
        bindingWithBody(includeFields: false),
      );
      expect(emptyBody.request.body, isNotNull, reason: '有 body 就得保留 body');
      expect(emptyBody.request.body!.fields, isEmpty);

      final noBody = await saveRoundTrip(
        tester,
        bindingWithBody(includeBody: false),
      );
      expect(noBody.request.body, isNull, reason: '没有 body 不得凭空造一个');
    });

    testWidgets('GET 时提示"只有 POST 才能带请求体"（模型校验的界面口径）', (tester) async {
      final fixture = bindingWithBody(verb: OnlineMusicHttpVerb.get);
      final settings = settingsWithBinding(
        OnlineMusicCapability.search,
        fixture,
      );
      final controller = _controller(configured: settings, active: settings);
      addTearDown(controller.dispose);
      await pumpPanel(tester, controller);
      await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

      await scrollCapabilityFormTo(tester, '带请求体');
      expect(find.textContaining('只有切换到 POST 才能带请求体'), findsOneWidget);
    });
  });

  testWidgets('★ F4 收口 分页说明与当前事实一致（含"总数路径缺失 ⇒ 加载更多不会出现"）', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

    // ⚠️ 惰性列表：说明在「总数路径」下方、滚动锚点用**精确匹配** ⇒ 滚到它下方的区块标题，
    // 保证说明已经进入 widget 树（是否可见不影响 contains 断言）。
    await scrollCapabilityFormTo(tester, '字段映射', maxAttempts: 40);

    // ① 说明必须与 **F4-S3 之后的事实**一致（旧文案写"目前不参与请求构造 / 还不生效"，
    //    S3 起 `offset`/`limit`/`page` 已经真的进请求 ⇒ 旧文案是错的）。
    expect(
      find.textContaining('按每页数量与偏移量分页的接口现在真的会生效'),
      findsOneWidget,
      reason: '必须如实告知"哪些生效、哪些不生效"',
    );
    // ② 游标分页的不支持要写明"会明确报错"，而不是让人以为填了就能用。
    expect(find.textContaining('使用「游标」分页的接口暂不支持'), findsOneWidget);
    expect(find.textContaining('不会悄悄当成第一页'), findsOneWidget);
    // ③ 本条的核心：`totalPath` 缺失 ⇒ 无法可靠判断"还有更多" ⇒ 必须说清并给出去处。
    expect(
      find.textContaining('没配「总数路径」'),
      findsOneWidget,
      reason: '无法可靠判断"还有更多"时不得沉默（否则用户只会看到"没有加载更多"）',
    );
    expect(find.textContaining('「加载更多」不会出现'), findsOneWidget);
    expect(find.textContaining('配好总数路径即可'), findsOneWidget);

    // 控件仍**刻意不给**：「分页类型 / 默认每页数量」是可点却无效果的选项（反模式 7）。
    expect(find.text('分页类型'), findsNothing);
    expect(find.text('默认每页数量'), findsNothing);
  });

  // ------------------------------------------------------------------ F1-g（P-64）

  test('★ F1 P-64 标签表必须覆盖全部枚举值', () {
    // 兜底是 `?? 枚举名` ⇒ 漏一个就会把**英文枚举名**渲染到界面上
    //（字段行标题、取值来源菜单、类型转换菜单）。逐值断言，新增枚举值也不会漏。
    for (final field in OnlineMusicDomainField.values) {
      expect(
        domainFieldLabel(field),
        isNot(field.name),
        reason: '${field.name} 缺中文标签（会以英文枚举名显示在字段行标题上）',
      );
    }
    for (final source in OnlineMusicInputSource.values) {
      expect(
        inputSourceLabel(source),
        isNot(source.name),
        reason: '${source.name} 缺中文标签（会以英文枚举名显示在取值来源菜单里）',
      );
    }
    for (final transform in OnlineMusicFieldTransform.values) {
      expect(
        transformLabel(transform),
        isNot(transform.name),
        reason: '${transform.name} 缺中文标签',
      );
    }
  });

  test('★ F1 P-64 试跑是否需要额外 ID 由能力决定', () {
    // 只有"按 id 取单条"的能力需要；数组类能力（歌单列表/分类/榜单/新歌）一律不需要
    //（旧写法只对 playlistCollection 特判，于是另三个也显示一个用不到的输入框）。
    const needsId = {
      OnlineMusicCapability.playlist,
      OnlineMusicCapability.artist,
      OnlineMusicCapability.album,
      // 艺人专辑列表也要艺人 ID ✓。
      OnlineMusicCapability.artistAlbums,
      // 艺人单曲列表同样 ✓。
      OnlineMusicCapability.artistSongs,
      OnlineMusicCapability.lyric,
      OnlineMusicCapability.stream,
    };
    for (final capability in OnlineMusicCapability.values) {
      final testId = testIdFieldFor(capability);
      expect(
        testId.needed,
        needsId.contains(capability),
        reason: '${capability.name} 是否需要试跑 ID 判断错了',
      );
      if (testId.needed) {
        expect(testId.label, isNotEmpty, reason: '需要 ID 就得给出它的名字');
      }
    }
  });

  testWidgets('F1 P-64 非搜索能力的副标题按能力取名，不再一律"播放解析"', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(
      tester,
      OnlineMusicCapability.playlistCollection,
    );

    // 断言要**限定在编辑器对话框内**：背后的平台卡每个平台都有一行「播放解析」。
    final editor = find.byType(Dialog);
    expect(
      find.descendant(of: editor, matching: find.textContaining('声明式歌单列表')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: editor, matching: find.textContaining('播放解析')),
      findsNothing,
      reason: '以前所有非搜索能力的副标题都写"声明式播放解析"',
    );
  });

  testWidgets('F1 P-64 数组类能力的试跑**不要求 ID**（F3-S7 起给出每页数量）', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.chartList);

    // ⚠️ 不能滚到「试跑」：操作栏上的「试跑」按钮永远可见，锚点会立刻命中而根本不滚动。
    // 直接滚到那句输入标签本身（表单最下方，惰性 ListView）⇒ 多给几次机会。
    await scrollCapabilityFormTo(tester, '试跑用的每页数量', maxAttempts: 30);

    // P-64 的不变量仍然成立：数组类能力**不要求"试跑用的 ID"**。
    expect(find.textContaining('试跑用的 ID'), findsNothing);
    expect(find.textContaining('试跑用的曲目 ID'), findsNothing);
    expect(find.textContaining('试跑用的歌单 ID'), findsNothing);
    expect(testIdFieldFor(OnlineMusicCapability.chartList).needed, isFalse);
    // F3-S7（P-49）：改为给出**真正会被用到**的输入 —— 每页数量（以前写死）。
    expect(find.text('试跑用的每页数量'), findsOneWidget);
    expect(
      testInputFieldsFor(OnlineMusicCapability.chartList).limit,
      isTrue,
      reason: '数组类能力最可能用到 limit；它以前是写死的 1 / 30',
    );
  });

  testWidgets('F1 P-64 用户可见处不再露英文平台枚举名', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    // 列表副标题：内容来源用中文平台名。
    expect(
      find.textContaining(musicPlatformLabel(MusicPlatform.netease)),
      findsWidgets,
    );
    expect(
      find.textContaining('netease'),
      findsNothing,
      reason: '界面文案里不该出现英文枚举名',
    );

    // 添加提供商对话框的「内容来源」分段按钮同理。
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    for (final platform in builtinMusicPlatforms) {
      expect(
        find.text(musicPlatformLabel(platform)),
        findsWidgets,
        reason: '内容来源应当显示 ${musicPlatformLabel(platform)}',
      );
    }
    expect(find.text('netease'), findsNothing);
  });

  testWidgets('F1 P-64 标题用展示名而不是内部 id', (tester) async {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'displayName': '网易云本地',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'none'},
          'capabilities': {
            'search': validBindingFor(OnlineMusicCapability.search).toJson(),
          },
        },
      ],
    });
    final controller = _controller(configured: settings, active: settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.byTooltip('能力配置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('能力配置 · 网易云本地'), findsOneWidget);
    expect(
      find.textContaining('能力配置 · selfData'),
      findsNothing,
      reason: '用户可见标题不该用内部 id',
    );
  });

  // ------------------------------------------------------------------ F2（P-31）

  testWidgets('★ F2 P-31 保存时把字段级 required 派生自能力级 requiredFieldsFor', (
    tester,
  ) async {
    // 夹具起点故意制造**矛盾**：search 的能力级要求是 {trackId, title}，
    // 但文件里 trackId 的字段级标记是 false（手工编辑或旧版本可能留下这种状态）。
    final base = validBindingFor(OnlineMusicCapability.search);
    final fields = Map.of(base.response.fields);
    final trackId = fields[OnlineMusicDomainField.trackId]!;
    fields[OnlineMusicDomainField.trackId] = OnlineMusicFieldSpec(
      candidates: trackId.candidates,
      transform: trackId.transform,
      required: false,
    );
    final fixture = OnlineMusicDeclarativeCapabilityBinding(
      request: base.request,
      response: OnlineMusicResponseSpec(
        success: base.response.success,
        listPath: base.response.listPath,
        fieldsRootPath: base.response.fieldsRootPath,
        pagination: base.response.pagination,
        fields: fields,
      ),
    );
    expect(
      fixture.response.fields[OnlineMusicDomainField.trackId]!.required,
      isFalse,
      reason: '夹具起点：字段级标记与能力级要求相反',
    );

    final saved = await saveRoundTrip(tester, fixture);

    expect(
      saved.response.fields[OnlineMusicDomainField.trackId]!.required,
      isTrue,
      reason: '保存后必须与唯一事实源（能力级 requiredFieldsFor）一致',
    );
    expect(
      saved.response.fields[OnlineMusicDomainField.album]?.required ?? false,
      isFalse,
      reason: '非必填字段不得被写上必填',
    );
  });

  testWidgets('★ F2 P-32 面板如实显示条目的配置问题（能力 JSON 损坏）', (tester) async {
    // 损坏的能力以前被静默降级成"不支持"，与"从未配置"在界面上完全同形：
    // 用户只看到"这个能力就是不支持"，不知道是自己的配置坏了。
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'none'},
          'capabilities': {
            'search': {'kind': 'script'},
          },
        },
      ],
    });
    final controller = _controller(configured: settings, active: settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    expect(find.textContaining('配置问题：'), findsOneWidget);
    expect(find.textContaining('已损坏'), findsOneWidget);
    expect(
      find.textContaining('script'),
      findsNothing,
      reason: '配置里的原始值不得回显到界面',
    );
  });

  testWidgets('★ F2 P-32 干净的条目**不**显示配置问题', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    expect(find.textContaining('配置问题：'), findsNothing);
  });

  // ------------------------------------------------------------------ F2（P-29）

  testWidgets('★ F2 P-29 设置页显示路由诊断（只读、纯文本、不含凭据）', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller, service: _DiagnosticsOnlyService());

    // 能力清单变长（2026-10-12 起 13 项）⇒ 诊断区块可能落在惰性列表下方 ✗
    // ⇒ 用**普通滚动查找**（不能用 `scrollCapabilityFormTo`：那是"能力编辑器表单"专用 ✓）。
    await tester.scrollUntilVisible(
      find.text('路由诊断'),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('路由诊断'), findsOneWidget);
    expect(find.textContaining('网易云/搜索'), findsOneWidget);
    expect(find.textContaining('neteaseA'), findsOneWidget);
    expect(find.textContaining('neteaseB（成功）'), findsOneWidget);
    expect(find.textContaining('SECRET'), findsNothing);
  });

  // ------------------------------------------------------------------ F2（P-36）

  testWidgets('★ F2 P-29 拿不到诊断源时不渲染该区块（老替身不受影响）', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    // 真实组合：还没有任何路由记录 ⇒ 整段不渲染。
    await pumpPanel(tester, controller);

    expect(find.text('路由诊断'), findsNothing);
  });

  testWidgets('★ F2 P-36 能力编辑器在"条目不需要 Key 却声明认证"时当场提示', (tester) async {
    final controller = _controller(
      configured: settingsWithAuthDeclaringSearch(requiresCredential: false),
      active: settingsWithAuthDeclaringSearch(requiresCredential: false),
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.search);
    // 表单是**惰性 ListView**：滚到提示**下方**的「加请求头」，
    // 保证提示所在的那一行确实进了构建窗口（否则会变成"没构建 ⇒ 找不到"的假绿）。
    await scrollCapabilityFormTo(tester, '加请求头');

    expect(
      find.textContaining('但该条目当前设为「不需要 Key」'),
      findsOneWidget,
      reason: 'P-36：矛盾必须**在动手时**说清，而不是等运行期报缺少凭据',
    );
  });

  testWidgets('★ F2 P-36 对照组：同一条能力，条目改成"需要 Key"后提示消失', (tester) async {
    // 对照组与上一条**只差条目级那一个开关**，锚点、滚动过程完全相同 ——
    // 这样"找不到"才是真的没有，而不是"没滚到/没构建"。
    final controller = _controller(
      configured: settingsWithAuthDeclaringSearch(requiresCredential: true),
      active: settingsWithAuthDeclaringSearch(requiresCredential: true),
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.search);
    await scrollCapabilityFormTo(tester, '加请求头');
    expect(find.text('加请求头'), findsOneWidget, reason: '确认到了同一块区域');

    expect(find.textContaining('不需要 Key'), findsNothing);
  });

  // ------------------------------------------------------------------ F2（P-04 / P-37）

  testWidgets('★ F2 P-04 只有**改了的那一个条目**被标成"未生效"', (tester) async {
    // 以**默认配置的序列化结果**为基底，保证内置条目与运行中的那份逐字段相同 ——
    // 手写 `{'id':'chksz','protocol':'chksz'}` 会与内置默认条目在 baseUrl 等字段上不同，
    // 于是"没改过的条目"也会被标成未生效（夹具不精确，而不是判定错了）。
    final configured = OnlineMusicSettings.fromJson({
      'providers': [
        ...(OnlineMusicSettings.defaults.toJson()['providers'] as List),
        OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'http://127.0.0.1:8080',
          requiresCredential: false,
        ).toJson(),
      ],
    });
    // active 里**没有** selfData ⇒ 只有它是"未生效"。
    final controller = _controller(
      configured: configured,
      active: OnlineMusicSettings.defaults,
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    expect(
      find.text('未生效：这个条目的改动要重启后才进入运行时'),
      findsOneWidget,
      reason: 'P-04：逐条目标记 —— 没改过的条目不背这个锅',
    );
  });

  testWidgets('★ F2 P-04 改一个能力的来源 ⇒ 只在该平台/该能力上标"未生效"', (tester) async {
    final base = settingsWithBinding(
      OnlineMusicCapability.search,
      validBindingFor(OnlineMusicCapability.search),
    );
    final controller = _controller(configured: base, active: base);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    // 起点：一致 ⇒ 没有任何"未生效"标记。
    expect(find.textContaining('尚未生效'), findsNothing);

    await controller.assignPlatformCapability(
      MusicPlatform.netease,
      OnlineMusicCapability.search,
      'selfData',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('这里的改动尚未生效'), findsOneWidget);
    expect(find.textContaining('该平台的改动尚未生效'), findsOneWidget);
  });

  // ------------------------------------------------------------------ F2（P-22）

  testWidgets('★ F2 P-22 旧单值配置下点「自动」⇒ 该行真的回到「自动」', (tester) async {
    // P-22 的可复现症状：旧配置里 `capabilities: {search: 'chksz'}` 会被渲染成
    // 「已指定 chksz」；点「自动」只清了 `routing`，回落立刻又把它拉回来 ⇒ 操作看似无效。
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {'id': 'chksz', 'protocol': 'chksz'},
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'none'},
        },
      ],
      'capabilities': {'search': 'chksz'},
    });
    final controller = _controller(configured: settings, active: settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    expect(find.text('已指定 chksz'), findsOneWidget);

    // 精确定位到**那一行**：只有它把 'chksz' 作为选中值。
    final target = find.byWidgetPredicate(
      (widget) =>
          widget is SegmentedButton<String> &&
          widget.selected.contains('chksz'),
    );
    expect(target, findsOneWidget, reason: '被旧单值指定的那一行');
    await tester.tap(find.descendant(of: target, matching: find.text('自动')));
    await tester.pumpAndSettle();

    expect(
      find.text('已指定 chksz'),
      findsNothing,
      reason: 'P-22：点「自动」必须真的清空，而不是马上又被回落填回来',
    );
    expect(find.textContaining('自动：按条目顺序使用'), findsWidgets);
  });

  testWidgets('★ F2 P-14 面板把旧版旋钮如实列出来（以前完全看不到）', (tester) async {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {'id': 'chksz', 'protocol': 'chksz'},
      ],
      'capabilities': {'search': 'chksz'},
    });
    final controller = _controller(configured: settings, active: settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    expect(find.textContaining('还带着旧版「能力分配」'), findsOneWidget);
    expect(find.textContaining('search→chksz'), findsOneWidget);
  });

  testWidgets('★ F2 P-14 默认配置不显示旧旋钮提示（不误报）', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    expect(find.textContaining('还带着旧版「能力分配」'), findsNothing);
    expect(find.textContaining('还带着旧版「默认提供商」'), findsNothing);
  });

  testWidgets('★ F2 P-37 配置停用、运行中仍可用 ⇒ **两个事实都显示**且各自标注来源', (tester) async {
    // 让运行中的 service **确实**服务 qq：声明式条目 + search/stream 两条绑定
    //（D3 硬门槛要求可搜索 = 有 search 且有 stream）。
    final searchJson = validBindingFor(OnlineMusicCapability.search).toJson();
    final qqSettings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'contentPlatform': 'qq',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'none'},
          'capabilities': {
            'search': searchJson,
            'stream': authDeclaringSearchBindingJson(),
          },
        },
      ],
    });
    final configured = qqSettings.withPlatformEnabled(
      MusicPlatform.qq,
      enabled: false,
    );
    final controller = _controller(configured: configured, active: qqSettings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    final qqCard = platformCard(MusicPlatform.qq);
    expect(
      find.descendant(of: qqCard, matching: find.text('已停用')),
      findsOneWidget,
      reason: '配置态的事实',
    );
    expect(
      find.descendant(of: qqCard, matching: find.text('运行中：仍可用（停用要下次启动才生效）')),
      findsOneWidget,
      reason: 'P-37：运行中的事实必须**同时**说清，不能被展示优先级吃掉',
    );
  });

  // ------------------------------------------------------------------ F3（P-25）

  testWidgets('★ F3-S5 应用探测初稿会**同时**更新 _binding（JSON 视图与分页不再丢）', (
    tester,
  ) async {
    // 这个条目**没有任何**声明式绑定 ⇒ 编辑器是空的；而探测按 D-F3-1 走兼容模板
    //（内置 chksz 模板带 offsetLimit **分页**）—— 这正好能观测"初稿有没有真的进入
    // 单一事实源 `_binding`"：若只回填表单行，JSON 视图会停在**空绑定**、
    // 分页也会在保存时被 `_collect()` 丢掉（P-25）。
    //
    // ⚠️ 必须**备好凭据**：chksz 模板声明了认证，按 F3-S4（D-F3-2）"没有凭据 ⇒
    // 不计为可用、不产出初稿"，所以没凭据时本用例根本走不到初稿那一步。
    final credentials = _FakeCredentialAccess()
      ..saved['self/APIKey'] = 'chksz_PROBE_KEY_TEST_ONLY';
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'selfData',
          'baseUrl': 'https://self.invalid',
          'auth': {'kind': 'apiKey', 'reference': 'self/APIKey'},
        },
      ],
    });
    // 响应必须是**可解析出曲目**的 chksz 形状，否则探测不会产出初稿（也就观测不到本片）。
    final probeTransport = _StubTransport(const {
      'code': 200,
      'msg': 'success',
      'data': {
        'songs': [
          {'id': 65800, 'name': '最佳损友', 'artists': '陈奕迅', 'duration': 233560},
        ],
        'total': 1,
      },
    });
    final controller = _controller(
      configured: settings,
      active: settings,
      credentials: credentials,
      credentialReader: credentials,
      probeTransportFactory: (_) => probeTransport,
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

    // JSON 视图默认隐藏（`_showJson`）。先在**表单态**读一次基线：编辑器里的绑定是空的。
    final jsonToggle = find.widgetWithText(TextButton, 'JSON');
    expect(jsonToggle, findsOneWidget, reason: '编辑器应提供 JSON 视图切换');
    await tester.tap(jsonToggle);
    await tester.pumpAndSettle();
    expect(_jsonViewText(tester), isNot(contains('/api/163_search')));
    // 切回表单态再探测（探测按钮在任何视图下都在，但这样步骤更直白）。
    await tester.tap(find.widgetWithText(TextButton, '表单'));
    await tester.pumpAndSettle();

    final probeButton = find.widgetWithText(TextButton, '探测该服务');
    expect(probeButton, findsOneWidget, reason: '搜索能力应提供「探测该服务」');
    await tester.tap(probeButton);
    await tester.pumpAndSettle();
    // F3-2b：探测前先确认计划（候选 / 输入 / 凭据），确认后才发请求。
    await tester.tap(find.text('开始探测'));
    await tester.pumpAndSettle();

    // F3-5a：初稿只是**建议** —— 先弹差异确认。这里先选「保留我的编辑」，
    // 断言**什么都没被改**（旧行为是静默覆盖，这一片就是来钉死它的）。
    expect(find.text('探测生成了建议配置'), findsOneWidget);
    expect(find.textContaining('处差异'), findsOneWidget);
    await tester.tap(find.text('保留我的编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'JSON'));
    await tester.pumpAndSettle();
    expect(
      _jsonViewText(tester),
      isNot(contains('/api/163_search')),
      reason: 'F3-5a：拒绝建议后不得改动当前编辑内容',
    );
    await tester.tap(find.widgetWithText(TextButton, '表单'));
    await tester.pumpAndSettle();

    // 再探测一次，这次**应用建议** ⇒ 初稿才进入 `_binding`。
    await tester.tap(probeButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始探测'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用建议'));
    await tester.pumpAndSettle();

    // 应用初稿会把视图切回表单（`_loadFromBinding` 里 `_showJson = false`），因此再切到 JSON。
    await tester.tap(find.widgetWithText(TextButton, 'JSON'));
    await tester.pumpAndSettle();
    final json = _jsonViewText(tester);
    expect(
      json,
      contains('/api/163_search'),
      reason: 'P-25：初稿必须进入 `_binding`（JSON 视图随之更新），而不是只填表单行',
    );
    expect(
      json,
      contains('"pagination"'),
      reason: 'P-25：初稿的分页属于"没有表单行"的字段，只填行就会丢',
    );
    expect(probeTransport.probeCalls, greaterThan(0));
  });

  testWidgets('★ F3-S7 界面上填的关键词/数量真的进了试跑请求（P-49）', (tester) async {
    // 夹具必须**显式声明** keywords / limit 两个查询参数：只有声明了，用户的输入
    // 才可能出现在请求里 —— 这正是要验的那条链路（以前界面上根本没有关键词输入）。
    final binding = OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
            required: true,
          ),
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('result.songs')!,
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('id')!],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('name')!],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      ),
    );
    final settings = settingsWithBinding(OnlineMusicCapability.search, binding);
    final transport = _StubTransport();
    final controller = _controller(
      configured: settings,
      active: settings,
      probeTransportFactory: (_) => transport,
    );
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

    // 试跑输入区在表单最下方（惰性 ListView）⇒ 先把它滚出来。
    await scrollCapabilityFormTo(tester, '试跑用的关键词', maxAttempts: 30);
    Future<void> enter(String label, String text) async {
      final field = find.ancestor(
        of: find.text(label),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget, reason: '应能找到「$label」输入框');
      await tester.enterText(field, text);
    }

    await enter('试跑用的关键词', '自定义词');
    // 能力清单多一行（艺人/专辑）会把表单顶下去 ⇒ 每个字段都先滚到它再填 ✓。
    await scrollCapabilityFormTo(tester, '试跑用的每页数量', maxAttempts: 30);
    await enter('试跑用的每页数量', '7');

    await tester.tap(find.widgetWithText(TextButton, '试跑'));
    await tester.pumpAndSettle();

    final sent = transport.requests.last.query;
    expect(sent['keywords'], '自定义词', reason: 'P-49：界面上填的关键词必须真的进请求（以前恒为探测常量）');
    expect(sent['limit'], '7', reason: 'P-49：以前恒为 1');
  });
}

/// 读出 JSON 高级视图里的文本（JSON 视图是编辑器里唯一含 `"path"` 的输入框）。
String _jsonViewText(WidgetTester tester) => tester
    .widgetList<TextField>(find.byType(TextField))
    .map((field) => field.controller?.text ?? '')
    .firstWhere((text) => text.contains('"path"'), orElse: () => '');

/// 只提供诊断的最小替身：其余成员用 `noSuchMethod` 兜住
/// （这正是"诊断是**可选**出口"的体现 —— 不实现它就等于这一版没有诊断）。
final class _DiagnosticsOnlyService
    implements OnlineMusicService, OnlineMusicDiagnosticsSource {
  @override
  OnlineMusicCapabilities get capabilities => OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
  );

  @override
  List<OnlineMusicDiagnosticsEntry> get routeDiagnostics => const [
    OnlineMusicDiagnosticsEntry(
      platformLabel: '网易云',
      capabilityLabel: '搜索',
      attempts: ['neteaseA（网络）'],
      winnerProviderId: 'neteaseB',
    ),
  ];

  @override
  void dispose() {}

  /// 面板的"播放音质"区块会问档位；这个替身没有声明 ⇒ 空表（UI 走内部档位回落）。
  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 各能力的**校验通过**夹具：路径与字段名都取自真实配方（`docs/dev/netease-bindings/`）。
OnlineMusicDeclarativeCapabilityBinding validBindingFor(
  OnlineMusicCapability capability,
) {
  OnlineMusicFieldSpec field(
    OnlineMusicDomainField domainField,
    String path,
    OnlineMusicFieldTransform transform,
  ) => OnlineMusicFieldSpec(
    candidates: [JsonPath.tryParse(path)!],
    transform: transform,
    required: requiredFieldsFor(capability).contains(domainField),
  );

  const asString = OnlineMusicFieldTransform.asString;
  const asInt = OnlineMusicFieldTransform.asInt;
  const asUri = OnlineMusicFieldTransform.asUri;
  const trackId = OnlineMusicDomainField.trackId;
  const title = OnlineMusicDomainField.title;
  const playlistId = OnlineMusicDomainField.playlistId;
  const playlistName = OnlineMusicDomainField.playlistName;
  const categoryId = OnlineMusicDomainField.categoryId;
  const categoryName = OnlineMusicDomainField.categoryName;
  const streamUrl = OnlineMusicDomainField.streamUrl;
  const lyricOriginal = OnlineMusicDomainField.lyricOriginal;

  return switch (capability) {
    OnlineMusicCapability.search => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/search'),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('result.songs'),
        fields: {
          trackId: field(trackId, 'id', asInt),
          title: field(title, 'name', asString),
        },
      ),
    ),
    // 推荐曲目：与"新歌/搜索"同构（曲目数组 ✓）—— 网易云 `/recommend/songs` 在 `data.dailySongs` ✓。
    OnlineMusicCapability.recommendedTracks =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/recommend/songs'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('data.dailySongs'),
          fields: {
            trackId: field(trackId, 'id', asInt),
            title: field(title, 'name', asString),
          },
        ),
      ),
    // 关注艺人：与"搜索艺人"同构（艺人摘要数组 ✓）—— 网易云 `/artist/sublist` 在 `data` ✓。
    OnlineMusicCapability.followedArtists =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/artist/sublist'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('data'),
          fields: {
            OnlineMusicDomainField.artistId: field(
              OnlineMusicDomainField.artistId,
              'id',
              asInt,
            ),
            OnlineMusicDomainField.artistName: field(
              OnlineMusicDomainField.artistName,
              'name',
              asString,
            ),
          },
        ),
      ),
    // 搜索艺人：艺人在 `result.artists` 下（网易云 `/cloudsearch?type=100` ✓）。
    OnlineMusicCapability.searchArtists =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/cloudsearch'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('result.artists'),
          fields: {
            OnlineMusicDomainField.artistId: field(
              OnlineMusicDomainField.artistId,
              'id',
              asInt,
            ),
            OnlineMusicDomainField.artistName: field(
              OnlineMusicDomainField.artistName,
              'name',
              asString,
            ),
          },
        ),
      ),
    // 搜索专辑：专辑在 `result.albums` 下（网易云 `/cloudsearch?type=10` ✓）。
    OnlineMusicCapability.searchAlbums =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/cloudsearch'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('result.albums'),
          fields: {
            OnlineMusicDomainField.albumId: field(
              OnlineMusicDomainField.albumId,
              'id',
              asInt,
            ),
            OnlineMusicDomainField.albumName: field(
              OnlineMusicDomainField.albumName,
              'name',
              asString,
            ),
          },
        ),
      ),
    // 新专辑：专辑就在数组元素上（网易云 `/album/new` 的 `albums` ✓）。
    OnlineMusicCapability.newAlbums =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/album/new'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('albums'),
          fields: {
            OnlineMusicDomainField.albumId: field(
              OnlineMusicDomainField.albumId,
              'id',
              asInt,
            ),
            OnlineMusicDomainField.albumName: field(
              OnlineMusicDomainField.albumName,
              'name',
              asString,
            ),
          },
        ),
      ),
    // 艺人单曲列表：曲目就在数组元素上（网易云 `/artist/songs` 的 `songs` ✓）。
    OnlineMusicCapability.artistSongs =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/artist/songs'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('songs'),
          fields: {
            OnlineMusicDomainField.trackId: field(
              OnlineMusicDomainField.trackId,
              'id',
              asInt,
            ),
            OnlineMusicDomainField.title: field(
              OnlineMusicDomainField.title,
              'name',
              asString,
            ),
          },
        ),
      ),
    // 艺人专辑列表：专辑就在数组元素上（网易云 `/artist/album` 的 `hotAlbums` ✓）。
    OnlineMusicCapability.artistAlbums =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/artist/album'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('hotAlbums'),
          fields: {
            OnlineMusicDomainField.albumId: field(
              OnlineMusicDomainField.albumId,
              'id',
              asInt,
            ),
            OnlineMusicDomainField.albumName: field(
              OnlineMusicDomainField.albumName,
              'name',
              asString,
            ),
          },
        ),
      ),
    // 专辑详情：标量在 `album`，曲目在**顶层** `songs`（与网易云实测一致）。
    OnlineMusicCapability.album => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/album'),
      response: OnlineMusicResponseSpec(
        fieldsRootPath: JsonPath.tryParse('album'),
        listPath: JsonPath.tryParse('songs'),
        fields: {
          OnlineMusicDomainField.albumName: field(
            OnlineMusicDomainField.albumName,
            'name',
            asString,
          ),
        },
      ),
    ),
    // 艺人详情：标量在 `artist`，热门曲目在 `hotSongs`（与网易云实测一致）。
    OnlineMusicCapability.artist => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/artists'),
      response: OnlineMusicResponseSpec(
        fieldsRootPath: JsonPath.tryParse('artist'),
        listPath: JsonPath.tryParse('hotSongs'),
        fields: {
          OnlineMusicDomainField.artistName: field(
            OnlineMusicDomainField.artistName,
            'name',
            asString,
          ),
        },
      ),
    ),
    // 歌单详情：元数据在 `playlist`，曲目数组在 `playlist.tracks`（两个不同的位置）。
    OnlineMusicCapability.playlist => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/playlist/detail'),
      response: OnlineMusicResponseSpec(
        fieldsRootPath: JsonPath.tryParse('playlist'),
        listPath: JsonPath.tryParse('playlist.tracks'),
        fields: {
          playlistId: field(playlistId, 'id', asString),
          playlistName: field(playlistName, 'name', asString),
          trackId: field(trackId, 'id', asInt),
          title: field(title, 'name', asString),
        },
      ),
    ),
    OnlineMusicCapability.playlistCollection =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/top/playlist'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('playlists'),
          fields: {
            playlistId: field(playlistId, 'id', asInt),
            playlistName: field(playlistName, 'name', asString),
          },
        ),
      ),
    // 推荐歌单：与"歌单列表"同构（歌单摘要数组 ✓）—— 网易云 `/recommend/resource` 在 `recommend` ✓。
    OnlineMusicCapability.recommendedPlaylists =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/recommend/resource'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('recommend'),
          fields: {
            playlistId: field(playlistId, 'id', asInt),
            playlistName: field(playlistName, 'name', asString),
          },
        ),
      ),
    OnlineMusicCapability.chartList => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/toplist'),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('list'),
        fields: {
          playlistId: field(playlistId, 'id', asInt),
          playlistName: field(playlistName, 'name', asString),
        },
      ),
    ),
    OnlineMusicCapability.playlistCategories =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/playlist/catlist'),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('sub'),
          fields: {
            categoryId: field(categoryId, 'name', asString),
            categoryName: field(categoryName, 'name', asString),
          },
        ),
      ),
    OnlineMusicCapability.newSongs => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/personalized/newsong'),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('result'),
        fields: {
          trackId: field(trackId, 'song.id', asInt),
          title: field(title, 'song.name', asString),
        },
      ),
    ),
    OnlineMusicCapability.lyric => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/lyric'),
      response: OnlineMusicResponseSpec(
        fields: {lyricOriginal: field(lyricOriginal, 'lrc.lyric', asString)},
      ),
    ),
    OnlineMusicCapability.stream => OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/song/url'),
      response: OnlineMusicResponseSpec(
        fieldsRootPath: JsonPath.tryParse('data'),
        fields: {
          streamUrl: field(streamUrl, 'url', asUri),
          trackId: field(trackId, 'id', asInt),
        },
      ),
    ),
  };
}

/// F1-d 用：带"必填 / 默认值"的查询参数夹具（search 的响应部分复用 [validBindingFor]）。
OnlineMusicDeclarativeCapabilityBinding bindingWithParamExtras({
  bool required = false,
  Object? defaultValue,
}) => OnlineMusicDeclarativeCapabilityBinding(
  request: OnlineMusicRequestSpec(
    path: '/search',
    query: [
      OnlineMusicParamBinding(
        name: 'limit',
        source: OnlineMusicInputSource.limit,
        required: required,
        defaultValue: defaultValue,
      ),
    ],
  ),
  response: validBindingFor(OnlineMusicCapability.search).response,
);

/// F1-d 用：带请求体的夹具（POST 默认；可切换 GET / 有无字段）。
OnlineMusicDeclarativeCapabilityBinding bindingWithBody({
  OnlineMusicHttpVerb verb = OnlineMusicHttpVerb.post,
  bool includeBody = true,
  bool includeFields = true,
  bool isForm = false,
}) => OnlineMusicDeclarativeCapabilityBinding(
  request: OnlineMusicRequestSpec(
    verb: verb,
    path: '/search',
    body: includeBody
        ? OnlineMusicRequestBodySpec(
            isForm: isForm,
            fields: includeFields
                ? const [
                    OnlineMusicParamBinding(
                      name: 'kw',
                      source: OnlineMusicInputSource.keyword,
                      required: true,
                      defaultValue: 7,
                    ),
                  ]
                : const [],
          )
        : null,
  ),
  response: validBindingFor(OnlineMusicCapability.search).response,
);

/// F2 P-36 用：一条**声明了认证**的声明式 search 绑定（字段映射齐全、校验通过）。
Map<String, Object?> authDeclaringSearchBindingJson() {
  final base = validBindingFor(OnlineMusicCapability.search);
  return OnlineMusicDeclarativeCapabilityBinding(
    request: OnlineMusicRequestSpec(
      verb: base.request.verb,
      path: base.request.path,
      query: base.request.query,
      headers: base.request.headers,
      body: base.request.body,
      auth: const OnlineMusicQueryAuthPlacement(parameterName: 'key'),
    ),
    response: base.response,
  ).toJson();
}

/// F2 P-36 用：同一个条目，只切**条目级**「是否需要 Key」这一个开关。
OnlineMusicSettings settingsWithAuthDeclaringSearch({
  required bool requiresCredential,
}) => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': requiresCredential ? 'apiKey' : 'none'},
      'capabilities': {'search': authDeclaringSearchBindingJson()},
    },
  ],
});

/// 一个只配了某个能力的条目（用于驱动能力编辑器）。
OnlineMusicSettings settingsWithBinding(
  OnlineMusicCapability capability,
  OnlineMusicCapabilityBinding binding,
) => OnlineMusicSettings.fromJson({
  'providers': [
    {
      'id': 'selfData',
      'baseUrl': 'https://self.invalid',
      'auth': {'kind': 'none'},
      'capabilities': {capability.name: binding.toJson()},
    },
  ],
});

/// F0-4 用的**校验通过**的声明式 search 绑定（字段映射齐全）。
Map<String, Object?> f04SearchBindingJson() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
            required: true,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('result.songs'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('id')!],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('name')!],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('artists[*].name')!],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
        },
      ),
    ).toJson();

final class _StubTransport implements DeclarativeHttpTransport {
  /// 可选自定义响应体；缺省是"搜索形状"的假响应（既有用例依赖它）。
  _StubTransport([this.response]);

  final Object? response;

  int probeCalls = 0;

  /// F3-S7：把发出去的请求记下来（用来断言"用户填的输入真的进了请求"）。
  final List<BuiltDeclarativeRequest> requests = [];

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    probeCalls++;
    requests.add(request);
    return DeclarativeHttpResponse(
      statusCode: 200,
      data:
          response ??
          const {
            'result': {
              'songs': [
                {'id': 1, 'name': 'probe', 'duration': 1000},
              ],
            },
          },
    );
  }
}

OnlineMusicProviderSettingsController _controller({
  OnlineMusicSettings configured = OnlineMusicSettings.defaults,
  OnlineMusicSettings active = OnlineMusicSettings.defaults,
  _FakeCredentialAccess? credentials,
  DeclarativeProbeTransportFactory? probeTransportFactory,
  OnlineMusicCredentialReader? credentialReader,
}) {
  return OnlineMusicProviderSettingsController(
    activeSettings: active,
    store: _MemorySettingsStore(configured),
    fallbackCredentials: credentials ?? _FakeCredentialAccess(),
    probeTransportFactory: probeTransportFactory,
    credentialReader: credentialReader,
  );
}

final class _MemorySettingsStore implements OnlineMusicSettingsStore {
  _MemorySettingsStore(this.value);

  OnlineMusicSettings value;

  /// 落盘次数（用来断言"用户确认之前一个字节都没写"）。
  int writes = 0;

  @override
  OnlineMusicSettings read() => value;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    writes++;
    value = settings;
    return true;
  }
}

final class _FakeCredentialAccess
    implements OnlineMusicCredentialAccess, OnlineMusicCredentialReader {
  final Map<String, String> saved = {};

  /// 非空时挂起 [`isConfigured`]，用于观察「加载中」这一帧的布局。
  Completer<void>? gate;

  /// 为真时让凭据读取抛错，用于覆盖错误提示与重试。
  bool failReads = false;

  /// 为真时让凭据**写入**失败（F0-6：覆盖"迁移全部失败"的标题）。
  bool failWrites = false;

  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'chksz_...';

  @override
  bool isValidFormat(String value) => RegExp(r'^chksz_\S+$').hasMatch(value);

  @override
  Future<bool> isConfigured(String reference) async {
    if (gate != null) await gate!.future;
    if (failReads) throw StateError('credential read failed');
    return saved.containsKey(reference);
  }

  @override
  Future<void> save(String reference, String value) async {
    if (failWrites) throw StateError('credential write failed');
    saved[reference] = value;
  }

  @override
  Future<void> clear(String reference) async => saved.remove(reference);

  /// F0-5 迁移需要"写后立即回读"，所以这个假件同时当读取口。
  @override
  Future<String?> readCredential(String reference) async => saved[reference];
}
