import 'package:pure_music/services/music_platform/adapters/netease_adapter.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_client.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_quota.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/netease_stream_resolver.dart';
import 'package:pure_music/services/music_platform/remote_stream_coordinator.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/chksz/music_catalog_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';

typedef ChkszTransportDispose = void Function();

final class ChkszRuntime {
  ChkszRuntime({
    ChkszCredentialProvider? credentialProvider,
    required ChkszTransport transport,
    ChkszTransportDispose? disposeTransport,
    NeteaseAdapter neteaseAdapter = const NeteaseAdapter(),
    OnlineMusicAuthResolver authResolver = defaultOnlineMusicAuthResolver,
    RemoteStreamClock? clock,
  }) : _credentialProvider = credentialProvider,
       _disposeTransport = disposeTransport,
       _authResolver = authResolver {
    final client = ChkszClient(
      transport: transport,
      credentialProvider: credentialProvider,
      onQuotaUpdated: (quota) => _quota = quota,
    );
    _catalogService = MusicCatalogService(
      client: client,
      neteaseAdapter: neteaseAdapter,
      authResolver: authResolver,
    );
    _neteaseStreamResolver = NeteaseStreamResolver(
      client: client,
      adapter: neteaseAdapter,
      authResolver: authResolver,
      clock: clock,
    );
  }

  final ChkszCredentialProvider? _credentialProvider;
  final ChkszTransportDispose? _disposeTransport;
  final OnlineMusicAuthResolver _authResolver;
  final Set<ChkszCancelToken> _activeTokens = {};
  late final MusicCatalogService _catalogService;
  late final NeteaseStreamResolver _neteaseStreamResolver;
  Future<void> _pendingCredentialOperation = Future<void>.value();
  ChkszQuotaSnapshot? _quota;
  bool _disposed = false;

  ChkszQuotaSnapshot? get quota => _quota;

  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability) =>
      _authResolver(capability);

  /// Provider 声明 `auth.kind = none` 时没有凭据来源，读取结果为「未配置」。
  Future<String?> readApiKey() {
    _throwIfDisposed();
    return _credentialProvider?.readApiKey() ?? Future<String?>.value();
  }

  Future<void> writeApiKey(String apiKey) => _serializeCredentialOperation(
    () => _replaceCredential(
      () => _requireCredentialProvider().writeApiKey(apiKey),
    ),
  );

  Future<void> clearApiKey() => _serializeCredentialOperation(
    () => _replaceCredential(
      () => _credentialProvider?.clearApiKey() ?? Future<void>.value(),
    ),
  );

  ChkszCredentialProvider _requireCredentialProvider() {
    final provider = _credentialProvider;
    if (provider == null) {
      throw const ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.write,
      );
    }
    return provider;
  }

  Future<MusicSearchPage> search({
    required String keyword,
    int limit = 30,
    int offset = 0,
    required ChkszCancelToken cancelToken,
  }) => _runRequest(
    cancelToken,
    () => _catalogService.search(
      keyword: keyword,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    ),
  );

  Future<RemotePlaylist> fetchPlaylist({
    required String playlistId,
    required ChkszCancelToken cancelToken,
  }) => _runRequest(
    cancelToken,
    () => _catalogService.fetchPlaylist(
      playlistId: playlistId,
      cancelToken: cancelToken,
    ),
  );

  Future<MusicLyrics> fetchLyrics({
    required PlatformTrackRef ref,
    required ChkszCancelToken cancelToken,
  }) => _runRequest(
    cancelToken,
    () => _catalogService.fetchLyrics(ref: ref, cancelToken: cancelToken),
  );

  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) => _runRequest(
    cancelToken,
    () => _neteaseStreamResolver.resolve(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    ),
  );

  Future<ResolvedStream> resolveAndOpen(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required PlaybackBackend backend,
    required ChkszCancelToken cancelToken,
  }) => _runRequest(
    cancelToken,
    () =>
        RemoteStreamCoordinator(
          resolver: _neteaseStreamResolver.resolve,
          backend: backend,
        ).resolveAndOpen(
          ref,
          requestedQuality: requestedQuality,
          cancelToken: cancelToken,
        ),
  );

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelActiveRequests();
    _quota = null;
    _disposeTransport?.call();
  }

  Future<T> _runRequest<T>(
    ChkszCancelToken token,
    Future<T> Function() request,
  ) async {
    _throwIfDisposed();
    _activeTokens.add(token);
    try {
      return await request();
    } finally {
      _activeTokens.remove(token);
    }
  }

  Future<void> _replaceCredential(Future<void> Function() operation) async {
    _throwIfDisposed();
    _cancelActiveRequests();
    _quota = null;
    await operation();
  }

  Future<void> _serializeCredentialOperation(
    Future<void> Function() operation,
  ) {
    final result = _pendingCredentialOperation.then((_) => operation());
    _pendingCredentialOperation = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void _cancelActiveRequests() {
    final tokens = _activeTokens.toList(growable: false);
    _activeTokens.clear();
    for (final token in tokens) {
      token.cancel();
    }
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('ChkszRuntime has been disposed');
  }
}
