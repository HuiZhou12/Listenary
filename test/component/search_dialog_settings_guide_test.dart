import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

/// 「去设置」的两条路径都要**显式关掉弹窗**（Spec I4 / F6）。
///
/// 为什么单独钉：弹窗挂在 root navigator 上，只让面板 `context.go('/settings')`
/// 的话设置页会在下面渲染、弹窗仍盖在上面 —— 用户看到的是"点了没反应"。
/// 这两条用例都断言"弹窗真的没了 + 真的落到了设置页"，而不只是"路由变了"。
void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  testWidgets('未启用平台时引导里的「去设置」⇒ 关弹窗并落到 /settings', (tester) async {
    // 从**本地**来源打开（默认）：这样点「在线」才会走"没有平台 ⇒ 弹引导"分支。
    final router = await _pumpApp(
      tester,
      service: _Service(searchable: false),
      initialSource: SearchSource.local,
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();

    // 引导对话框（不是面板内的空态）：没有可搜索平台 ⇒ 不切换来源（I3）。
    expect(find.text('还没有可搜索的在线平台'), findsOneWidget);
    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();

    expect(find.byType(SearchDialog), findsNothing);
    expect(find.text('还没有可搜索的在线平台'), findsNothing);
    expect(find.text(_settingsLabel), findsOneWidget);
    expect(router.state.uri.toString(), app_paths.SETTINGS_PAGE);
  });

  testWidgets('面板内「没有可搜索的平台」空态的「去设置」⇒ 同样先关弹窗', (tester) async {
    // 有平台身份（能切到在线），但服务在**提交时**才发现一个都搜不了
    // ⇒ 落到面板自己的 `noPlatform` 空态（另一条「去设置」路径）。
    final router = await _pumpApp(tester, service: _Service(searchable: false));

    // 打开时就进在线来源（`initialSource`），跳过引导 ⇒ 直接走面板的空态分支。
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // 必须先真的落到"没有可搜索的平台"空态，否则下面的点击断言毫无意义。
    expect(find.text('没有可搜索的平台'), findsOneWidget);

    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();

    expect(find.byType(SearchDialog), findsNothing);
    expect(find.text(_settingsLabel), findsOneWidget);
    expect(router.state.uri.toString(), app_paths.SETTINGS_PAGE);
  });
}

/// 设置页占位的文案（写常量以便被 const 引用）。
const _settingsLabel = 'stub:${app_paths.SETTINGS_PAGE}';

Future<GoRouter> _pumpApp(
  WidgetTester tester, {
  required OnlineMusicService service,
  SearchSource initialSource = SearchSource.online,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final database = sqlite3.openInMemory();
  initializeAppDatabase(database);
  final favorites = PersonalOnlinePlaylistController(
    repository: SynchronousFuture(OnlineLibraryRepository(database)),
  );
  addTearDown(favorites.dispose);
  addTearDown(database.dispose);

  final router = GoRouter(
    initialLocation: app_paths.EXPLORE_PAGE,
    routes: [
      GoRoute(
        path: app_paths.EXPLORE_PAGE,
        builder: (context, state) => Scaffold(
          body: Builder(
            builder: (inner) => Center(
              child: ElevatedButton(
                onPressed: () => SearchDialog.show(
                  inner,
                  initialSource: initialSource,
                ),
                child: const Text('打开搜索'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: app_paths.SETTINGS_PAGE,
        builder: (context, state) => const Scaffold(body: Text(_settingsLabel)),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
          value: favorites,
        ),
        Provider<OnlineMusicService>.value(value: service),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开搜索'));
  await tester.pumpAndSettle();
  return router;
}

/// 可搜索平台集合可配的空服务（用来构造"未启用/搜不了"两种空态）。
final class _Service implements OnlineMusicService {
  _Service({required bool searchable})
    : capabilities = OnlineMusicCapabilities(
        // 身份表为空时枚举也必须为空，否则能力类会把身份推导回来。
        searchablePlatforms: searchable
            ? const [MusicPlatform.netease]
            : const [],
        resolvablePlatforms: const [],
        searchableIdentities: searchable
            ? const [PlatformIdentity.builtin(MusicPlatform.netease)]
            : const [],
      );

  @override
  final OnlineMusicCapabilities capabilities;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}

final class _FakeHotKeyManager extends HotKeyManagerPlatform {
  @override
  Stream<Map<Object?, Object?>> get onKeyEventReceiver => const Stream.empty();

  @override
  Future<void> register(HotKey hotKey) async {}

  @override
  Future<void> unregister(HotKey hotKey) async {}

  @override
  Future<void> unregisterAll() async {}
}
