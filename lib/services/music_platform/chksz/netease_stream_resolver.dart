import 'package:pure_music/services/music_platform/adapters/netease_adapter.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_client.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/remote_stream_coordinator.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

final class NeteaseStreamResolver {
  NeteaseStreamResolver({
    required ChkszClient client,
    NeteaseAdapter adapter = const NeteaseAdapter(),
    RemoteStreamClock? clock,
  }) : _client = client,
       _adapter = adapter,
       _clock = clock ?? DateTime.now;

  final ChkszClient _client;
  final NeteaseAdapter _adapter;
  final RemoteStreamClock _clock;

  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    if (requestedQuality != NeteaseAdapter.defaultQuality) {
      throw const ChkszException(
        kind: ChkszErrorKind.businessFailure,
        safeMessage: '请求的音质不可用，请重新选择',
      );
    }

    final request = _adapter.createResolveRequest(ref);
    final response = await _client.sendJson(
      request,
      isBusinessSuccess: _adapter.isBusinessSuccess,
      cancelToken: cancelToken,
    );
    _throwIfCancelled(cancelToken);
    return _adapter.parseResolveResponse(
      response.body,
      expectedRef: ref,
      resolvedAt: _clock(),
    );
  }

  void _throwIfCancelled(ChkszCancelToken token) {
    if (token.isCancelled) throw ChkszException.cancelled();
  }
}
