import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/page/online_music_page.dart';
import 'package:pure_music/services/music_platform/index.dart';

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

  testWidgets('searches inline only after explicit submit', (tester) async {
    final calls = <_SearchCall>[];
    Future<MusicSearchPage> search({
      required String keyword,
      required int limit,
      required int offset,
      required ChkszCancelToken cancelToken,
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
    expect(find.byIcon(Symbols.music_note), findsNothing);
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
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Paid')).enabled,
      isFalse,
    );

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
    ChkszCancelToken? token;
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
            if (attempts == 1) throw ChkszException.network();
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
            throw const ChkszException(
              kind: ChkszErrorKind.unauthorized,
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
      required ChkszCancelToken cancelToken,
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
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required OnlineMusicSearch search,
  OnlineTrackSelected? onTrackSelected,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: OnlineMusicPage(search: search, onTrackSelected: onTrackSelected),
      ),
    ),
  );
  await tester.pump();
}

MusicSearchPage _page(List<MusicTrack> tracks) => MusicSearchPage(
  platform: MusicPlatform.netease,
  items: tracks,
  offset: 0,
  limit: 30,
  total: tracks.length,
);

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
  final ChkszCancelToken cancelToken;
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
