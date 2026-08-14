import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

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

  bool isBusinessSuccess(Map<String, dynamic> body) =>
      body['code'] == 200 && body['msg'] == 'success';

  ChkszRequest createResolveRequest(PlatformTrackRef ref) {
    _validateTrackRef(ref);
    return ChkszRequest(
      path: '/api/163_music',
      queryParameters: {
        'id': ref.trackId,
        'level': defaultQuality,
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

  ResolvedStream parseResolveResponse(
    Map<String, dynamic> body, {
    required PlatformTrackRef expectedRef,
    required DateTime resolvedAt,
  }) {
    _validateTrackRef(expectedRef);
    if (!isBusinessSuccess(body)) throw _invalidResponse();

    final data = _requiredMap(body['data']);
    final responseId = _requiredPositiveInt(data['id']);
    if ('$responseId' != expectedRef.trackId) throw _invalidResponse();
    final actualQuality = _requiredString(data['level']);
    if (actualQuality != defaultQuality) {
      throw const ChkszException(
        kind: ChkszErrorKind.businessFailure,
        safeMessage: '请求的音质不可用，请重新选择',
      );
    }
    return ResolvedStream(
      ref: expectedRef,
      uri: _requiredHttpUri(data['url']),
      requestedQuality: defaultQuality,
      actualQuality: actualQuality,
      bitrate: _requiredPositiveInt(data['br']),
      resolvedAt: resolvedAt,
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
      coverUri: _optionalHttpUri(song['picUrl']),
      duration: Duration(milliseconds: duration),
    );
  }
}

void _validateTrackRef(PlatformTrackRef ref) {
  if (ref.platform != MusicPlatform.netease ||
      !RegExp(r'^[1-9][0-9]*$').hasMatch(ref.trackId)) {
    throw ArgumentError('Must be a valid NetEase track reference');
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

Uri _requiredHttpUri(Object? value) {
  final uri = _optionalHttpUri(value);
  if (uri == null) throw _invalidResponse();
  return uri;
}

ChkszException _invalidResponse() => const ChkszException(
  kind: ChkszErrorKind.invalidResponse,
  safeMessage: '音乐服务返回了无法识别的数据',
);
