import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/page/now_playing_page/component/active_lyric_region.dart';
import 'package:pure_music/page/now_playing_page/page.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_lyric_controller.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/services/music_platform/index.dart';

void main() {
  testWidgets('remote lyric region hides the local lyric child', (tester) async {
    final session = ActivePlaybackSession();
    const ref = PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: 'remote-1',
    );
    final queue = RemotePlaybackQueue()
      ..replace([
        RemotePlaybackQueueItem(
          ref: ref,
          title: 'Remote',
          artists: const ['Artist'],
        ),
      ], currentIndex: 0);
    final timeline = RemotePlaybackTimelineController(
      readPosition: () => const Duration(seconds: 1),
    )..synchronize(
      revision: 1,
      state: PlaybackBackendState.paused,
      duration: const Duration(minutes: 3),
    );
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
    final lyrics = RemoteLyricController(
      service: _RemoteLyricService(),
      activeSession: session,
      queue: queue,
      timeline: timeline,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: session),
          ChangeNotifierProvider.value(value: lyrics),
        ],
        child: const MaterialApp(
          home: ActiveNowPlayingLyricRegion(
            localChild: Text('local lyric must stay hidden'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Remote lyric line'), findsOneWidget);
    expect(find.text('local lyric must stay hidden'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    lyrics.dispose();
    timeline.dispose();
    queue.dispose();
    session.dispose();
  });

  test('local-only actions reject remote and inactive sessions', () {
    expect(
      shouldShowLocalNowPlayingActions(
        ActivePlaybackSessionSnapshot.inactive(revision: 1),
      ),
      isFalse,
    );
    expect(
      shouldShowLocalNowPlayingActions(
        _snapshot(ActivePlaybackSessionSource.remote),
      ),
      isFalse,
    );
    expect(
      shouldShowLocalNowPlayingActions(
        _snapshot(ActivePlaybackSessionSource.local),
      ),
      isTrue,
    );
  });
}

ActivePlaybackSessionSnapshot _snapshot(ActivePlaybackSessionSource source) =>
    ActivePlaybackSessionSnapshot.active(
      revision: 1,
      source: source,
      queue: const [
        ActivePlaybackSessionItem(title: 'Track', artist: 'Artist'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: ActivePlaybackSessionCapabilities.none,
    );

final class _RemoteLyricService implements OnlineMusicService {
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
      LrcLine(
        const Duration(seconds: 1),
        'Remote lyric line',
        requiredIsBlank: false,
        length: const Duration(seconds: 4),
      ),
    ], LyricFormat.web),
  );

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('playlist');

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('resolve');

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('search');

  @override
  String defaultQualityFor(MusicPlatform platform) => 'standard';

  @override
  void dispose() {}
}
