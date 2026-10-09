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
    expect(find.text('响应'), findsOneWidget);
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
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请求路径不能为空'), findsOneWidget);
    expect(find.text('请求'), findsOneWidget);
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

  testWidgets('平台卡：该平台没有支持某能力的条目时显示"未配置"', (tester) async {
    final controller = _controller();
    await pumpPanel(tester, controller);

    // 默认只有一个 netease 条目：QQ / 酷狗的所有能力都没有候选。
    expect(
      find.text('未配置：该平台下没有支持此能力的条目'),
      findsNWidgets(2 * OnlineMusicCapability.values.length),
    );
    expect(
      find.descendant(
        of: platformCard(MusicPlatform.kugou),
        matching: find.text('未配置：该平台下没有支持此能力的条目'),
      ),
      findsNWidgets(OnlineMusicCapability.values.length),
    );
    controller.dispose();
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
  Future<void> addHeaderRow(WidgetTester tester, String name) async {
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
}

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
  int probeCalls = 0;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    probeCalls++;
    return const DeclarativeHttpResponse(
      statusCode: 200,
      data: {
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
    saved[reference] = value;
  }

  @override
  Future<void> clear(String reference) async => saved.remove(reference);

  /// F0-5 迁移需要"写后立即回读"，所以这个假件同时当读取口。
  @override
  Future<String?> readCredential(String reference) async => saved[reference];
}
