import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

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
}
