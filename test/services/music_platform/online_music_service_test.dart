import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/services/music_platform/index.dart';

void main() {
  test(
    'a provider-neutral fake can search and resolve a remote stream',
    () async {
      final service = _FakeOnlineMusicService();
      final token = OnlineMusicCancelToken();
      final page = await service.search(
        platform: MusicPlatform.netease,
        keyword: 'test',
        cancelToken: token,
      );

      expect(page.items.single.title, 'Fake Track');
      final stream = await service.resolve(
        page.items.single.ref,
        requestedQuality: service.defaultQualityFor(MusicPlatform.netease),
        cancelToken: token,
      );
      expect(stream.ref, page.items.single.ref);
    },
  );

  test(
    'the generic playback gateway opens through the neutral service',
    () async {
      final service = _FakeOnlineMusicService();
      final backend = _FakeBackend();
      final gateway = OnlineServiceRemoteQueuePlaybackGateway(
        service: service,
        backend: backend,
      );

      final result = await gateway.openWithMetadata(
        _FakeOnlineMusicService.ref,
        requestedQuality: 'standard',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(result.coverUri, Uri.parse('https://cover.invalid/fake.jpg'));
      expect(result.duration, const Duration(minutes: 3));
      expect(backend.sources.single, isA<RemotePlaybackSource>());
    },
  );
}

final class _FakeOnlineMusicService implements OnlineMusicService {
  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended playlists are not implemented here');

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
  static const ref = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: 'fake-1',
  );

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
  }) async => MusicSearchPage(
    platform: platform,
    items: [
      MusicTrack(
        ref: ref,
        title: 'Fake Track',
        artists: const ['Fake Artist'],
        coverUri: Uri.parse('https://cover.invalid/fake.jpg'),
      ),
    ],
  );

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async => ResolvedStream(
    ref: ref,
    uri: Uri.parse('https://media.invalid/fake.mp3'),
    requestedQuality: requestedQuality,
    coverUri: Uri.parse('https://cover.invalid/fake.jpg'),
    resolvedAt: DateTime.utc(2026, 8, 18),
  );

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('playlist');

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
  }) => throw UnsupportedError('lyrics');

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

final class _FakeBackend
    implements PlaybackBackend, DurationReadablePlaybackBackend {
  final sources = <PlaybackSource>[];
  final _states = StreamController<PlaybackBackendState>.broadcast();

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  @override
  Future<void> open(PlaybackSource source) async => sources.add(source);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _states.close();

  @override
  Duration? readDuration() => const Duration(minutes: 3);
}
