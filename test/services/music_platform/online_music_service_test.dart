import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/services/music_platform/index.dart';

void main() {
  test('a provider-neutral fake can search and resolve a remote stream', () async {
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
  });

  test('the generic playback gateway opens through the neutral service', () async {
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
    expect(backend.sources.single, isA<RemotePlaybackSource>());
  });
}

final class _FakeOnlineMusicService implements OnlineMusicService {
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
  String defaultQualityFor(MusicPlatform platform) => 'standard';

  @override
  void dispose() {}
}

final class _FakeBackend implements PlaybackBackend {
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
}
