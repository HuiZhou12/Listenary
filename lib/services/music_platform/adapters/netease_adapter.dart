import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/online_lyric/parsed_lyric_converter.dart';
import 'package:pure_music/services/online_lyric/parsers/lrc_tool.dart';

final class NeteaseAdapter {
  const NeteaseAdapter();

  static const defaultQuality = 'lossless';

  ChkszRequest createSearchRequest({
    required String keyword,
    int limit = 30,
    int offset = 0,
  }) {
    if (keyword.trim().isEmpty) {
      throw ArgumentError.value(keyword, 'keyword', 'Must not be empty');
    }
    _validatePagination(limit: limit, offset: offset);
    return ChkszRequest(
      path: '/api/163_search',
      queryParameters: {
        'keyword': keyword,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
  }

  ChkszRequest createPlaylistRequest(String playlistId) {
    _validatePlaylistId(playlistId);
    return ChkszRequest(
      path: '/api/163_playlist',
      queryParameters: {'id': playlistId},
    );
  }

  ChkszRequest createLyricsRequest(PlatformTrackRef ref) {
    _validateTrackRef(ref);
    return ChkszRequest(
      path: '/api/163_lyric',
      queryParameters: {'id': ref.trackId},
    );
  }

  bool isBusinessSuccess(Map<String, dynamic> body) =>
      body['code'] == 200 && body['msg'] == 'success';

  ChkszRequest createResolveRequest(
    PlatformTrackRef ref, {
    String quality = defaultQuality,
  }) {
    _validateTrackRef(ref);
    return ChkszRequest(
      path: '/api/163_music',
      queryParameters: {
        'id': ref.trackId,
        'level': quality,
        'type': 'json',
      },
    );
  }

  MusicSearchPage parseSearchResponse(
    Map<String, dynamic> body, {
    required int limit,
    required int offset,
  }) {
    _validatePagination(limit: limit, offset: offset);
    if (!isBusinessSuccess(body)) throw _invalidResponse();

    final data = _requiredMap(body['data']);
    final songs = _requiredList(data['songs']);
    final total = _requiredNonNegativeInt(data['total']);
    final items = songs.map(_parseTrack).toList(growable: false);
    return MusicSearchPage(
      platform: MusicPlatform.netease,
      items: items,
      offset: offset,
      limit: limit,
      total: total,
    );
  }

  RemotePlaylist parsePlaylistResponse(
    Map<String, dynamic> body, {
    String? expectedPlaylistId,
  }) {
    if (!isBusinessSuccess(body)) throw _invalidResponse();

    final data = _requiredMap(body['data']);
    final playlistId = _requiredPositiveInt(data['id']);
    if (expectedPlaylistId != null && '$playlistId' != expectedPlaylistId) {
      throw _invalidResponse();
    }
    final name = _requiredNonEmptyString(data['name']);
    final trackCount = _requiredNonNegativeInt(data['trackCount']);
    final rawTracks = _requiredList(data['tracks']);
    if (trackCount != rawTracks.length) throw _invalidResponse();

    final trackIds = <String>{};
    final tracks = <MusicTrack>[];
    for (final rawTrack in rawTracks) {
      final track = _parsePlaylistTrack(rawTrack);
      if (!trackIds.add(track.ref.trackId)) throw _invalidResponse();
      tracks.add(track);
    }

    return RemotePlaylist(
      platform: MusicPlatform.netease,
      id: '$playlistId',
      name: name,
      coverUri: _optionalSearchCoverUri(data['coverImgUrl']),
      creator: _optionalNestedString(data['creator'], 'nickname'),
      trackCount: trackCount,
      tracks: tracks,
    );
  }

  ResolvedStream parseResolveResponse(
    Map<String, dynamic> body, {
    required PlatformTrackRef expectedRef,
    required DateTime resolvedAt,
    String requestedQuality = defaultQuality,
  }) {
    _validateTrackRef(expectedRef);
    if (!isBusinessSuccess(body)) throw _invalidResponse();

    final data = _requiredMap(body['data']);
    final responseId = _requiredPositiveInt(data['id']);
    if ('$responseId' != expectedRef.trackId) throw _invalidResponse();
    final actualQuality = _requiredString(data['level']);
    if (actualQuality != requestedQuality) {
      throw const ChkszException(
        kind: ChkszErrorKind.businessFailure,
        safeMessage: '请求的音质不可用，请重新选择',
      );
    }
    return ResolvedStream(
      ref: expectedRef,
      uri: _requiredHttpUri(data['url']),
      requestedQuality: requestedQuality,
      coverUri: _optionalHttpsUri(data['picUrl']),
      actualQuality: actualQuality,
      bitrate: _requiredPositiveInt(data['br']),
      resolvedAt: resolvedAt,
    );
  }

  Future<MusicLyrics> parseLyricsResponse(
    Map<String, dynamic> body,
  ) async {
    if (!isBusinessSuccess(body)) throw _invalidResponse();
    final data = _requiredMap(body['data']);
    final original = _optionalLyricTrack(data, 'lrc');
    final translation = _optionalLyricTrack(data, 'tlyric');
    final romanization = _optionalLyricTrack(data, 'romalrc');
    if (original == null) {
      return MusicLyrics(
        translation: translation,
        romanization: romanization,
      );
    }
    final parsed = await parseLyricInIsolate(
      text: original,
      transText: translation,
      romanizationText: romanization,
    );
    return MusicLyrics(
      original: original,
      translation: translation,
      romanization: romanization,
      parsed: parsed == null
          ? null
          : parsedLyricToLyric(parsed, rawText: original),
    );
  }

  MusicTrack _parseTrack(Object? value) {
    final song = _requiredMap(value);
    final id = _requiredPositiveInt(song['id']);
    final duration = _requiredNonNegativeInt(song['duration']);
    return MusicTrack(
      ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: '$id'),
      title: _requiredString(song['name']),
      artists: [_requiredString(song['artists'])],
      album: _requiredString(song['album']),
      coverUri: _optionalSearchCoverUri(song['picUrl']),
      duration: Duration(milliseconds: duration),
    );
  }

  MusicTrack _parsePlaylistTrack(Object? value) {
    final song = _requiredMap(value);
    final id = _requiredPositiveInt(song['id']);
    final title = _requiredNonEmptyString(song['name']);
    final rawArtists = _requiredList(song['ar']);
    if (rawArtists.isEmpty) throw _invalidResponse();
    final artists = rawArtists
        .map((artist) {
          final artistMap = _requiredMap(artist);
          return _requiredNonEmptyString(artistMap['name']);
        })
        .toList(growable: false);
    final album = _optionalMap(song['al']);
    return MusicTrack(
      ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: '$id'),
      title: title,
      artists: artists,
      album: _optionalString(album?['name']) ?? '',
      coverUri: _optionalSearchCoverUri(album?['picUrl']),
      duration: Duration.zero,
      availability: TrackAvailability.unknown,
    );
  }
}

