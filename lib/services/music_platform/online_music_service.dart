import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';

final class OnlineMusicCapabilities {
  OnlineMusicCapabilities({
    required Iterable<MusicPlatform> searchablePlatforms,
    required Iterable<MusicPlatform> resolvablePlatforms,
  }) : searchablePlatforms = Set.unmodifiable(searchablePlatforms),
       resolvablePlatforms = Set.unmodifiable(resolvablePlatforms);

  final Set<MusicPlatform> searchablePlatforms;
  final Set<MusicPlatform> resolvablePlatforms;
}

abstract interface class OnlineMusicService {
  OnlineMusicCapabilities get capabilities;

  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  });

  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  });

  String defaultQualityFor(MusicPlatform platform);

  void dispose();
}
