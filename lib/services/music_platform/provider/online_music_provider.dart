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

  /// **歌单集合**（歌单列表）：只回答"这个平台有哪些歌单"，**不带曲目**。
  ///
  /// 与 [fetchPlaylist] 是两个业务语义（Spec §19.2）：前者是浏览，后者是打开。
  /// [categoryId] 可选，给定时只返回该分类下的歌单。
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit,
    int offset,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  });

  /// **歌单分类索引**：只回答"平台把歌单分成了哪些类"，**不带歌单**。
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit,
    int offset,
    required OnlineMusicCancelToken cancelToken,
  });

  /// **榜单索引**：只回答"这个平台发布了哪些名次集合"，**不带曲目**。
  ///
  /// 与 [fetchPlaylistCollection] 是两个内容类型；在榜单以歌单形态存在的平台上，
  /// 返回项的 `id` 可直接交给 [fetchPlaylist] 打开（见能力枚举的说明）。
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit,
    int offset,
    required OnlineMusicCancelToken cancelToken,
  });

  /// **新歌**：该平台最近发布的曲目（**输出就是曲目**，复用既有实体）。
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit,
    int offset,
    required OnlineMusicCancelToken cancelToken,
  });

  /// **艺人详情**（`artist`，2026-10-12）：按实体 ID 取"艺人 + 热门曲目"。
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  });

  /// **艺人的专辑列表**（`artistAlbums`，2026-10-12 新增）：只要元数据，**不带曲目** ✓。
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit,
    int offset,
    required OnlineMusicCancelToken cancelToken,
  });

  /// **专辑详情**（`album`，2026-10-12）：按实体 ID 取"专辑元数据 + 曲目"。
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
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
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
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
