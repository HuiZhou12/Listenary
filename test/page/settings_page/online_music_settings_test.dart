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

const _apiKey = 'chksz_SETTINGS_TEST_ONLY';

void main() {
  Future<void> pumpPanel(
    WidgetTester tester,
    OnlineMusicProviderSettingsController controller, {
    bool active = true,
    OnlineMusicService? service,
  }) async {
    tester.view.physicalSize = const Size(1200, 2600);
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
    expect(
      find.text(label),
      findsOneWidget,
      reason: '把「$label」滚进视口后应当能找到它',
    );
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
    for (final platform in MusicPlatform.values) {
      expect(find.text(musicPlatformLabel(platform)), findsOneWidget);
    }
    // 每个平台卡内五行能力（search / 歌单详情 / 歌单列表 / lyric / stream）。
    for (final capability in OnlineMusicCapability.values) {
      expect(
        find.text(onlineMusicCapabilityLabel(capability)),
        findsNWidgets(MusicPlatform.values.length),
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
    tester.view.physicalSize = const Size(1200, 2600);
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
    expect(find.byType(Switch), findsNWidgets(MusicPlatform.values.length));

    // 关掉酷狗（卡顺序 = MusicPlatform.values 顺序）。
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
      MusicPlatform.values.where(controller.settings.isPlatformEnabled).length,
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
        .where((capability) => !builtinOnlineMusicCapabilities.contains(capability))
        .length;
    expect(missingOnNetease, 4, reason: '内置实现有 4 项 ⇒ 网易云卡应缺 4 项');
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
      findsNWidgets(
        2 * OnlineMusicCapability.values.length + missingOnNetease,
      ),
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

    expect(find.text('缺少播放解析能力，因此不会参与搜索'), findsOneWidget);
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
          .ancestor(
            of: find.text('请求头名'),
            matching: find.byType(TextField),
          )
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
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('保存'),
      ),
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
    test('★ 只有 search 的默认是「搜索关键词」', () {
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
      ]) {
        expect(defaults[capability], OnlineMusicInputSource.limit);
      }
      // **缺陷本体**：修复前"一律 keyword"，于是歌单详情里新增的参数会把
      // 搜索关键词当成歌单 ID 发出去。现在 keyword 只属于 search。
      expect(
        defaults.entries
            .where((entry) => entry.value == OnlineMusicInputSource.keyword)
            .map((entry) => entry.key)
            .toList(),
        [OnlineMusicCapability.search],
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
      final issues = const OnlineMusicResponseSpec().validationIssues(capability);
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
      expect(
        responsePathFieldsFor(OnlineMusicCapability.search),
        listPathOnly,
      );
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
    await scrollCapabilityFormTo(tester, '总数路径（可选）');
    expect(find.text('列表路径（如 data.songs）'), findsOneWidget);
    expect(find.text('字段根路径（如 data）'), findsNothing);
  });

  testWidgets('F1 P-01 歌单详情：两个路径入口都在，并说明各自放什么', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.playlist);

    await scrollCapabilityFormTo(tester, '总数路径（可选）');
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
    final settings = settingsWithBinding(OnlineMusicCapability.playlist, binding);
    final transport = _StubTransport({
      'playlist': {
        'id': 42,
        'name': '测试歌单',
        'tracks': [
          for (var i = 0; i < trackCount; i++)
            {'id': 100 + i, 'name': '曲目 $i'},
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
    final settings = settingsWithBinding(OnlineMusicCapability.playlist, binding);
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
    expect(
      find.textContaining('其它已配置的能力（歌单列表）保持不变'),
      findsOneWidget,
    );

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
      final fixture = bindingWithParamExtras(
        required: false,
        defaultValue: 30,
      );
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

  testWidgets('F1 P-21 分页刻意不给控件，但如实说明它当前不生效', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);
    await openCapabilityEditorFor(tester, OnlineMusicCapability.search);

    // 分页字段没有任何消费方 ⇒ 做成可编辑项就是"无效果选项"（反模式 7）。
    // 这里断言的是"**说明**存在、**控件**不存在"。
    await scrollCapabilityFormTo(tester, '游标路径（可选）');
    expect(
      find.textContaining('分页：目前不参与请求构造'),
      findsOneWidget,
      reason: '必须如实告知，而不是让用户以为改了就有用',
    );
    expect(find.text('分页类型'), findsNothing);
    expect(find.text('默认每页数量'), findsNothing);
  });
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
Map<String, Object?> f04SearchBindingJson() => OnlineMusicDeclarativeCapabilityBinding(
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

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    probeCalls++;
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
}) {
  return OnlineMusicProviderSettingsController(
    activeSettings: active,
    store: _MemorySettingsStore(configured),
    fallbackCredentials: credentials ?? _FakeCredentialAccess(),
    probeTransportFactory: probeTransportFactory,
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
