import 'package:pure_music/services/music_platform/adapters/netease_adapter.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_client.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

final class MusicCatalogService {
  MusicCatalogService({
    required ChkszClient client,
    NeteaseAdapter neteaseAdapter = const NeteaseAdapter(),
  }) : _client = client,
       _neteaseAdapter = neteaseAdapter;

  final ChkszClient _client;
  final NeteaseAdapter _neteaseAdapter;

  Future<MusicSearchPage> searchNetease({
    required String keyword,
    int limit = 30,
    int offset = 0,
    required ChkszCancelToken cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    final request = _neteaseAdapter.createSearchRequest(
      keyword: keyword,
      limit: limit,
      offset: offset,
    );
    final response = await _client.sendJson(
      request,
      isBusinessSuccess: _neteaseAdapter.isBusinessSuccess,
      cancelToken: cancelToken,
    );
    _throwIfCancelled(cancelToken);
    return _neteaseAdapter.parseSearchResponse(
      response.body,
      limit: limit,
      offset: offset,
    );
  }

  Future<RemotePlaylist> fetchNeteasePlaylist({
    required String playlistId,
    required ChkszCancelToken cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    final request = _neteaseAdapter.createPlaylistRequest(playlistId);
    final response = await _client.sendJson(
      request,
      isBusinessSuccess: _neteaseAdapter.isBusinessSuccess,
      cancelToken: cancelToken,
    );
    _throwIfCancelled(cancelToken);
    return _neteaseAdapter.parsePlaylistResponse(
      response.body,
      expectedPlaylistId: playlistId,
    );
  }

  void _throwIfCancelled(ChkszCancelToken token) {
    if (token.isCancelled) throw ChkszException.cancelled();
  }
}
