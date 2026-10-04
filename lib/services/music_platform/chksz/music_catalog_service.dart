import 'package:pure_music/services/music_platform/adapters/netease_adapter.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_client.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';

final class MusicCatalogService {
  MusicCatalogService({
    required ChkszClient client,
    NeteaseAdapter neteaseAdapter = const NeteaseAdapter(),
    OnlineMusicAuthResolver authResolver = defaultOnlineMusicAuthResolver,
  }) : _client = client,
       _neteaseAdapter = neteaseAdapter,
       _authResolver = authResolver;

  final ChkszClient _client;
  final NeteaseAdapter _neteaseAdapter;
  final OnlineMusicAuthResolver _authResolver;

  Future<MusicSearchPage> search({
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
      auth: _authResolver(OnlineMusicCapability.search),
      cancelToken: cancelToken,
    );
    _throwIfCancelled(cancelToken);
    return _neteaseAdapter.parseSearchResponse(
      response.body,
      limit: limit,
      offset: offset,
    );
  }

  Future<RemotePlaylist> fetchPlaylist({
    required String playlistId,
    required ChkszCancelToken cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    final request = _neteaseAdapter.createPlaylistRequest(playlistId);
    final response = await _client.sendJson(
      request,
      isBusinessSuccess: _neteaseAdapter.isBusinessSuccess,
      auth: _authResolver(OnlineMusicCapability.playlist),
      cancelToken: cancelToken,
    );
    _throwIfCancelled(cancelToken);
    return _neteaseAdapter.parsePlaylistResponse(
      response.body,
      expectedPlaylistId: playlistId,
    );
  }

  Future<MusicLyrics> fetchLyrics({
    required PlatformTrackRef ref,
    required ChkszCancelToken cancelToken,
  }) async {
    _throwIfCancelled(cancelToken);
    final request = _neteaseAdapter.createLyricsRequest(ref);
    final response = await _client.sendJson(
      request,
      isBusinessSuccess: _neteaseAdapter.isBusinessSuccess,
      auth: _authResolver(OnlineMusicCapability.lyric),
      cancelToken: cancelToken,
    );
    _throwIfCancelled(cancelToken);
    final lyrics = await _neteaseAdapter.parseLyricsResponse(response.body);
    _throwIfCancelled(cancelToken);
    return lyrics;
  }

  void _throwIfCancelled(ChkszCancelToken token) {
    if (token.isCancelled) throw ChkszException.cancelled();
  }
}