void _validateTrackRef(PlatformTrackRef ref) {
  if (ref.platform != MusicPlatform.netease ||
      !RegExp(r'^[1-9][0-9]*$').hasMatch(ref.trackId)) {
    throw ArgumentError('Must be a valid NetEase track reference');
  }
}

void _validatePlaylistId(String playlistId) {
  if (!RegExp(r'^[1-9][0-9]*$').hasMatch(playlistId)) {
    throw ArgumentError.value(playlistId, 'playlistId');
  }
}

void _validatePagination({required int limit, required int offset}) {
  if (limit <= 0) {
    throw ArgumentError.value(limit, 'limit', 'Must be positive');
  }
  if (offset < 0) {
    throw ArgumentError.value(offset, 'offset', 'Must not be negative');
  }
}

Map<Object?, Object?> _requiredMap(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  throw _invalidResponse();
}

List<Object?> _requiredList(Object? value) {
  if (value is List<Object?>) return value;
  throw _invalidResponse();
}

String _requiredString(Object? value) {
  if (value is String) return value;
  throw _invalidResponse();
}

String _requiredNonEmptyString(Object? value) {
  final result = _requiredString(value);
  if (result.trim().isEmpty) throw _invalidResponse();
  return result;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final result = value.trim();
  return result.isEmpty ? null : value;
}

String? _optionalLyricTrack(Map<Object?, Object?> data, String key) {
  final value = data[key];
  if (value == null) return null;
  if (value is! String) throw _invalidResponse();
  return value.trim().isEmpty ? null : value;
}

Map<Object?, Object?>? _optionalMap(Object? value) {
  if (value == null) return null;
  return value is Map<Object?, Object?> ? value : null;
}

String? _optionalNestedString(Object? value, String key) {
  return _optionalString(_optionalMap(value)?[key]);
}

int _requiredPositiveInt(Object? value) {
  if (value is int && value > 0) return value;
  throw _invalidResponse();
}

int _requiredNonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  throw _invalidResponse();
}

Uri? _optionalHttpUri(Object? value) {
  if (value == null || value == '') return null;
  if (value is! String) throw _invalidResponse();
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

Uri? _optionalSearchCoverUri(Object? value) {
  final uri = _optionalHttpUri(value);
  if (uri == null || uri.scheme == 'https') return uri;
  return uri.replace(scheme: 'https');
}

Uri _requiredHttpUri(Object? value) {
  final uri = _optionalHttpUri(value);
  if (uri == null) throw _invalidResponse();
  return uri;
}

Uri? _optionalHttpsUri(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

ChkszException _invalidResponse() => const ChkszException(
  kind: ChkszErrorKind.invalidResponse,
  safeMessage: '音乐服务返回了无法识别的数据',
);
