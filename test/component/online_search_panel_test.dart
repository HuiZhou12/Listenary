import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_panel.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

/// 在线搜索**面板**的 widget 测试。
///
/// 由 `test/page/online_music_page_test.dart` 迁移而来（页面 2026-11-03 撤销，D2）：
/// 面板不再自带输入框 ⇒ `_pumpPanel` 直接注入 `query`，提交走
/// `GlobalKey<OnlineSearchPanelState>.submit`（Spec §5.4.2 的选定方案），
/// 原来"输入后点「在线搜索」"的动作在这里是"调一次 `handle.submit()`"。
/// 页面级断言（`find.text('在线音乐')` 标题等）已删除 —— 标题归搜索弹窗的 frame。
void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  testWidgets('opens online history from the panel header', (tester) async {
    var requested = false;
    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) async => _page(const []),
      onHistoryRequested: () => requested = true,
    );

    await tester.tap(find.byTooltip('在线播放历史'));
    await tester.pump();

    expect(requested, isTrue);
  });

  testWidgets('searches inline only after explicit submit', (tester) async {
    final calls = <_SearchCall>[];
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) async {
      calls.add(_SearchCall(keyword, limit, offset, cancelToken));
      return _page([_track('1', title: 'Explicit Result')]);
    }

    await _pumpPanel(tester, search: search);

    expect(find.text('在线搜索'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      '  测试搜索  ',
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(calls, isEmpty);

    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.keyword, '测试搜索');
    expect(calls.single.limit, 30);
    expect(calls.single.offset, 0);
    expect(find.text('Explicit Result'), findsOneWidget);
    // 详情行现在是**分段渲染**（艺人 / 专辑各一段 + 中间的分隔符）⇒ 逐段断言 ✓
    // （比原来找整串 "艺人 · 专辑" 更强：分段错了也抓得到 ✓）。
    expect(find.text('Test Artist'), findsOneWidget);
    expect(find.text('Test Album'), findsOneWidget);
    // 2026-10-12：平台标识**并进了同一条详情文本**（读起来是 `歌手 · 专辑 · 平台` ✓）⇒
    // 分隔符从 1 个变成 2 个 ✓（艺人↔专辑、专辑↔平台）。平台不再是行尾的独立徽章 ✓。
    expect(find.text(' · '), findsNWidgets(2));
    expect(find.text('2:03'), findsOneWidget);
  });

  testWidgets('search result row adds a track to a personal playlist', (
    tester,
  ) async {
    final database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    final repository = OnlineLibraryRepository(database);
    final controller = PersonalOnlinePlaylistController(
      repository: Future.value(repository),
    );
    addTearDown(controller.dispose);
    addTearDown(database.dispose);
    final targetId = repository.createPersonalPlaylist('目标歌单');

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: _PanelHost(
              search:
                  ({
                    required keyword,
                    required limit,
                    required offset,
                    required cancelToken,
                  }) async => _page([_track('1', title: 'Explicit Result')]),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      '测试',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();

    expect(find.text('Explicit Result'), findsOneWidget);

    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.moveTo(tester.getCenter(find.text('Explicit Result')));
    await tester.pump();
    await tester.tap(find.byTooltip('添加到歌单'));
    await tester.pumpAndSettle();

    expect(find.text('收藏到歌单'), findsOneWidget);

    // **这条断言是本轮补上的**：原先只断言弹窗出现，可这条测试的名字承诺的是
    // "adds a track to a personal playlist"。弹窗出现而回调没接上时，
    // 用户看到的过程完全一样 —— 名字承诺的事必须真被验证。
    await tester.tap(find.text('目标歌单'));
    await tester.pumpAndSettle();
    expect(
      repository.readPersonalPlaylist(targetId)!.tracks.map((t) => t.title),
      contains('Explicit Result'),
    );
    await hover.removePointer();
  });

  testWidgets('renders result cover without a music-note placeholder', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) async => _page([
            _track(
              '1',
              title: 'Covered Result',
              coverUri: Uri.parse('https://cover.invalid/result.jpg'),
            ),
          ]),
    );

    await _submit(tester, 'cover');

    expect(find.byKey(const ValueKey('online-track-cover-1')), findsOneWidget);
    final cover = tester.widget<RemoteMediaCover>(
      find.descendant(
        of: find.byKey(const ValueKey('online-track-cover-1')),
        matching: find.byType(RemoteMediaCover),
      ),
    );
    expect(cover.coverUri, Uri.parse('https://cover.invalid/result.jpg'));
  });

  testWidgets('enter submits and playable result preserves current page', (
    tester,
  ) async {
    final result = _page([
      _track('1', title: 'Playable'),
      _track('2', title: 'Paid', availability: TrackAvailability.paid),
    ]);
    MusicSearchPage? selectedPage;
    MusicTrack? selectedTrack;
    var requestCount = 0;

    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) async {
            requestCount++;
            return result;
          },
      onTrackSelected: (page, track) async {
        selectedPage = page;
        selectedTrack = track;
      },
    );

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'enter query',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(requestCount, 1);
    final paidRow = tester.widget<OnlineTrackRow>(
      find.ancestor(
        of: find.text('Paid'),
        matching: find.byType(OnlineTrackRow),
      ),
    );
    expect(paidRow.enabled, isFalse);

    await tester.tap(find.text('Playable'));
    await tester.pump();

    expect(selectedPage, same(result));
    expect(selectedTrack?.ref.trackId, '1');
  });

  testWidgets('new submission cancels and ignores the previous request', (
    tester,
  ) async {
    final firstResponse = Completer<MusicSearchPage>();
    final secondResponse = Completer<MusicSearchPage>();
    final calls = <_SearchCall>[];

    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) {
            calls.add(_SearchCall(keyword, limit, offset, cancelToken));
            return keyword == 'first'
                ? firstResponse.future
                : secondResponse.future;
          },
    );

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'first',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pump();
    expect(find.text('正在搜索'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'second',
    );
    await tester.pump();
    expect(calls.single.cancelToken.isCancelled, isTrue);

    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pump();
    secondResponse.complete(_page([_track('2', title: 'Second Result')]));
    await tester.pumpAndSettle();
    expect(find.text('Second Result'), findsOneWidget);

    firstResponse.complete(_page([_track('1', title: 'Stale Result')]));
    await tester.pumpAndSettle();
    expect(find.text('Second Result'), findsOneWidget);
    expect(find.text('Stale Result'), findsNothing);
  });

  testWidgets('disposal cancels an active request', (tester) async {
    final response = Completer<MusicSearchPage>();
    OnlineMusicCancelToken? token;
    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) {
            token = cancelToken;
            return response.future;
          },
    );

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'dispose',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    // 不 pumpAndSettle：在途请求不会完成，加载态里的进度条是无限动画。
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    expect(token?.isCancelled, isTrue);
    response.complete(_page([_track('1', title: 'Ignored')]));
    await tester.pump();
  });

  testWidgets('shows empty, retryable, and unauthorized states', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) async => _page(const []),
    );
    await _submit(tester, 'empty');
    expect(find.text('没有找到在线曲目'), findsOneWidget);
    expect(find.text('重新搜索'), findsOneWidget);

    var attempts = 0;
    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) async {
            attempts++;
            if (attempts == 1) {
              throw const OnlineMusicException(
                kind: OnlineMusicErrorKind.network,
                safeMessage: '网络请求失败，请稍后重试',
              );
            }
            return _page([_track('1', title: 'Retry Result')]);
          },
    );
    await _submit(tester, 'retry');
    expect(find.text('网络请求失败，请稍后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('Retry Result'), findsOneWidget);

    await _pumpPanel(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) {
            throw const OnlineMusicException(
              kind: OnlineMusicErrorKind.notConfigured,
              safeMessage: '请先配置有效的 ChKSz API Key',
            );
          },
    );
    await _submit(tester, 'unauthorized');
    expect(find.text('请先配置有效的 ChKSz API Key'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
  });

  testWidgets('keeps query and results across parent rebuild', (tester) async {
    var requestCount = 0;
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) async {
      requestCount++;
      return _page([_track('1', title: 'Persistent Result')]);
    }

    final handle = await _pumpPanel(tester, search: search);
    await _submit(tester, 'persistent query');

    // 父级重建（同一 state 保留）⇒ 不重新发请求，结果还在。
    handle.rebuild();
    await tester.pumpAndSettle();

    expect(requestCount, 1);
    expect(find.text('Persistent Result'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('online-search-field')))
          .controller
          ?.text,
      'persistent query',
    );
  });

  testWidgets('pagination appends the next page with offset = loaded count', (
    tester,
  ) async {
    final calls = <_SearchCall>[];
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) async {
      calls.add(_SearchCall(keyword, limit, offset, cancelToken));
      if (offset == 0) {
        return _page(_tracks(0, 30), offset: 0, limit: 30, total: 60);
      }
      return _page(_tracks(30, 30), offset: 30, limit: 30, total: 60);
    }

    await _pumpPanel(tester, size: const Size(1200, 5000), search: search);
    await _submit(tester, 'page');

    // 首请求参数不变：limit 30 / offset 0
    expect(calls, hasLength(1));
    expect(calls.single.keyword, 'page');
    expect(calls.single.limit, 30);
    expect(calls.single.offset, 0);
    expect(find.text('Track p0'), findsOneWidget);
    expect(find.text('Track p30'), findsNothing);
    expect(_loadMoreButton, findsOneWidget);
    expect(find.text('没有更多了'), findsNothing);

    await tester.tap(_loadMoreButton);
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(calls[1].keyword, 'page');
    expect(calls[1].limit, 30);
    expect(calls[1].offset, 30);
    // 追加而不是替换，原有顺序保留
    expect(find.text('Track p0'), findsOneWidget);
    expect(find.text('Track p30'), findsOneWidget);
    expect(find.text('Track p59'), findsOneWidget);
    expect(find.byType(OnlineTrackRow), findsNWidgets(60));
    // 已加载 60 == total 60，已到底
    expect(_loadMoreButton, findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('pagination dedupes by ref and queues every loaded result', (
    tester,
  ) async {
    MusicSearchPage? queuedPage;
    MusicTrack? selectedTrack;
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) async {
      if (offset == 0) {
        return _page(_tracks(0, 30), offset: 0, limit: 30, total: 60);
      }
      // 第二页重复最后 3 条，再补 27 条新的
      return _page([
        ..._tracks(27, 3),
        ..._tracks(30, 27),
      ], offset: 30, limit: 30, total: 60);
    }

    await _pumpPanel(
      tester,
      size: const Size(1200, 5000),
      search: search,
      onTrackSelected: (page, track) async {
        queuedPage = page;
        selectedTrack = track;
      },
    );
    await _submit(tester, 'dedupe');
    await tester.tap(_loadMoreButton);
    await tester.pumpAndSettle();

    // 重复的 p27/p28/p29 不追加；60 条去重后为 57 条
    expect(find.byType(OnlineTrackRow), findsNWidgets(57));
    expect(
      find.byKey(const ValueKey('online-track-cover-p27')),
      findsOneWidget,
    );

    await tester.tap(find.text('Track p0'));
    await tester.pump();

    expect(selectedTrack?.ref.trackId, 'p0');
    // 队列 = 已加载的全部结果（顺序不变，无重复）
    expect(queuedPage?.items.map((track) => track.ref.trackId).toList(), [
      for (var i = 0; i < 57; i++) 'p$i',
    ]);
  });

  testWidgets('pagination hides the entry when a page is short of the limit', (
    tester,
  ) async {
    // total 远大于已加载数量，但首请求只返回 10 条：双重判定必须拦住入口
    await _pumpPanel(
      tester,
      size: const Size(1200, 1600),
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) async => _page(_tracks(0, 10), offset: 0, limit: 30, total: 500),
    );
    await _submit(tester, 'short-first');

    expect(find.text('Track p0'), findsOneWidget);
    expect(_loadMoreButton, findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('pagination stops when the last page is shorter than the limit', (
    tester,
  ) async {
    final calls = <_SearchCall>[];
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) async {
      calls.add(_SearchCall(keyword, limit, offset, cancelToken));
      if (offset == 0) {
        return _page(_tracks(0, 30), offset: 0, limit: 30, total: 60);
      }
      return _page(_tracks(30, 5), offset: 30, limit: 30, total: 60);
    }

    await _pumpPanel(tester, size: const Size(1200, 3000), search: search);
    await _submit(tester, 'short-last');
    await tester.tap(_loadMoreButton);
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(find.text('Track p34'), findsOneWidget);
    expect(_loadMoreButton, findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('pagination failure keeps results and stays retryable', (
    tester,
  ) async {
    var moreAttempts = 0;
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) async {
      if (offset == 0) {
        return _page(_tracks(0, 30), offset: 0, limit: 30, total: 60);
      }
      moreAttempts++;
      if (moreAttempts == 1) {
        throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.network,
          safeMessage: '网络请求失败，请稍后重试',
        );
      }
      return _page(_tracks(30, 5), offset: 30, limit: 30, total: 60);
    }

    await _pumpPanel(tester, size: const Size(1200, 3000), search: search);
    await _submit(tester, 'retry-more');
    await tester.tap(_loadMoreButton);
    await tester.pumpAndSettle();

    // 失败：保留已加载结果，只给安全提示（不含签名 URL），入口可重试
    expect(find.text('Track p0'), findsOneWidget);
    expect(find.text('网络请求失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining('http'), findsNothing);
    expect(_loadMoreRetryButton, findsOneWidget);
    expect(_loadMoreButton, findsNothing);

    await tester.tap(_loadMoreRetryButton);
    await tester.pumpAndSettle();

    expect(moreAttempts, 2);
    expect(find.text('Track p30'), findsOneWidget);
    expect(_loadMoreRetryButton, findsNothing);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('a stale pagination response never pollutes a new search', (
    tester,
  ) async {
    final staleMore = Completer<MusicSearchPage>();
    final calls = <_SearchCall>[];
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) {
      calls.add(_SearchCall(keyword, limit, offset, cancelToken));
      if (keyword == 'second') {
        return Future.value(_page([_track('s1', title: 'Second Result')]));
      }
      if (offset == 0) {
        return Future.value(
          _page(_tracks(0, 30), offset: 0, limit: 30, total: 60),
        );
      }
      return staleMore.future;
    }

    await _pumpPanel(tester, size: const Size(1200, 3000), search: search);
    await _submit(tester, 'first');
    await tester.tap(_loadMoreButton);
    await tester.pump();

    expect(calls, hasLength(2));
    expect(calls[1].offset, 30);
    expect(calls[1].cancelToken.isCancelled, isFalse);
    // 入队后不可重复触发：入口退化为加载态
    expect(_loadMoreButton, findsNothing);

    // 改词重新搜索：在途分页请求被取消并作废
    await _submit(tester, 'second');

    expect(calls.last.keyword, 'second');
    expect(calls[1].cancelToken.isCancelled, isTrue);

    staleMore.complete(_page([_track('stale', title: 'Stale More Result')]));
    await tester.pumpAndSettle();

    expect(find.text('Second Result'), findsOneWidget);
    expect(find.text('Stale More Result'), findsNothing);
    expect(find.text('Track p0'), findsNothing);
  });

  testWidgets('editing the query resets accumulated pages', (tester) async {
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    }) async {
      if (offset == 0) {
        return _page(_tracks(0, 30), offset: 0, limit: 30, total: 60);
      }
      return _page(_tracks(30, 5), offset: 30, limit: 30, total: 60);
    }

    await _pumpPanel(tester, size: const Size(1200, 3000), search: search);
    await _submit(tester, 'reset');
    await tester.tap(_loadMoreButton);
    await tester.pumpAndSettle();
    expect(find.text('Track p30'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'reset2',
    );
    await tester.pumpAndSettle();

    expect(find.byType(OnlineTrackRow), findsNothing);
    expect(find.text('Track p0'), findsNothing);
    expect(find.text('没有更多了'), findsNothing);
    expect(find.text('在线搜索'), findsOneWidget);
  });
}

/// 面板的测试宿主：一个输入框把文本交给面板的 `query`，提交走
/// `GlobalKey<OnlineSearchPanelState>.submit`（Spec §5.4.2 的选定方案）。
///
/// 弹窗里这一层由 `SearchDialog` 承担；测试里单独造一个，让面板测试**不依赖弹窗**。
class _PanelHost extends StatefulWidget {
  const _PanelHost({
    super.key,
    required this.search,
    this.onTrackSelected,
    this.onHistoryRequested,
  });

  final OnlineSearchQuery search;
  final Future<void> Function(MusicSearchPage page, MusicTrack selected)?
  onTrackSelected;
  final VoidCallback? onHistoryRequested;

  @override
  State<_PanelHost> createState() => _PanelHostState();
}

class _PanelHostState extends State<_PanelHost> {
  final TextEditingController controller = TextEditingController();
  final GlobalKey<OnlineSearchPanelState> panelKey = GlobalKey();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// 模拟"提交按钮 / Enter"：直接调面板的 `submit`（与弹窗同一条路径）。
  void submit() {
    final query = controller.text;
    final panel = panelKey.currentState;
    if (panel != null) {
      panel.submit(query);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      panelKey.currentState?.submit(query);
    });
  }

  /// 模拟"父级重建"：查询词与已提交状态都不变。
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          key: const ValueKey('online-search-field'),
          controller: controller,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '在线搜索',
                  onPressed: submit,
                  icon: const Icon(Icons.travel_explore),
                ),
              ],
            ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => submit(),
        ),
        Expanded(
          child: OnlineSearchPanel(
            key: panelKey,
            query: controller.text,
            search: widget.search,
            onTrackSelected: widget.onTrackSelected,
            onHistoryRequested: widget.onHistoryRequested,
          ),
        ),
      ],
    );
  }
}

