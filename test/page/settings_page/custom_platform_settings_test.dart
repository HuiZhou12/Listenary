import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/page/settings_page/online_music_settings.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';

/// decoupling-2.2（R3 / R7）：设置页**能新建自定义平台、能分辨它、且内置平台照旧**。
///
/// 单独成文件（既有 `online_music_settings_test.dart` 已 3000 行，且这些用例全是
/// 2.2 新增语义）。
void main() {
  const alphaId = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const betaId = '0f9a1c2e-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  Future<void> pumpPanel(
    WidgetTester tester,
    OnlineMusicProviderSettingsController controller,
  ) async {
    tester.view.physicalSize = const Size(1200, 5200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final service = createOnlineMusicComposition(
      settings: controller.activeSettings,
      portableBuild: true,
    ).service;
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<
                OnlineMusicProviderSettingsController
              >.value(value: controller),
              Provider<OnlineMusicService>.value(value: service),
            ],
            child: const OnlineMusicSettingsPanel(active: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  OnlineMusicProviderSettingsController controllerWith(
    OnlineMusicSettings settings, {
    OnlineMusicSettings? active,
  }) => OnlineMusicProviderSettingsController(
    activeSettings: active ?? settings,
    store: _MemorySettingsStore(settings),
    fallbackCredentials: _FakeCredentialAccess(),
  );

  /// 两个自定义平台（同展示名 ⇒ 必须附短 ID 才能分辨）。
  OnlineMusicSettings twoCustomPlatforms() => OnlineMusicSettings.fromJson({
    'providers': [
      {
        'id': 'alpha',
        'contentPlatform': 'custom',
        'platformId': alphaId,
        'platformName': '同名平台',
        'baseUrl': 'https://alpha.invalid',
        'auth': {'kind': 'none'},
        'capabilities': <String, Object?>{},
      },
      {
        'id': 'beta',
        'contentPlatform': 'custom',
        'platformId': betaId,
        'platformName': '同名平台',
        'baseUrl': 'https://beta.invalid',
        'auth': {'kind': 'none'},
        'capabilities': <String, Object?>{},
      },
    ],
  });

  testWidgets('★ R3 两个同名自定义平台：条目列表附短 ID 以便区分', (tester) async {
    final controller = controllerWith(twoCustomPlatforms());
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    // 短 ID = platformId 前 8 位。
    expect(find.text('alpha（0f9a1c2e）'), findsOneWidget);
    expect(find.text('beta（0f9a1c2e）'), findsOneWidget);
    // 两个条目的平台展示名相同（允许同名，Spec §0/G6）。
    expect(find.textContaining('同名平台'), findsWidgets);
  });

  testWidgets('★ R3 不同名的自定义平台不附短 ID（不加噪声）', (tester) async {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'alpha',
          'contentPlatform': 'custom',
          'platformId': alphaId,
          'platformName': '我的自建服务',
          'baseUrl': 'https://alpha.invalid',
          'auth': {'kind': 'none'},
          'capabilities': <String, Object?>{},
        },
      ],
    });
    final controller = controllerWith(settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    expect(find.text('alpha'), findsWidgets);
    expect(find.textContaining('（0f9a1c2e）'), findsNothing);
    // 副标题用平台展示名，不再一律「自定义平台」。
    expect(find.textContaining('我的自建服务'), findsWidgets);
  });

  testWidgets('★ R3 平台卡出现自定义平台（含自己的启用开关）', (tester) async {
    final controller = controllerWith(twoCustomPlatforms());
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    // 三个内置平台 + 两个自定义平台 = 5 张卡（每张一个 Switch）。
    expect(
      find.byType(Switch),
      findsNWidgets(builtinMusicPlatforms.length + 2),
    );
    expect(
      find.text('同名平台（0f9a1c2e）'),
      findsNWidgets(2),
      reason: '平台卡同样需要短 ID 才能分辨同名平台',
    );
  });

  testWidgets('★ R3 / R7 内置平台卡标题与数量不变（零回归）', (tester) async {
    final controller = controllerWith(OnlineMusicSettings.defaults);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    for (final platform in builtinMusicPlatforms) {
      expect(find.text(musicPlatformLabel(platform)), findsOneWidget);
    }
    expect(find.byType(Switch), findsNWidgets(builtinMusicPlatforms.length));
    expect(find.textContaining('（0f9a1c2e）'), findsNothing);
  });

  testWidgets('★ R2 / R3 添加对话框：选「自定义平台」后填展示名，保存时带身份', (tester) async {
    final controller = controllerWith(OnlineMusicSettings.defaults);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'customAlpha');
    // 选「自定义平台」分段（新建时可选）。
    await tester.tap(find.text('自定义平台').last);
    await tester.pumpAndSettle();

    // 自动生成了稳定 ID（只读展示）。
    final idField = find.byKey(const ValueKey('online-music-platform-id'));
    expect(idField, findsOneWidget);
    final generated = tester.widget<SelectableText>(idField).data!;
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(generated),
      isTrue,
      reason: 'R2：新建时自动生成标准 UUID v4',
    );

    // 展示名必填。
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请填写平台展示名'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(3), '我的自建平台');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final saved = controller.settings.providerById('customAlpha')!;
    expect(saved.contentPlatform, MusicPlatform.custom);
    expect(saved.platformId, generated);
    expect(saved.platformName, '我的自建平台');
    expect(saved.toJson()['platformId'], generated);
    expect(saved.toJson()['platformName'], '我的自建平台');
  });

  testWidgets('★ R2 编辑既有自定义平台：platformId 原样保留（不可改写）', (tester) async {
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'alpha',
          'contentPlatform': 'custom',
          'platformId': alphaId,
          'platformName': '旧名',
          'baseUrl': 'https://alpha.invalid',
          'auth': {'kind': 'none'},
          'capabilities': <String, Object?>{},
        },
      ],
    });
    final controller = controllerWith(settings);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();

    // 只读展示既有 ID。
    final idField = find.byKey(const ValueKey('online-music-platform-id'));
    expect(tester.widget<SelectableText>(idField).data, alphaId);

    // 改展示名并保存。
    await tester.enterText(find.byType(TextField).at(3), '新名');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final updated = controller.settings.providerById('alpha')!;
    expect(updated.platformId, alphaId, reason: 'R2：编辑不得重写平台身份');
    expect(updated.platformName, '新名');
  });

  testWidgets('★ R7 内置平台条目仍按原样显示（不出现平台 ID 输入）', (tester) async {
    final controller = controllerWith(OnlineMusicSettings.defaults);
    addTearDown(controller.dispose);
    await pumpPanel(tester, controller);

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 默认选中的是网易云 ⇒ 不显示自定义平台的两个字段。
    expect(
      find.byKey(const ValueKey('online-music-platform-id')),
      findsNothing,
    );
    expect(find.text('平台展示名'), findsNothing);
    expect(find.text('平台 ID'), findsNothing);
  });
}

final class _MemorySettingsStore implements OnlineMusicSettingsStore {
  _MemorySettingsStore(this.settings);

  OnlineMusicSettings settings;

  @override
  OnlineMusicSettings read() => settings;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    this.settings = settings;
    return true;
  }
}

final class _FakeCredentialAccess implements OnlineMusicCredentialAccess {
  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => '测试用';

  @override
  bool isValidFormat(String value) => value.trim().isNotEmpty;

  @override
  Future<bool> isConfigured(String reference) async => false;

  @override
  Future<void> save(String reference, String value) async {}

  @override
  Future<void> clear(String reference) async {}
}
