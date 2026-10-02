import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/page/online_music_page.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  test('online selection filters explicitly unplayable tracks', () {
    final tracks = [
      _track('1', title: 'Playable'),
      _track('2', title: 'Paid', availability: TrackAvailability.paid),
      _track(
        '3',
        title: 'Unavailable',
        availability: TrackAvailability.unavailable,
      ),
      _track('4', title: 'Unknown', availability: TrackAvailability.unknown),
    ];

    final selection = OnlineTrackSelection.fromResultPage(
      tracks: tracks,
      selectedRef: tracks.last.ref,
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['1', '4']);
    expect(selection.selectedIndex, 1);
  });

  test('history selection preserves visible order and last quality', () {
    final entries = [
      _history('2', quality: 'standard'),
      _history('1', quality: 'lossless'),
    ];

    final selection = OnlineTrackSelection.fromHistory(
      entries: entries,
      selectedRef: entries.last.track.ref,
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['2', '1']);
    expect(selection.selectedIndex, 1);
    expect(selection.requestedQuality, 'lossless');
  });

  test('active matching online identity is reused without a new request', () {
    final ref = _track('1', title: 'Current').ref;

    expect(
      shouldReuseActiveOnlineTrack(
        state: PlaybackBackendState.playing,
        currentRef: ref,
        selectedRef: ref,
      ),
      isTrue,
    );
    expect(
      shouldReuseActiveOnlineTrack(
        state: PlaybackBackendState.failed,
        currentRef: ref,
        selectedRef: ref,
      ),
      isFalse,
    );
  });

  testWidgets('opens online history from the page toolbar', (tester) async {
    var requested = false;
    await _pumpPage(
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

    await _pumpPage(tester, search: search);

    expect(find.text('在线音乐'), findsOneWidget);
    expect(find.byKey(const ValueKey('online-search-field')), findsOneWidget);
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
    expect(find.text('Test Artist · Test Album'), findsOneWidget);
    expect(find.text('2:03'), findsOneWidget);
  });

  testWidgets('search result row adds a track to a personal playlist', (
    tester,
  ) async {
    final database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    final controller = PersonalOnlinePlaylistController(
      repository: Future.value(OnlineLibraryRepository(database)),
    );
    addTearDown(controller.dispose);
    addTearDown(database.dispose);

    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: OnlineMusicPage(
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
    await hover.removePointer();

    expect(find.text('收藏到歌单'), findsOneWidget);
  });

  testWidgets('renders result cover without a music-note placeholder', (
    tester,
  ) async {
    await _pumpPage(
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

    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'cover',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();

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

    await _pumpPage(
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

    await _pumpPage(
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
    await _pumpPage(
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
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    expect(token?.isCancelled, isTrue);
    response.complete(_page([_track('1', title: 'Ignored')]));
    await tester.pump();
  });

  testWidgets('shows empty, retryable, and unauthorized states', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      search:
          ({
            required keyword,
            required limit,
            required offset,
            required cancelToken,
          }) async => _page(const []),
    );
    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'empty',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();
    expect(find.text('没有找到在线曲目'), findsOneWidget);
    expect(find.text('重新搜索'), findsOneWidget);

    var attempts = 0;
    await _pumpPage(
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
    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'retry',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();
    expect(find.text('网络请求失败，请稍后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('Retry Result'), findsOneWidget);

    await _pumpPage(
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
    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'unauthorized',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();
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

    await _pumpPage(tester, search: search);
    await tester.enterText(
      find.byKey(const ValueKey('online-search-field')),
      'persistent query',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();

    await _pumpPage(tester, search: search);

    expect(requestCount, 1);
    expect(find.text('Persistent Result'), findsOneWidget);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('online-search-field')),
    );
    expect(field.controller?.text, 'persistent query');
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

    await _pumpPage(
      tester,
      size: const Size(1200, 5000),
      search: search,
    );
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

    await _pumpPage(
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
    await _pumpPage(
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

    await _pumpPage(tester, size: const Size(1200, 3000), search: search);
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

    await _pumpPage(tester, size: const Size(1200, 3000), search: search);
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

    await _pumpPage(tester, size: const Size(1200, 3000), search: search);
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

    await _pumpPage(tester, size: const Size(1200, 3000), search: search);
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

Future<void> _pumpPage(
  WidgetTester tester, {
  required OnlineMusicSearch search,
  OnlineTrackSelected? onTrackSelected,
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
  await tester.pumpWidget(
    ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
      value: favorites,
      child: MaterialApp(
        home: Scaffold(
          body: OnlineMusicPage(
            search: search,
            onTrackSelected: onTrackSelected,
            onHistoryRequested: onHistoryRequested,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
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

OnlineHistoryEntry _history(String id, {required String quality}) =>
    OnlineHistoryEntry(
      track: _track(id, title: 'History $id'),
      playCount: 1,
      lastPlayedAt: DateTime.utc(2026, 8, 18),
      lastQuality: quality,
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
