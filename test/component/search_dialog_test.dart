import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/services/music_platform/index.dart';

const _apiKey = 'chksz_TEST_ONLY';

void main() {
  setUpAll(() {
    HotKeyManagerPlatform.instance = _FakeHotKeyManager();
  });

  testWidgets('online input does not request until explicitly submitted', (
    tester,
  ) async {
    final transport = _RecordingTransport(
      (_, _) async => _searchResponse(title: 'Explicit Result'),
    );
    final runtime = _runtime(transport);
    addTearDown(runtime.dispose);
    await _pumpDialog(tester, runtime);

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '测试搜索');
    await tester.pump(const Duration(milliseconds: 600));

    expect(transport.requests, isEmpty);

    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();

    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.path, '/api/163_search');
    expect(transport.requests.single.queryParameters, {
      'keyword': '测试搜索',
      'limit': '30',
      'offset': '0',
      'apikey': _apiKey,
    });
    expect(find.text('Explicit Result'), findsOneWidget);
  });

  testWidgets('online entry opens online tab without requesting', (
    tester,
  ) async {
    final transport = _RecordingTransport(
      (_, _) async => _searchResponse(title: 'Unexpected Result'),
    );
    final runtime = _runtime(transport);
    addTearDown(runtime.dispose);
    await _pumpDialog(tester, runtime, initialOnline: true);

    final searchField = tester.widget<TextField>(find.byType(TextField));
    expect(searchField.decoration?.hintText, '搜索网易音乐');
    expect(transport.requests, isEmpty);
  });

  test('online selection filters explicitly unplayable tracks', () {
    final tracks = [
      _track('1', TrackAvailability.playable),
      _track('2', TrackAvailability.paid),
      _track('3', TrackAvailability.unavailable),
      _track('4', TrackAvailability.unknown),
    ];

    final selection = OnlineTrackSelection.fromResultPage(
      tracks: tracks,
      selectedRef: tracks.last.ref,
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['1', '4']);
    expect(selection.selectedIndex, 1);
  });

  testWidgets('enter submits and selected result preserves stable reference', (
    tester,
  ) async {
    final transport = _RecordingTransport(
      (_, _) async => _searchResponse(title: 'Selected Result'),
    );
    final runtime = _runtime(transport);
    addTearDown(runtime.dispose);
    OnlineTrackSelection? selected;
    await _pumpDialog(
      tester,
      runtime,
      onOnlineTrackSelected: (track) => selected = track,
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'enter query');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Selected Result'), findsOneWidget);
    expect(find.text('Test Artist · Test Album'), findsOneWidget);
    expect(find.text('2:03'), findsOneWidget);

    await tester.tap(find.text('Selected Result'));
    expect(
      selected?.selectedTrack.ref,
      const PlatformTrackRef(
        platform: MusicPlatform.netease,
        trackId: '123456',
      ),
    );
    expect(selected?.tracks, hasLength(1));
    expect(selected?.selectedIndex, 0);
  });

  testWidgets('selection keeps the playable current result page and index', (
    tester,
  ) async {
    final transport = _RecordingTransport(
      (_, _) async => _searchResponse(
        items: [
          _song(id: 1, title: 'First'),
          _song(id: 2, title: 'Second'),
          _song(id: 3, title: 'Third'),
        ],
      ),
    );
    final runtime = _runtime(transport);
    addTearDown(runtime.dispose);
    OnlineTrackSelection? selected;
    await _pumpDialog(
      tester,
      runtime,
      onOnlineTrackSelected: (selection) => selected = selection,
    );

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'page');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second'));

    expect(selected?.tracks.map((track) => track.ref.trackId), ['1', '2', '3']);
    expect(selected?.selectedIndex, 1);
  });

  testWidgets('shows empty and safe unauthorized states', (tester) async {
    final emptyTransport = _RecordingTransport(
      (_, _) async => _searchResponse(items: const []),
    );
    final emptyRuntime = _runtime(emptyTransport);
    addTearDown(emptyRuntime.dispose);
    await _pumpDialog(tester, emptyRuntime);

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'empty');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();
    expect(find.text('没有找到在线曲目'), findsOneWidget);
    expect(find.text('重新搜索'), findsOneWidget);

    final unauthorizedTransport = _RecordingTransport(
      (_, _) => throw StateError('must not request without a key'),
    );
    final unauthorizedRuntime = ChkszRuntime(
      credentialProvider: InMemoryChkszCredentialProvider(),
      transport: unauthorizedTransport,
    );
    addTearDown(unauthorizedRuntime.dispose);
    await _pumpDialog(tester, unauthorizedRuntime);

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'unauthorized');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pumpAndSettle();

    expect(find.text('请先配置有效的 ChKSz API Key'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(unauthorizedTransport.requests, isEmpty);
  });

  testWidgets('new submission cancels and ignores the previous request', (
    tester,
  ) async {
    final firstResponse = Completer<ChkszTransportResponse>();
    final secondResponse = Completer<ChkszTransportResponse>();
    final transport = _RecordingTransport((request, _) {
      return request.queryParameters['keyword'] == 'first'
          ? firstResponse.future
          : secondResponse.future;
    });
    final runtime = _runtime(transport);
    addTearDown(runtime.dispose);
    await _pumpDialog(tester, runtime);

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'first');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'second');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pump();

    expect(transport.tokens, hasLength(2));
    expect(transport.tokens.first.isCancelled, isTrue);

    secondResponse.complete(_searchResponse(title: 'Second Result'));
    await tester.pumpAndSettle();
    expect(find.text('Second Result'), findsOneWidget);

    firstResponse.complete(_searchResponse(title: 'Stale Result'));
    await tester.pumpAndSettle();
    expect(find.text('Second Result'), findsOneWidget);
    expect(find.text('Stale Result'), findsNothing);
  });

  testWidgets('leaving online view and disposing cancel active requests', (
    tester,
  ) async {
    final responses = <Completer<ChkszTransportResponse>>[];
    final transport = _RecordingTransport((_, _) {
      final response = Completer<ChkszTransportResponse>();
      responses.add(response);
      return response.future;
    });
    final runtime = _runtime(transport);
    addTearDown(runtime.dispose);
    await _pumpDialog(tester, runtime);

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'leave');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pump();
    await tester.tap(find.text('音乐'));
    await tester.pump();
    expect(transport.tokens.first.isCancelled, isTrue);
    responses.first.complete(_searchResponse(title: 'Ignored After Leave'));
    await tester.pump();

    await tester.tap(find.text('在线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dispose');
    await tester.pump();
    await tester.tap(find.byTooltip('在线搜索'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(transport.tokens.last.isCancelled, isTrue);
    responses.last.complete(_searchResponse(title: 'Ignored After Dispose'));
    await tester.pump();
  });

  testWidgets('local categories remain local and do not use transport', (
    tester,
  ) async {
    final transport = _RecordingTransport(
      (_, _) => throw StateError('local search must not use ChKSz'),
    );
    final runtime = _runtime(transport);
    addTearDown(runtime.dispose);
    await _pumpDialog(tester, runtime);

    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    await tester.tap(find.text('艺术家'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();

    expect(transport.requests, isEmpty);
  });
}

Future<void> _pumpDialog(
  WidgetTester tester,
  ChkszRuntime runtime, {
  ValueChanged<OnlineTrackSelection>? onOnlineTrackSelected,
  bool initialOnline = false,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Provider<ChkszRuntime>.value(
          value: runtime,
          child: SearchDialog(
            onOnlineTrackSelected: onOnlineTrackSelected,
            initialOnline: initialOnline,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Map<String, Object?> _song({required int id, required String title}) => {
  'id': id,
  'name': title,
  'artists': 'Test Artist',
  'album': 'Test Album',
  'picUrl': null,
  'duration': 123456,
};

MusicTrack _track(String id, TrackAvailability availability) => MusicTrack(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
  title: 'Track $id',
  artists: const ['Artist'],
  availability: availability,
);

ChkszRuntime _runtime(_RecordingTransport transport) => ChkszRuntime(
  credentialProvider: InMemoryChkszCredentialProvider(initialApiKey: _apiKey),
  transport: transport,
);

ChkszTransportResponse _searchResponse({
  String title = 'Test Track',
  List<Map<String, Object?>>? items,
}) {
  final songs =
      items ??
      [
        {
          'id': 123456,
          'name': title,
          'artists': 'Test Artist',
          'album': 'Test Album',
          'picUrl': null,
          'duration': 123456,
        },
      ];
  return ChkszTransportResponse(
    statusCode: 200,
    data: {
      'code': 200,
      'msg': 'success',
      'data': {'songs': songs, 'total': songs.length},
    },
  );
}

typedef _TransportHandler =
    Future<ChkszTransportResponse> Function(
      ChkszAuthorizedRequest request,
      ChkszCancelToken cancelToken,
    );

final class _RecordingTransport implements ChkszTransport {
  _RecordingTransport(this.handler);

  final _TransportHandler handler;
  final List<ChkszAuthorizedRequest> requests = [];
  final List<ChkszCancelToken> tokens = [];

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) {
    requests.add(request);
    tokens.add(cancelToken);
    return handler(request, cancelToken);
  }
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
