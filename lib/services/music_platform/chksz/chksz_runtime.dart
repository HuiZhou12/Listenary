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

typedef ChkszTransportDispose = void Function();

final class ChkszRuntime {
  ChkszRuntime({
    required ChkszCredentialProvider credentialProvider,
    required ChkszTransport transport,
    ChkszTransportDispose? disposeTransport,
    NeteaseAdapter neteaseAdapter = const NeteaseAdapter(),
    RemoteStreamClock? clock,
  }) : _credentialProvider = credentialProvider,
       _disposeTransport = disposeTransport {
    final client = ChkszClient(
      transport: transport,
      credentialProvider: credentialProvider,
      onQuotaUpdated: (quota) => _quota = quota,
    );
    _catalogService = MusicCatalogService(
      client: client,
      neteaseAdapter: neteaseAdapter,
    );
    _neteaseStreamResolver = NeteaseStreamResolver(
      client: client,
      adapter: neteaseAdapter,
      clock: clock,
    );
  }

  final ChkszCredentialProvider _credentialProvider;
  final ChkszTransportDispose? _disposeTransport;
  final Set<ChkszCancelToken> _activeTokens = {};
  late final MusicCatalogService _catalogService;
  late final NeteaseStreamResolver _neteaseStreamResolver;
  Future<void> _pendingCredentialOperation = Future<void>.value();
  ChkszQuotaSnapshot? _quota;
  bool _disposed = false;

  ChkszQuotaSnapshot? get quota => _quota;

  Future<String?> readApiKey() {
    _throwIfDisposed();
    return _credentialProvider.readApiKey();
  }

  Future<void> writeApiKey(String apiKey) => _serializeCredentialOperation(
    () => _replaceCredential(() => _credentialProvider.writeApiKey(apiKey)),
  );

  Future<void> clearApiKey() => _serializeCredentialOperation(
    () => _replaceCredential(_credentialProvider.clearApiKey),
  );

  Future<MusicSearchPage> searchNetease({
    required String keyword,
    int limit = 30,
    int offset = 0,
    required ChkszCancelToken cancelToken,
  }) => _runRequest(
    cancelToken,
    () => _catalogService.searchNetease(
      keyword: keyword,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    ),
  );

  Future<RemotePlaylist> fetchNeteasePlaylist({
    required String playlistId,
    required ChkszCancelToken cancelToken,
  }) => _runRequest(
    cancelToken,
    () => _catalogService.fetchNeteasePlaylist(
      playlistId: playlistId,
      cancelToken: cancelToken,
    ),
  );

  Future<ResolvedStream> resolveNetease(
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

  Future<ResolvedStream> resolveAndOpenNetease(
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
