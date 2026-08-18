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
  final Map<PlatformTrackRef, Completer<MusicLyrics>> _responses = {};
  final List<OnlineMusicCancelToken> tokens = [];

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
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) {
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
  void dispose() {}
}
