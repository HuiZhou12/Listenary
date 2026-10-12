import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/services/music_platform/index.dart';

void main() {
  const firstRef = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: '1',
  );
  const secondRef = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: '2',
  );

  late _FakeOnlineMusicService service;
  late ActivePlaybackSession activeSession;
  late RemotePlaybackQueue queue;
  late RemotePlaybackTimelineController timeline;
  late RemoteLyricController controller;
  late Duration position;

  setUp(() {
    service = _FakeOnlineMusicService();
    activeSession = ActivePlaybackSession();
    queue = RemotePlaybackQueue()
      ..replace([
        RemotePlaybackQueueItem(
          ref: firstRef,
          title: 'First',
          artists: const ['Artist'],
        ),
        RemotePlaybackQueueItem(
          ref: secondRef,
          title: 'Second',
          artists: const ['Artist'],
        ),
      ], currentIndex: 0);
    position = Duration.zero;
    timeline = RemotePlaybackTimelineController(readPosition: () => position);
    timeline.synchronize(
      revision: 1,
      state: PlaybackBackendState.paused,
      duration: const Duration(minutes: 3),
    );
    activeSession.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: const [
        ActivePlaybackSessionItem(title: 'First', artist: 'Artist'),
        ActivePlaybackSessionItem(title: 'Second', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );
    controller = RemoteLyricController(
      service: service,
      activeSession: activeSession,
      queue: queue,
      timeline: timeline,
    );
  });

  tearDown(() {
    controller.dispose();
    timeline.dispose();
    queue.dispose();
    activeSession.dispose();
  });

  test('loads the active track and follows the existing timeline', () async {
    service.complete(firstRef, _lyrics());
    await _flushAsync();

    expect(controller.value.status, RemoteLyricStatus.ready);
    expect(remoteLyricLineContent(controller.value.currentLine!), 'First line');

    position = const Duration(seconds: 6);
    timeline.synchronize(
      revision: 1,
      state: PlaybackBackendState.completed,
      duration: const Duration(minutes: 3),
    );

    expect(
      remoteLyricLineContent(controller.value.currentLine!),
      'Second line',
    );
  });

  test('uses local word timing rules for remote line selection', () {
    final lyric = Lyric([
      SyncLyricLine(const Duration(seconds: 1), const Duration(seconds: 2), [
        SyncLyricWord(
          const Duration(seconds: 1),
          const Duration(seconds: 1),
          'First',
        ),
      ]),
      SyncLyricLine(const Duration(seconds: 4), const Duration(seconds: 2), [
        SyncLyricWord(
          const Duration(seconds: 4),
          const Duration(milliseconds: 500),
          'Second',
        ),
      ]),
    ]);

    expect(
      remoteLyricLineIndexAt(lyric, const Duration(milliseconds: 3679)),
      0,
    );
    expect(
      remoteLyricLineIndexAt(lyric, const Duration(milliseconds: 3680)),
      1,
    );
  });

  test('cancels a stale request and rejects its late result', () async {
    final firstToken = service.tokens.single;
    queue.select(1);

    expect(firstToken.isCancelled, isTrue);
    expect(controller.value.ref, secondRef);
    service.complete(firstRef, _lyrics(first: 'Stale'));
    service.complete(secondRef, _lyrics(first: 'Current'));
    await _flushAsync();

    expect(controller.value.ref, secondRef);
    expect(remoteLyricLineContent(controller.value.currentLine!), 'Current');
  });

  test('clears immediately when local playback becomes active', () async {
    service.complete(firstRef, _lyrics());
    await _flushAsync();

    activeSession.switchTo(
      source: ActivePlaybackSessionSource.local,
      queue: const [
        ActivePlaybackSessionItem(title: 'Local', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );

    expect(controller.value.status, RemoteLyricStatus.inactive);
    expect(controller.value.lyric, isNull);
  });

  test('keeps failed and empty responses as safe empty states', () async {
    service.fail(firstRef);
    await _flushAsync();
    expect(controller.value.status, RemoteLyricStatus.failed);

    queue.select(1);
    service.complete(secondRef, const MusicLyrics());
    await _flushAsync();
    expect(controller.value.status, RemoteLyricStatus.empty);
  });

  // ★ P-63：「这首歌没歌词」与「这个平台不支持歌词」必须是**两种**状态与文案。
  // 以前后者被写成 `empty`，界面上两者都是「暂无歌词」⇒ 用户只会反复换歌，
  // 而播放侧对同一情形给的是明确的 `unavailable`（同一失败两种结论，RC-C）。
  test('★ P-63 平台没有歌词能力 ⇒ platformUnsupported（不是 empty），且不发请求', () async {
    // 开场时控制器已经为队列里的第一项（netease）发过一次请求，因此这里比较**新增**请求数。
    final before = service.requestedRefs.length;
    const qqRef = PlatformTrackRef(platform: MusicPlatform.qq, trackId: '9');
    queue
      ..replace([
        RemotePlaybackQueueItem(
          ref: qqRef,
          title: 'QQ track',
          artists: const ['Artist'],
        ),
      ], currentIndex: 0)
      ..select(0);
    await _flushAsync();

    expect(controller.value.status, RemoteLyricStatus.platformUnsupported);
    expect(controller.value.ref, qqRef);
    expect(
      service.requestedRefs.length,
      before,
      reason: '平台没有歌词能力 ⇒ 闸门直接给出结论，不再发新请求',
    );
  });

  test('★ P-63 对照：平台支持但这首歌没歌词 ⇒ 仍然是 empty', () async {
    service.complete(firstRef, const MusicLyrics());
    await _flushAsync();

    expect(
      controller.value.status,
      RemoteLyricStatus.empty,
      reason: 'P-63：两种情形不得再塌成同一个状态',
    );
    expect(service.requestedRefs, [firstRef]);
  });

  test('★ P-63 占位文案：四种状态四种说法，"没歌词"与"平台不支持"必须不同', () {
    expect(remoteLyricPlaceholderFor(RemoteLyricStatus.loading), contains('加载'));
    expect(remoteLyricPlaceholderFor(RemoteLyricStatus.failed), contains('失败'));

    final empty = remoteLyricPlaceholderFor(RemoteLyricStatus.empty);
    final unsupported = remoteLyricPlaceholderFor(
      RemoteLyricStatus.platformUnsupported,
    );
    expect(empty, '暂无歌词');
    expect(
      unsupported,
      isNot(empty),
      reason: 'P-63：同一失败两种结论是这次要修的缺陷形态',
    );
    expect(unsupported, contains('平台不支持'));
    // 必须给出"为什么换歌没用"的线索，而不是只说"没有歌词"。
    expect(unsupported, contains('Provider'));
  });
}

MusicLyrics _lyrics({String first = 'First line'}) => MusicLyrics(
  parsed: Lrc([
    LrcLine(const Duration(seconds: 1), first, requiredIsBlank: false),
    LrcLine(const Duration(seconds: 5), 'Second line', requiredIsBlank: false),
  ], LyricFormat.web),
);

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeOnlineMusicService implements OnlineMusicService {
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
  final Map<PlatformTrackRef, Completer<MusicLyrics>> _responses = {};
  final List<OnlineMusicCancelToken> tokens = [];

  /// 实际发出过取词请求的曲目（P-63：用来证明"平台不支持"时**不去请求**）。
  final List<PlatformTrackRef> requestedRefs = [];

  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: const [],
    resolvablePlatforms: const [],
    lyricPlatforms: const [MusicPlatform.netease],
  );

  void complete(PlatformTrackRef ref, MusicLyrics lyrics) {
    _responses.putIfAbsent(ref, Completer.new).complete(lyrics);
  }

  void fail(PlatformTrackRef ref) {
    _responses
        .putIfAbsent(ref, Completer.new)
        .completeError(StateError('fail'));
  }

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
  }) {
    requestedRefs.add(ref);
    tokens.add(cancelToken);
    return _responses.putIfAbsent(ref, Completer.new).future;
  }

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('playlist');

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('search');

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('resolve');

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
