import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

/// 一个具名的在线音乐 Provider。
///
/// Provider 自己声明服务哪些能力、每个能力支持哪些音乐来源、每个能力需要什么认证；
/// 因此「能力选择」与「认证配置」彼此正交，业务能力也不再与某个具体 Provider 绑定。
abstract interface class OnlineMusicProvider {
  String get providerId;

  /// 该 Provider 对这个能力支持的音乐来源；空集合表示不支持该能力。
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability);

  /// 该 Provider 对这个能力的认证要求。
  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability);

  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit,
    int offset,
    required OnlineMusicCancelToken cancelToken,
  });

  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  });

  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  });

  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  });

  String defaultQualityFor(MusicPlatform platform);

  /// 该平台在这家 Provider 下的**音质档位声明**（D2:A / D10b:a，静态声明）。
  ///
  /// - 返回空列表表示"没有声明档位" ⇒ 内部偏好档位**原样透传**给该平台，
  ///   行为与引入档位模型之前一致；
  /// - 声明后，UI 用档位里的 `displayLabel`（**平台自己的文案**）渲染选择菜单，
  ///   并把内部偏好按 [selectPlatformQuality] 解析成该平台的 `requestValue`。
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  void dispose();
}

/// 只实现部分能力的 Provider 的基类；未覆写的能力统一报「不可用」。
abstract class UnsupportedOnlineMusicProvider implements OnlineMusicProvider {
  const UnsupportedOnlineMusicProvider();

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) => const {};

  @override
  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability) =>
      const OnlineMusicNoAuth();

  /// 默认不声明档位：内部偏好档位原样透传给该平台（行为与引入档位模型之前一致）。
  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  String defaultQualityFor(MusicPlatform platform) =>
      MusicQuality.lossless.level;

  @override
  void dispose() {}
}

/// 供 Provider 实现抛出的统一「不支持该能力」错误。
OnlineMusicException unsupportedCapability() => const OnlineMusicException(
  kind: OnlineMusicErrorKind.unavailable,
  safeMessage: '当前在线服务不支持该音乐来源',
);
