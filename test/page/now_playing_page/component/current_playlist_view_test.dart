import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_source_label.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/now_playing_page/component/current_playlist_view.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/index.dart';

void main() {
  late _Harness harness;

  setUp(() => harness = _Harness());
  tearDown(() => harness.dispose());

  /// 起播测试的宿主：挂上**胶水需要的三样**（队列、播放会话控制器、在线服务），
  /// 并接上应用根部的两个全局 key —— 后者是**断言 Toast 的前提**
  /// （不接 `showTextOnSnackBar` 会静默不渲染，`findsNothing` 就永远是绿的）。
  /// 返回一个位于这些 provider 之下的 context。
  Future<BuildContext> pumpLauncher(WidgetTester tester) async {
    late BuildContext launchContext;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RemotePlaybackQueue>.value(value: harness.queue),
          Provider<RemotePlaybackSessionController>.value(
            value: harness.remoteController,
          ),
          Provider<OnlineMusicService>.value(value: _OnlineService()),
        ],
        child: MaterialApp(
          navigatorKey: routerKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          home: Builder(
            builder: (context) {
              launchContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return launchContext;
  }

  MusicTrack launchTrack(String id) => MusicTrack(
    ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
    title: 'Track $id',
    artists: const ['Artist'],
  );

  testWidgets('inactive without a local player shows an empty queue', (
    tester,
  ) async {
    harness.queue.clear();
    await tester.pumpWidget(harness.app());

    expect(find.text('播放队列还是空的'), findsOneWidget);
    expect(find.byType(SegmentedButton), findsNothing);
    expect(PlayService.instance.existingPlaybackService, isNull);
  });

  testWidgets('hides the source switcher when only remote has items', (
    tester,
  ) async {
    await tester.pumpWidget(harness.app());

    // 只有远程队列有内容：不显示本地/在线切换器，直接展示远程队列。
    expect(find.byType(SegmentedButton), findsNothing);
    expect(find.text('Remote 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inactive remote memory queue remains visible', (tester) async {
    await tester.pumpWidget(harness.app());

    expect(find.text('Remote 1'), findsOneWidget);
    expect(find.text('Remote 2'), findsOneWidget);
    expect(PlayService.instance.existingPlaybackService, isNull);
  });

  testWidgets('remote source has priority without creating a local player', (
    tester,
  ) async {
    harness.showRemote(currentIndex: 0);
    await tester.pumpWidget(harness.app());

    expect(find.text('Remote 1'), findsOneWidget);
    expect(find.text('Remote artist 1 - Remote album 1'), findsOneWidget);
    expect(find.text('Remote 2'), findsOneWidget);
    expect(find.byIcon(Symbols.reorder), findsOneWidget);
    expect(find.byIcon(Symbols.clear_all), findsOneWidget);
    expect(find.byIcon(Symbols.remove_circle_outline), findsNWidgets(2));
    expect(PlayService.instance.existingPlaybackService, isNull);
  });

  testWidgets('★ 在线队列投影时带上来源标记（platform 没有在中途丢掉）', (
    tester,
  ) async {
    harness.showRemote(currentIndex: 0);
    await tester.pumpWidget(harness.app());

    // 队列项本身带 ref；投影成 ActivePlaybackSessionItem 时必须把平台名带上，
    // 否则"这一行来自哪个平台"在播放队列里就断了（Spec §20.2 的既定扩展路径）。
    expect(find.byType(OnlineSourceLabel), findsNWidgets(2));
    expect(find.text('网易云'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('★ 点一行起播：队列换成该页曲目，并从**被点的那一首**开始', (tester) async {
    // 这条测的是**所有在线列表共用的"点了就播"胶水**（`playOnlineTrackSelection`），
    // 它此前没有任何测试 —— 而它是"从发现入口开始播放"这条主路径的唯一出口。
    //
    // 借本文件的 `_Harness`：它已经把队列、播放会话控制器与在线服务都备齐了。
    // （另起一套意味着把 4 个假件再抄一遍 —— R1/R2 反复收敛的就是这种重复。）
    final launchContext = await pumpLauncher(tester);

    final tracks = [
      for (final id in ['a', 'b', 'c'])
        MusicTrack(
          ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: id),
          title: 'Track $id',
          artists: const ['Artist'],
        ),
    ];

    await playOnlineTrackSelection(
      launchContext,
      OnlineTrackSelection(
        tracks: tracks,
        selectedIndex: 1,
        requestedQuality: 'standard',
      ),
    );
    await tester.pumpAndSettle();

    // 队列被换成**这一页**的曲目（不是留着上一次的），顺序保持。
    expect(harness.queue.value.items.map((item) => item.ref.trackId), [
      'a',
      'b',
      'c',
    ]);
    // 当前项就是被点的那一首 —— 列表里的"正在播放"高亮正是按它判定的。
    expect(harness.queue.value.currentIndex, 1);
    // 真的向网关要了**那一首**，并带上指定音质。
    expect(harness.gateway.lastRef?.trackId, 'b');
    expect(harness.gateway.lastQuality, 'standard');
  });

  testWidgets('★ 起播失败：**取消不弹提示**，真失败与未知错误都要弹', (tester) async {
    // 这是 P6 立的规则（"取消不是失败"）在**播放层**的落点。
    // 断言"没有弹提示"必须真的能看见提示才算数 —— 所以这里把应用根部的两个全局 key
    // 接进来（否则 `showTextOnSnackBar` 会静默什么都不做，`findsNothing` 永远是绿的）。
    final launchContext = await pumpLauncher(tester);

    final tracks = [
      MusicTrack(
        ref: const PlatformTrackRef(
          platform: MusicPlatform.netease,
          trackId: 'a',
        ),
        title: 'Track a',
        artists: const ['Artist'],
      ),
    ];
    Future<void> launch() => playOnlineTrackSelection(
      launchContext,
      OnlineTrackSelection(
        tracks: tracks,
        selectedIndex: 0,
        requestedQuality: 'standard',
      ),
    );

    // 取消：**静默**（用户只是切走了/又被别的操作取代了，不该看到红字）。
    harness.gateway.failure = const OnlineMusicException(
      kind: OnlineMusicErrorKind.cancelled,
      safeMessage: '播放请求已取消',
    );
    await launch();
    await tester.pumpAndSettle();
    expect(
      find.text('播放请求已取消'),
      findsNothing,
      reason: '取消不是失败，不能弹提示',
    );
    // 也要排除"被当成通用失败"：兜底分支的文案同样不该出现，
    // 否则这条否定断言会因为"错误走了另一条路"而假绿。
    expect(find.text('无法播放远程曲目'), findsNothing);

    // 真失败：必须有提示（否则用户点了没反应、也不知道为什么）。
    harness.gateway.failure = const OnlineMusicException(
      kind: OnlineMusicErrorKind.unavailable,
      safeMessage: '平台暂时不可用',
    );
    await launch();
    await tester.pumpAndSettle();
    expect(find.text('平台暂时不可用'), findsOneWidget);

    // 未知错误：走兜底分支，同样**必须**有提示（否则用户点了没反应也不知道为什么）。
    // 这是一条**正向**断言：它通过本身就证明提示机制在这里是活的。
    harness.gateway.failure = StateError('boom');
    await launch();
    await tester.pumpAndSettle();
    expect(find.text('无法播放远程曲目'), findsOneWidget);

    // Toast 自带自动消失的 Timer，必须让它跑完（否则框架报 pending timer）。
    harness.gateway.failure = null;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('★ 再点正在播的那一首：**不重新请求流**（否则会从头重播）', (tester) async {
    final launchContext = await pumpLauncher(tester);
    final tracks = [launchTrack('a')];

    Future<void> tapIt() => playOnlineTrackSelection(
      launchContext,
      OnlineTrackSelection(
        tracks: tracks,
        selectedIndex: 0,
        requestedQuality: 'standard',
      ),
    );

    await tapIt();
    await tester.pumpAndSettle();
    expect(harness.gateway.calls, 1);
    expect(harness.queue.value.currentIndex, 0);

    // 同一首再点一次：应被判定为"已经在播这一首"而直接返回。
    // 若这里又去请求一次流，用户看到的就是"点了一下，歌从头发一遍"。
    await tapIt();
    await tester.pumpAndSettle();
    expect(
      harness.gateway.calls,
      1,
      reason: '再点正在播的那一首不该重新解析/请求流',
    );
  });

  testWidgets('local source defaults to the local queue', (tester) async {
    harness.showLocal();
    await tester.pumpWidget(harness.app());

    expect(find.text('Remote 1'), findsNothing);
    expect(find.text('播放队列还是空的'), findsOneWidget);
    expect(PlayService.instance.existingPlaybackService, isNull);
  });

  testWidgets('remote selection uses target index and default quality', (
    tester,
  ) async {
    harness.showRemote(currentIndex: 0);
    await tester.pumpWidget(harness.app());

    await tester.tap(find.text('Remote 1'));
    await tester.pump();
    expect(harness.gateway.calls, 0);

    await tester.tap(find.text('Remote 2'));
    await tester.pump();

    expect(harness.gateway.calls, 1);
    expect(harness.gateway.lastRef, harness.remoteItems[1].ref);
    expect(harness.gateway.lastQuality, 'lossless');
    expect(harness.queue.value.currentIndex, 1);
  });
}

final class _Harness {
  _Harness() {
    queue.replace(remoteItems, currentIndex: 0);
    queueController = RemotePlaybackQueueController(
      queue: queue,
      gateway: gateway,
    );
    remoteController = RemotePlaybackSessionController(
      queue: queue,
      remoteController: queueController,
      localBridge: localBridge,
      backend: backend,
    );
  }

  final activeSession = ActivePlaybackSession();
  final queue = RemotePlaybackQueue();
  final gateway = _Gateway();
  final localBridge = _LocalBridge();
  final backend = _Backend();
  final remoteItems = [_remoteItem(1), _remoteItem(2)];
  late final RemotePlaybackQueueController queueController;
  late final RemotePlaybackSessionController remoteController;

  Widget app() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ActivePlaybackSession>.value(
          value: activeSession,
        ),
        Provider<RemotePlaybackSessionController>.value(
          value: remoteController,
        ),
        ChangeNotifierProvider<RemotePlaybackQueue>.value(value: queue),
        Provider<OnlineMusicService>.value(value: _OnlineService()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 400, child: CurrentPlaylistView()),
        ),
      ),
    );
  }

  void showRemote({required int currentIndex}) {
    _remoteLease = activeSession.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: remoteItems.map(
        (item) => ActivePlaybackSessionItem(
          title: item.title,
          artist: item.artistDisplay,
          album: item.album,
        ),
      ),
      currentIndex: currentIndex,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: false,
        canPause: true,
        canPrevious: false,
        canNext: true,
        canSeek: false,
      ),
    );
  }

  ActivePlaybackSessionLease? _remoteLease;

  void updateRemote({required int currentIndex}) {
    final lease = _remoteLease!;
    activeSession.publish(
      lease,
      queue: remoteItems.map(
        (item) => ActivePlaybackSessionItem(
          title: item.title,
          artist: item.artistDisplay,
          album: item.album,
        ),
      ),
      currentIndex: currentIndex,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: true,
        canPause: false,
        canPrevious: true,
        canNext: false,
        canSeek: false,
      ),
    );
  }

  void releaseRemote() {
    activeSession.release(_remoteLease!);
  }

  void showLocal() {
    activeSession.switchTo(
      source: ActivePlaybackSessionSource.local,
      queue: const [
        ActivePlaybackSessionItem(
          title: 'Local 1',
          artist: 'Local artist 1',
          album: 'Local album 1',
        ),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: true,
        canPause: false,
        canPrevious: true,
        canNext: true,
        canSeek: true,
      ),
    );
  }

  Future<void> dispose() async {
    remoteController.dispose();
    queueController.dispose();
    queue.dispose();
    activeSession.dispose();
    await Future<void>.delayed(Duration.zero);
    await backend.dispose();
  }
}

final class _Gateway implements RemoteQueuePlaybackGateway {
  int calls = 0;
  PlatformTrackRef? lastRef;
  String? lastQuality;

  /// 设了就让 `open` 抛这个错。用来测"起播失败"的分支（取消 vs 真失败）。
  Object? failure;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    calls++;
    lastRef = ref;
    lastQuality = requestedQuality;
    final failure = this.failure;
    if (failure != null) throw failure;
  }
}

final class _OnlineService implements OnlineMusicService {
  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

  @override
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('New albums are not implemented here');
  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist songs are not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist albums are not implemented here');
  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album detail is not implemented here');
  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist detail is not implemented here');
  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: [MusicPlatform.netease],
    resolvablePlatforms: [MusicPlatform.netease],
  );

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnimplementedError();

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnimplementedError();

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnimplementedError();

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('categories');

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('charts');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('new songs');

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnimplementedError();

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(perPlatform: const {}, failures: const {});

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
  }) => PlatformQualitySelection(
    requestValue: preference,
    displayLabel: preference,
    internalLevel: preference,
  );

  @override
  void dispose() {}
}

final class _LocalBridge implements LocalPlaybackSessionBridge {
  final _listeners = <void Function()>{};

  @override
  void addLocalPlaybackRequestListener(void Function() listener) {
    _listeners.add(listener);
  }

  @override
  LocalPlaybackResumePoint? capture() => null;

  @override
  void pause() {}

  @override
  void removeLocalPlaybackRequestListener(void Function() listener) {
    _listeners.remove(listener);
  }

  @override
  void restore(LocalPlaybackResumePoint resumePoint) {}
}

final class _Backend implements ControllablePlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast(sync: true);

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<void> open(PlaybackSource source) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}
}

RemotePlaybackQueueItem _remoteItem(int id) {
  return RemotePlaybackQueueItem(
    ref: PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: 'remote-$id',
    ),
    title: 'Remote $id',
    artists: ['Remote artist $id'],
    album: 'Remote album $id',
  );
}
