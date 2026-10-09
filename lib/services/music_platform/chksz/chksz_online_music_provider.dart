import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';
import 'package:pure_music/services/music_platform/provider/online_music_quality_tiers.dart';

/// ChkSz 作为「一个 Provider」的实现。
///
/// 它只声明自己服务的能力、平台与认证要求；能力选择由注册与选择层决定，
/// 因此同一份实现可以按不同连接/认证配置注册成多个条目。
final class ChkszOnlineMusicProvider
    implements OnlineMusicProvider, OnlineMusicCredentialController {
  ChkszOnlineMusicProvider({
    required ChkszRuntime runtime,
    this.providerId = defaultOnlineMusicProviderId,
    Map<OnlineMusicCapability, Set<MusicPlatform>>? platforms,
  }) : _runtime = runtime,
       _platforms = platforms ?? _defaultPlatforms;

  static const Map<OnlineMusicCapability, Set<MusicPlatform>>
  _defaultPlatforms = {
    OnlineMusicCapability.search: {MusicPlatform.netease},
    OnlineMusicCapability.playlist: {MusicPlatform.netease},
    OnlineMusicCapability.lyric: {MusicPlatform.netease},
    OnlineMusicCapability.stream: {MusicPlatform.netease},
  };

  final ChkszRuntime _runtime;
  final Map<OnlineMusicCapability, Set<MusicPlatform>> _platforms;

  @override
  final String providerId;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _platforms[capability] ?? const {};

  @override
  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability) =>
      _runtime.authFor(capability);

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    _ensurePlatform(platform, OnlineMusicCapability.search);
    try {
      return await _runtime.search(
        keyword: keyword,
        limit: limit,
        offset: offset,
        cancelToken: cancelToken,
      );
    } catch (error) {
      throw _mapError(error);
    }
  }

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    _ensurePlatform(ref.platform, OnlineMusicCapability.stream);
    try {
      return await _runtime.resolve(
        ref,
        requestedQuality: requestedQuality,
        cancelToken: cancelToken,
      );
    } catch (error) {
      throw _mapError(error);
    }
  }

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    _ensurePlatform(platform, OnlineMusicCapability.playlist);
    try {
      return await _runtime.fetchPlaylist(
        playlistId: playlistId,
        cancelToken: cancelToken,
      );
    } catch (error) {
      throw _mapError(error);
    }
  }

  /// ChkSz 这条链路在当前契约里**没有**歌单集合（歌单列表）接口。
  ///
  /// 这里刻意**不猜路径**：不声明该能力就是"不支持"，由平台卡与能力配置如实呈现；
  /// 需要浏览歌单集合时，用户可以声明式配置一个真正支持它的服务。
  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  /// 同理：ChkSz 这条链路也没有分类索引接口，不猜路径。
  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();

  /// ChkSz 这条链路在当前契约里同样**没有**榜单索引接口。
  ///
  /// 与歌单集合一样刻意**不猜路径**：不声明该能力就是"不支持"。
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
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    _ensurePlatform(ref.platform, OnlineMusicCapability.lyric);
    try {
      return await _runtime.fetchLyrics(ref: ref, cancelToken: cancelToken);
    } catch (error) {
      throw _mapError(error);
    }
  }

  @override
  String defaultQualityFor(MusicPlatform platform) {
    _ensurePlatform(platform, OnlineMusicCapability.stream);
    return AppPreference.instance.defaultQuality;
  }

  /// 网易云档位：7 档，文案与请求值都来自 [MusicQuality]。
  ///
  /// 之所以要显式声明而不是留空：留空表示"不声明档位"，UI 就只能拿内部键当文案；
  /// 而内置 ChkSz 的档位就是网易云的那 7 档，声明的结果与今天完全一致（行为不变）。
  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) =>
      platformsFor(OnlineMusicCapability.stream).contains(platform)
      ? neteaseQualityTiers
      : const [];

  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'chksz_...';

  @override
  bool isCredentialFormatValid(String value) => isValidChkszApiKeyFormat(value);

  @override
  Future<bool> isConfigured() async {
    try {
      return await _runtime.readApiKey() != null;
    } catch (error) {
      throw _mapCredentialError(error, OnlineMusicCredentialOperation.read);
    }
  }

  @override
  Future<void> saveCredential(String value) async {
    // 该 Provider 声明了 auth.kind = none：没有凭据槽位可写，
    // 直接给出可读原因，而不是让底层存储报一个误导性的写入失败。
    if (!_runtime.hasCredentialSource) {
      throw const OnlineMusicCredentialException(
        operation: OnlineMusicCredentialOperation.save,
        safeMessage: '当前在线音乐服务不需要 API Key',
      );
    }
    try {
      await _runtime.writeApiKey(value);
    } catch (error) {
      throw _mapCredentialError(error, OnlineMusicCredentialOperation.save);
    }
  }

  @override
  Future<void> clearCredential() async {
    try {
      await _runtime.clearApiKey();
    } catch (error) {
      throw _mapCredentialError(error, OnlineMusicCredentialOperation.clear);
    }
  }

  @override
  void dispose() => _runtime.dispose();

  void _ensurePlatform(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    if (!platformsFor(capability).contains(platform)) {
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.unavailable,
        safeMessage: '当前在线服务不支持该音乐来源',
      );
    }
  }

  OnlineMusicException _mapError(Object error) {
    if (error is! ChkszException) {
      return const OnlineMusicException(
        kind: OnlineMusicErrorKind.unknown,
        safeMessage: '音乐服务请求失败',
      );
    }
    final kind = switch (error.kind) {
      ChkszErrorKind.badRequest => OnlineMusicErrorKind.badRequest,
      ChkszErrorKind.unauthorized => OnlineMusicErrorKind.notConfigured,
      ChkszErrorKind.quotaExhausted => OnlineMusicErrorKind.quotaExhausted,
      ChkszErrorKind.forbidden => OnlineMusicErrorKind.forbidden,
      ChkszErrorKind.notFound => OnlineMusicErrorKind.notFound,
      ChkszErrorKind.rateLimited => OnlineMusicErrorKind.rateLimited,
      ChkszErrorKind.unavailable => OnlineMusicErrorKind.unavailable,
      ChkszErrorKind.businessFailure => OnlineMusicErrorKind.businessFailure,
      ChkszErrorKind.invalidResponse => OnlineMusicErrorKind.invalidResponse,
      ChkszErrorKind.cancelled => OnlineMusicErrorKind.cancelled,
      ChkszErrorKind.network => OnlineMusicErrorKind.network,
      ChkszErrorKind.unknown => OnlineMusicErrorKind.unknown,
    };
    return OnlineMusicException(
      kind: kind,
      safeMessage: error.safeMessage,
      retryAfter: error.retryAfter,
    );
  }

  OnlineMusicCredentialException _mapCredentialError(
    Object error,
    OnlineMusicCredentialOperation operation,
  ) {
    if (error is ChkszCredentialStorageException) {
      return OnlineMusicCredentialException(
        operation: operation,
        safeMessage: error.safeMessage,
      );
    }
    if (error is FormatException) {
      return OnlineMusicCredentialException(
        operation: operation,
        safeMessage: 'API Key 格式无效',
      );
    }
    return OnlineMusicCredentialException(
      operation: operation,
      safeMessage: '无法安全处理 ChKSz API Key',
    );
  }
}
