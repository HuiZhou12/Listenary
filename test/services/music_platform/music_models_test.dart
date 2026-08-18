import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

void main() {
  test('platform track refs provide stable value equality', () {
    const first = PlatformTrackRef(
      platform: MusicPlatform.qq,
      trackId: 'track-id',
    );
    const same = PlatformTrackRef(
      platform: MusicPlatform.qq,
      trackId: 'track-id',
    );
    const different = PlatformTrackRef(
      platform: MusicPlatform.kugou,
      trackId: 'track-id',
    );

    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(different));
  });

  test('domain model collections are immutable', () {
    final artists = <String>['Artist'];
    final qualityHints = <String, String>{'quality': 'lossless'};
    final track = MusicTrack(
      ref: const PlatformTrackRef(
        platform: MusicPlatform.netease,
        trackId: '1',
      ),
      title: 'Title',
      artists: artists,
      rawQualityHints: qualityHints,
    );
    final page = MusicSearchPage(
      platform: MusicPlatform.netease,
      items: [track],
    );

    artists.add('Later artist');
    qualityHints['format'] = 'flac';

    expect(track.artists, ['Artist']);
    expect(track.rawQualityHints, {'quality': 'lossless'});
    expect(() => track.artists.add('Blocked'), throwsUnsupportedError);
    expect(
      () => track.rawQualityHints['format'] = 'mp3',
      throwsUnsupportedError,
    );
    expect(() => page.items.clear(), throwsUnsupportedError);
  });

  test('resolved stream expiry remains explicit and in memory', () {
    final expiresAt = DateTime.utc(2026, 8, 14, 12);
    final stream = ResolvedStream(
      ref: const PlatformTrackRef(platform: MusicPlatform.kugou, trackId: '2'),
      uri: Uri.parse('https://media.invalid/song'),
      requestedQuality: 'flac',
      resolvedAt: expiresAt.subtract(const Duration(minutes: 5)),
      expiresAt: expiresAt,
    );

    expect(stream.isExpiredAt(expiresAt), isTrue);
    expect(
      stream.isExpiredAt(expiresAt.subtract(const Duration(microseconds: 1))),
      isFalse,
    );
  });
}