Future<_PanelHostState> _pumpPanel(
  WidgetTester tester, {
  required OnlineSearchQuery search,
  Future<void> Function(MusicSearchPage page, MusicTrack selected)?
  onTrackSelected,
  VoidCallback? onHistoryRequested,
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
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
  final handleKey = GlobalKey<_PanelHostState>();
  await tester.pumpWidget(
    ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
      value: favorites,
      child: MaterialApp(
        home: Scaffold(
          body: _PanelHost(
            key: handleKey,
            search: search,
            onTrackSelected: onTrackSelected,
            onHistoryRequested: onHistoryRequested,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return handleKey.currentState!;
}

MusicSearchPage _page(
  List<MusicTrack> tracks, {
  int offset = 0,
  int limit = 30,
  int? total,
}) => MusicSearchPage(
  platform: MusicPlatform.netease,
  items: tracks,
  offset: offset,
  limit: limit,
  total: total ?? tracks.length,
);

/// 生成 `id` 为 `p$start … p${start + count - 1}` 的连续曲目。
List<MusicTrack> _tracks(int start, int count) => [
  for (var i = start; i < start + count; i++)
    _track('p$i', title: 'Track p$i'),
];

/// 输入关键词并点击搜索按钮，等待首请求完成。
Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('online-search-field')),
    query,
  );
  await tester.pump();
  await tester.tap(find.byTooltip('在线搜索'));
  await tester.pumpAndSettle();
}

Finder get _loadMoreButton =>
    find.byKey(const ValueKey('online-search-load-more'));

Finder get _loadMoreRetryButton =>
    find.byKey(const ValueKey('online-search-load-more-retry'));

MusicTrack _track(
  String id, {
  required String title,
  TrackAvailability availability = TrackAvailability.playable,
  Uri? coverUri,
}) => MusicTrack(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
  title: title,
  artists: const ['Test Artist'],
  album: 'Test Album',
  coverUri: coverUri,
  duration: const Duration(seconds: 123),
  availability: availability,
);

final class _SearchCall {
  const _SearchCall(this.keyword, this.limit, this.offset, this.cancelToken);

  final String keyword;
  final int limit;
  final int offset;
  final OnlineMusicCancelToken cancelToken;
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
