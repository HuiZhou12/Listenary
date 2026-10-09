import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';
import 'package:sqlite3/sqlite3.dart';

/// 借变量构造出一个与常量 ref 值相等、但不是同一实例的对象，
/// 用来验证判定按值相等而不是按对象身份。
PlatformTrackRef _ref(MusicPlatform platform, String trackId) =>
    PlatformTrackRef(platform: platform, trackId: trackId);

void main() {
  const current = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: 'current',
  );
  const other = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: 'other',
  );

  test('remote active highlights a track whose ref is value-equal', () {
    final nowPlaying = _ref(MusicPlatform.netease, 'current');
    expect(identical(nowPlaying, current), isFalse);
    expect(
      resolveOnlineTrackFocus(
        activeSource: ActivePlaybackSessionSource.remote,
        remoteNowPlayingRef: nowPlaying,
        trackRef: current,
      ),
      isTrue,
    );
    expect(
      resolveOnlineTrackFocus(
        activeSource: ActivePlaybackSessionSource.remote,
        remoteNowPlayingRef: current,
        trackRef: other,
      ),
      isFalse,
    );
  });

  test('ref equality includes the platform', () {
    expect(
      resolveOnlineTrackFocus(
        activeSource: ActivePlaybackSessionSource.remote,
        remoteNowPlayingRef: _ref(MusicPlatform.qq, 'current'),
        trackRef: current,
      ),
      isFalse,
    );
  });

  test('non-remote sources and missing playback state suppress highlight', () {
    for (final source in const [
      ActivePlaybackSessionSource.local,
      ActivePlaybackSessionSource.inactive,
      null,
    ]) {
      expect(
        resolveOnlineTrackFocus(
          activeSource: source,
          remoteNowPlayingRef: current,
          trackRef: current,
        ),
        isFalse,
      );
    }
    expect(
      resolveOnlineTrackFocus(
        activeSource: ActivePlaybackSessionSource.remote,
        remoteNowPlayingRef: null,
        trackRef: current,
      ),
      isFalse,
    );
  });

  // ---------------------------------------------------------------- 接线
  //
  // 上面几条只测了**纯函数**。纯函数全绿、接线断掉，用户看到的是"高亮从来没出现过"。
  // 下面这条把 provider 按**与应用完全一样的方式**注册（非空类型），走真实接线。

  testWidgets('★ 正在播放的在线曲目真的会高亮（接线，不只是纯函数）', (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    final repository = OnlineLibraryRepository(database);
    final favorites = PersonalOnlinePlaylistController(
      repository: SynchronousFuture(repository),
    );
    addTearDown(favorites.dispose);
    addTearDown(database.dispose);

    final session = ActivePlaybackSession();
    final queue = RemotePlaybackQueue();
    addTearDown(session.dispose);
    addTearDown(queue.dispose);

    final nowPlaying = MusicTrack(
      ref: current,
      title: '正在播放的歌',
      artists: const ['甲'],
      album: '专辑一',
    );
    final otherTrack = MusicTrack(
      ref: other,
      title: '别的歌',
      artists: const ['甲'],
      album: '专辑一',
    );

    queue.replace([
      RemotePlaybackQueueItem(
        ref: current,
        title: nowPlaying.title,
        artists: nowPlaying.artists,
        album: nowPlaying.album,
      ),
    ], currentIndex: 0);
    session.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: const [
        ActivePlaybackSessionItem(title: '正在播放的歌', artist: '甲'),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: false,
        canPause: true,
        canPrevious: false,
        canNext: false,
        canSeek: false,
      ),
    );

    Future<void> pumpFor(MusicTrack track) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            // **与 entry.dart:689/692 完全一致**：注册成非空类型。
            ChangeNotifierProvider<ActivePlaybackSession>.value(value: session),
            ChangeNotifierProvider<RemotePlaybackQueue>.value(value: queue),
            ChangeNotifierProvider<PersonalOnlinePlaylistController>.value(
              value: favorites,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: OnlineTrackEntry(track: track, onTap: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpFor(nowPlaying);
    final playingRow = tester.widget<OnlineTrackRow>(
      find.byType(OnlineTrackRow),
    );
    expect(
      playingRow.isNowPlaying,
      isTrue,
      reason: '当前远程播放的曲目必须被判为"正在播放"',
    );
    // 高亮必须是**用户看得见**的差别，不只是字段为 true。
    final scheme = Theme.of(
      tester.element(find.byType(OnlineTrackRow)),
    ).colorScheme;
    final playingTitleColor = tester
        .widget<Text>(find.text('正在播放的歌'))
        .style
        ?.color;
    expect(playingTitleColor, scheme.primary);

    // 对照组：不是当前曲目的行不高亮。
    await pumpFor(otherTrack);
    final otherRow = tester.widget<OnlineTrackRow>(find.byType(OnlineTrackRow));
    expect(otherRow.isNowPlaying, isFalse);
    expect(tester.widget<Text>(find.text('别的歌')).style?.color, isNot(scheme.primary));
  });
}
