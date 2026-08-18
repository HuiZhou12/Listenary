import 'package:pure_music/services/music_platform/adapters/netease_adapter.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';

final class ChkszOnlineMusicProvider
    implements OnlineMusicService, OnlineMusicCredentialController {
  ChkszOnlineMusicProvider({required ChkszRuntime runtime})
    : _runtime = runtime;

  final ChkszRuntime _runtime;

  @override
  final OnlineMusicCapabilities capabilities = OnlineMusicCapabilities(
    searchablePlatforms: [MusicPlatform.netease],
    resolvablePlatforms: [MusicPlatform.netease],
    playlistPlatforms: [MusicPlatform.netease],
  );

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    _ensurePlatform(platform, capabilities.searchablePlatforms);
    try {
      return await _runtime.searchNetease(
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
    _ensurePlatform(ref.platform, capabilities.resolvablePlatforms);
    try {
      return await _runtime.resolveNetease(
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
    _ensurePlatform(platform, capabilities.playlistPlatforms);
    try {
      return await _runtime.fetchNeteasePlaylist(
        playlistId: playlistId,
        cancelToken: cancelToken,
      );
    } catch (error) {
      throw _mapError(error);
    }
  }

  @override
  String defaultQualityFor(MusicPlatform platform) {
    _ensurePlatform(platform, capabilities.resolvablePlatforms);
    return NeteaseAdapter.defaultQuality;
  }

  @override
  String get providerDisplayName => 'ChKSz';

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

  void _ensurePlatform(MusicPlatform platform, Set<MusicPlatform> supported) {
    if (!supported.contains(platform)) {
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
