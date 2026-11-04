import 'dart:async';

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

/// 搜索弹窗的**来源切换状态机**（Spec §5.2 的每一行一个用例）+ D3 / D6。
///
/// 与 `search_dialog_test.dart` 分开：那个文件守"本地分支零行为改动"，
/// 本文件守"来源切换与在线分支"。
void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  testWidgets('switching to online keeps the query and searches immediately', (
    tester,
  ) async {
    final calls = <String>[];
    await _pumpDialog(
      tester,
      service: _SearchService(
        onSearch: (keyword) async {
          calls.add(keyword);
          return _page([_track('1', 'Online Result')]);
        },
      ),
    );

    await tester.enterText(find.byType(TextField), '  关键字  ');
    await tester.pump();

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();

    // 同一个 controller ⇒ 查询词不丢；切过去立刻按**归一化**后的词搜一次。
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '  关键字  ',
    );
    expect(calls, ['关键字']);
    expect(find.text('Online Result'), findsOneWidget);
    // 在线来源的提示文案换了。
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration?.hintText,
      '搜索在线音乐',
    );
  });

  testWidgets('switching back to local searches immediately without debounce', (
    tester,
  ) async {
    await _pumpDialog(
      tester,
      service: _SearchService(
        onSearch: (keyword) async => _page([_track('1', 'Online Result')]),
      ),
    );

    await tester.enterText(find.byType(TextField), 'query');
    await tester.pump();
    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    expect(find.text('Online Result'), findsOneWidget);

    await tester.tap(find.text('本地'));
    await tester.pump();

    // 本地分支：立刻出结果（不等 450ms debounce），且回到本地三档 tab。
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('Online Result'), findsNothing);
  });

  testWidgets('online typing does not search until explicit submit', (
    tester,
  ) async {
    final calls = <String>[];
    await _pumpDialog(
      tester,
      service: _SearchService(
        onSearch: (keyword) async {
          calls.add(keyword);
          return _page([_track('1', 'Explicit Result')]);
        },
      ),
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await tester.enterText(find.byType(TextField), 'typed');
    await tester.pump(const Duration(milliseconds: 600));
    // I2：在线分支**不**边打边搜（每次击键会打满全部平台）。
    expect(calls, isEmpty);

    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();
    expect(calls, ['typed']);

    // 再改词：结果被标记为过期并清空，但仍不自动搜。
    await tester.enterText(find.byType(TextField), 'typed2');
    await tester.pumpAndSettle();
    expect(find.text('Explicit Result'), findsNothing);
    expect(calls, hasLength(1));
  });

  testWidgets('enter submits in the online source', (tester) async {
    final calls = <String>[];
    await _pumpDialog(
      tester,
      service: _SearchService(
        onSearch: (keyword) async {
          calls.add(keyword);
          return _page([_track('1', 'Enter Result')]);
        },
      ),
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'enter');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(calls, ['enter']);
    expect(find.text('Enter Result'), findsOneWidget);
  });

  testWidgets('without any searchable platform online is inert and guides', (
    tester,
  ) async {
    await _pumpDialog(tester, service: _SearchService(searchable: const []));

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();

    // I3：不切换来源 ⇒ 仍是本地三档 tab。
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    // 但**必须给引导**（不能"点了没反应"）。
    expect(find.text('还没有可搜索的在线平台'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
  });

  testWidgets('guide to settings closes the dialog and lands on settings', (
    tester,
  ) async {
    await _pumpDialogWithRouter(
      tester,
      service: _SearchService(searchable: const []),
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去设置'));
    await tester.pumpAndSettle();

    // I4：弹窗（含引导）必须先关，否则会盖住目标页。
    expect(find.byType(SearchDialog), findsNothing);
    expect(find.text('还没有可搜索的在线平台'), findsNothing);
    expect(find.text('stub:${app_paths.SETTINGS_PAGE}'), findsOneWidget);
  });

  testWidgets('closing the dialog cancels in-flight online requests', (
    tester,
  ) async {
    final pending = Completer<MusicSearchPage>();
    OnlineMusicCancelToken? token;
    await _pumpDialog(
      tester,
      service: _SearchService(
        onSearch: (keyword) => pending.future,
        onToken: (value) => token = value,
      ),
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'inflight');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pump();
    expect(token, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(token?.isCancelled, isTrue);
    pending.complete(_page([_track('1', 'Ignored')]));
    await tester.pump();
  });

  testWidgets('a freshly built panel still receives the source-switch submit', (
    tester,
  ) async {
    // 这条钉住 GlobalKey 提交路径的必要性：**面板是在切来源那一帧才被新建的**
    //（本地分支没有它）⇒ 任何"递增一个参数让面板自己发现变化"的机制都收不到这一次提交
    //（`didUpdateWidget` 在首次 build 前根本不会跑）。只有宿主直接调方法才行。
    final calls = <String>[];
    await _pumpDialog(
      tester,
      service: _SearchService(
        onSearch: (keyword) async {
          calls.add(keyword);
          return _page([_track('1', 'Fresh Panel Result')]);
        },
      ),
    );

    // 切到在线**之前**先有词，且此时面板还不存在（本地分支）。
    await tester.enterText(find.byType(TextField), 'fresh');
    await tester.pump();
    expect(find.text('Fresh Panel Result'), findsNothing);

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();

    // 面板首次出现就完成了提交，并拿到结果。
    expect(calls, ['fresh']);
    expect(find.text('Fresh Panel Result'), findsOneWidget);
  });

  testWidgets('the online branch keeps the play-history entry (D6)', (
    tester,
  ) async {
    final router = await _pumpDialogWithRouter(
      tester,
      service: _SearchService(),
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();

    // D6：撤销 `/online` 页后，「在线播放历史」入口在弹窗在线分支顶部重建。
    expect(find.byTooltip('在线播放历史'), findsOneWidget);
    // 打开在线分支**不应**触发路由变化（弹窗只是切来源）。
    expect(router.state.uri.toString(), app_paths.EXPLORE_PAGE);
  });

  testWidgets('dialog loads favorites once for the first online frame', (
    tester,
  ) async {
    final database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    final repository = OnlineLibraryRepository(database);
    // 预置一条收藏：弹窗若在首帧调了 `loadFavorites`，这条就会变成"已收藏"。
    repository.toggleFavorite(_track('fav-1', 'Favorited'));
    final favorites = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
    addTearDown(favorites.dispose);
    addTearDown(database.dispose);
    // 前提：控制器**还没**加载过收藏（否则下面的断言证明不了任何事）。
    expect(favorites.isFavorite(_ref('fav-1')), isFalse);

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: favorites,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: SearchDialog())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 弹窗成为在线行的唯一宿主 ⇒ 打开时就要把收藏状态取好（爱心不该是空的）。
    expect(favorites.isFavorite(_ref('fav-1')), isTrue);
  });
}

/// 单平台搜索注入用替身：给出 [onSearch] 即可（弹窗内注入单平台链路）。
///
/// ⚠️ [searchable] 为空时**必须**同时让 `searchablePlatforms` 也为空：
/// `OnlineMusicCapabilities` 在 `searchableIdentities` 为空时会**从枚举推导**回来，
/// 只清身份不清枚举的话，D3 的"未启用任何平台"根本构造不出来。
final class _SearchService implements OnlineMusicService {
  _SearchService({
    Future<MusicSearchPage> Function(String keyword)? onSearch,
    void Function(OnlineMusicCancelToken token)? onToken,
    Iterable<PlatformIdentity> searchable = const [
      PlatformIdentity.builtin(MusicPlatform.netease),
    ],
  }) : _onSearch = onSearch,
       _onToken = onToken,
       capabilities = OnlineMusicCapabilities(
         searchablePlatforms: searchable.isEmpty
             ? const []
             : const [MusicPlatform.netease],
         resolvablePlatforms: const [],
         // D3 的判据就是这一项：空表 ⇒「在线」置灰。
         searchableIdentities: searchable,
       );

  final Future<MusicSearchPage> Function(String keyword)? _onSearch;
  final void Function(OnlineMusicCancelToken token)? _onToken;

  @override
  final OnlineMusicCapabilities capabilities;

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    _onToken?.call(cancelToken);
    final handler = _onSearch;
    if (handler == null) {
      return MusicSearchPage(platform: platform, items: const []);
    }
    return handler(keyword);
  }

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    _onToken?.call(cancelToken);
    final handler = _onSearch;
    if (handler == null) {
      return AggregatedSearchResult(perPlatform: const {}, failures: const {});
    }
    final page = await handler(keyword);
    return AggregatedSearchResult(
      perPlatform: {page.platform: page},
      failures: const {},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('这个测试用不到：${invocation.memberName}');
}

MusicSearchPage _page(List<MusicTrack> tracks) => MusicSearchPage(
  platform: MusicPlatform.netease,
  items: tracks,
  offset: 0,
  limit: 30,
  total: tracks.length,
);

MusicTrack _track(String id, String title) => MusicTrack(
  ref: _ref(id),
  title: title,
  artists: const ['Test Artist'],
  album: 'Test Album',
);

PlatformTrackRef _ref(String id) =>
    PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

/// 打开弹窗（无路由）：本地来源，可注入单平台搜索替身。
Future<void> _pumpDialog(
  WidgetTester tester, {
  OnlineMusicService? service,
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
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
          value: favorites,
        ),
        if (service != null) Provider<OnlineMusicService>.value(value: service),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Center(child: SearchDialog())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 打开弹窗（**带路由**）：用于"跳设置页"与"当前位置不变"这类路由断言。
///
/// 弹窗挂在 root navigator 上，路由壳在它下面 ⇒ 弹窗内 `GoRouter.maybeOf` 能拿到
/// 同一个 router（"跳设置页前先关自己"正依赖这一点）。
Future<GoRouter> _pumpDialogWithRouter(
  WidgetTester tester, {
  OnlineMusicService? service,
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
            builder: (innerContext) => Center(
              child: ElevatedButton(
                onPressed: () => SearchDialog.show(innerContext),
                child: const Text('打开搜索'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: app_paths.SETTINGS_PAGE,
        builder: (context, state) => const _SettingsStub(),
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
        if (service != null) Provider<OnlineMusicService>.value(value: service),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开搜索'));
  await tester.pumpAndSettle();
  return router;
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

/// 设置页占位：只用来证明"弹窗已关、落到了设置页"。
class _SettingsStub extends StatelessWidget {
  const _SettingsStub();

  static const String _label = 'stub:${app_paths.SETTINGS_PAGE}';

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text(_label));
}