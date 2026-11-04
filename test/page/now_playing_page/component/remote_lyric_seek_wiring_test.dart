// 视图级接线测试：在线歌词行点击 → `seekLyricLineFromUi` → 时间轴 seek 预期。
//
// 覆盖三件事（对应 Spec `docs/specs/lyric-click-seek-2026-11-04.md` 的 T7/T8/T9）：
// 1. 远程可跳时：行可点，点击把 `line.start` 换算成秒后提交，并给时间轴一个 seek 预期；
// 2. 提交失败时：放弃预期 + 按真实位置重采样 ⇒ 当前行不跳；
// 3. `opening`（流还不可跳）时：行不可点（`onTap == null`）。
//
// 这里不测渲染/分组/布局：本包不动那些代码，断言也不该漂移到那里。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/lyrics_line_widget.dart';
import 'package:pure_music/page/now_playing_page/component/remote_vertical_lyric_view.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/services/music_platform/index.dart';

void main() {
  // 三行歌词：2s / 10s / 20s。点击第 2 行应提交 10s。
  final positions = <Duration>[
    const Duration(seconds: 2),
    const Duration(seconds: 10),
    const Duration(seconds: 20),
  ];
  const lineContents = ['First line', 'Second line', 'Third line'];

  late ActivePlaybackSession session;
  late RemotePlaybackQueue queue;
  late RemotePlaybackTimelineController timeline;
  late RemoteLyricController lyrics;
  late Duration backendPosition;
  late _Harness harness;

  setUp(() {
    backendPosition = const Duration(seconds: 2);
    harness = _Harness();
    session = ActivePlaybackSession();
    const ref = PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: 'remote-1',
    );
    queue = RemotePlaybackQueue()
      ..replace([
        RemotePlaybackQueueItem(
          ref: ref,
          title: 'Remote',
          artists: const ['Artist'],
        ),
      ], currentIndex: 0);
    timeline = RemotePlaybackTimelineController(
      readPosition: () => backendPosition,
    );
    lyrics = RemoteLyricController(
      service: _RemoteLyricService(positions, lineContents),
      activeSession: session,
      queue: queue,
      timeline: timeline,
    );
  });

  tearDown(() {
    lyrics.dispose();
    timeline.dispose();
    queue.dispose();
    session.dispose();
    PlayService.instance.clearRemotePlaybackControlHandlers();
    harness.dispose();
  });

  Future<void> pumpView(
    WidgetTester tester, {
    required PlaybackBackendState backendState,
  }) async {
    harness.bind(backendState);
    session.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: const [
        ActivePlaybackSessionItem(title: 'Remote', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );
    timeline.synchronize(
      revision: 1,
      state: backendState,
      duration: const Duration(minutes: 3),
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: session),
          ChangeNotifierProvider.value(value: lyrics),
          ChangeNotifierProvider.value(value: timeline),
        ],
        child: const MaterialApp(
          home: Scaffold(body: RemoteVerticalLyricView(showControls: false)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('remote seekable state makes lines tappable and reports line start', (
    tester,
  ) async {
    await pumpView(tester, backendState: PlaybackBackendState.paused);

    final lineWidgets = tester
        .widgetList<LyricsLineWidget>(find.byType(LyricsLineWidget))
        .toList();
    expect(lineWidgets, isNotEmpty);
    // 可跳状态下每一行都带 onTap（说明门禁已开）。
    expect(lineWidgets.every((widget) => widget.onTap != null), isTrue);

    // 点第 2 行（10s）。歌词是 CustomPaint 绘制的，只能按行组件定位。
    harness.seekResult = true;
    await tester.tap(find.byType(LyricsLineWidget).at(1));
    await tester.pump();

    // 秒数换算与本地歌词视图一致：行起点毫秒 / 1000。
    expect(harness.seekSeconds, [10.0]);
    // 提交前先给时间轴一个 seek 预期，成功后不会出现"先回跳再前进"。
    expect(timeline.value.position, positions[1]);
  });

  testWidgets('failed lyric seek rolls the timeline back so the line does not jump', (
    tester,
  ) async {
    await pumpView(tester, backendState: PlaybackBackendState.paused);
    final before = timeline.value.position;
    expect(before, positions[0]);

    harness.seekResult = false;
    await tester.tap(find.byType(LyricsLineWidget).at(2));
    await tester.pump();
    await tester.pump();

    expect(harness.seekSeconds, [20.0]);
    // 跳转失败：放弃 seek 预期并按后端真实位置重采样 ⇒ 时间轴回到跳转前，
    // 当前行与视口因此留在原处（视图不写任何回滚滚动代码）。
    expect(timeline.value.position, before);
    expect(timeline.isSeekGuardActive, isFalse);
  });

  testWidgets('opening state keeps lyric lines unclickable', (tester) async {
    await pumpView(tester, backendState: PlaybackBackendState.opening);

    final lineWidgets = tester
        .widgetList<LyricsLineWidget>(find.byType(LyricsLineWidget))
        .toList();
    expect(lineWidgets, isNotEmpty);
    expect(lineWidgets.every((widget) => widget.onTap == null), isTrue);

    await tester.tap(find.byType(LyricsLineWidget).at(1));
    await tester.pump();
    expect(harness.seekSeconds, isEmpty);
  });
}

/// 通过真实的 `PlayService` 装配远程控制链路，避免测试自己模拟服务层行为。
final class _Harness {
  final StreamController<RemotePlaybackControlState> _states =
      StreamController<RemotePlaybackControlState>.broadcast();
  final List<double> seekSeconds = [];
  bool seekResult = true;

  void bind(PlaybackBackendState state) {
    PlayService.instance.setRemotePlaybackControlHandlers(
      initialState: _State(state),
      stateStream: _states.stream,
      isActive: () => true,
      pause: () => true,
      resume: () => true,
      seek: (position) async {
        seekSeconds.add(position.inMicroseconds / Duration.microsecondsPerSecond);
        return seekResult;
      },
    );
  }

  void dispose() {
    _states.close();
  }
}

final class _State implements RemotePlaybackControlState {
  const _State(this.state);

  @override
  final PlaybackBackendState state;

  @override
  bool get controlInFlight => false;

  @override
  bool get isActive => true;
}

final class _RemoteLyricService implements OnlineMusicService {
  _RemoteLyricService(this.positions, this.contents);

  final List<Duration> positions;
  final List<String> contents;

  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
    lyricPlatforms: const [MusicPlatform.netease],
  );

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) async => MusicLyrics(
    parsed: Lrc([
      for (var index = 0; index < positions.length; index++)
        LrcLine(
          positions[index],
          contents[index],
          requiredIsBlank: false,
          length: const Duration(seconds: 4),
        ),
    ], LyricFormat.web),
  );

  @override
  Future<List<RemotePlaylistSummary>> fetchPersonalizedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<OnlineArtistSummary>> fetchFollowedArtists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

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
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('not implemented');

  @override
  String defaultQualityFor(MusicPlatform platform) => 'standard';

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
