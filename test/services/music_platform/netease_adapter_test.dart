import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/index.dart';

void main() {
  const adapter = NeteaseAdapter();

  group('NeteaseAdapter search request', () {
    test('builds the confirmed request without an API key', () {
      final request = adapter.createSearchRequest(
        keyword: 'Test Track',
        limit: 3,
        offset: 6,
      );

      expect(request.path, '/api/163_search');
      expect(request.method, ChkszHttpMethod.get);
      expect(request.queryParameters, {
        'keyword': 'Test Track',
        'limit': '3',
        'offset': '6',
      });
      expect(request.queryParameters, isNot(contains('apikey')));
    });

    test('rejects invalid query and pagination values locally', () {
      expect(
        () => adapter.createSearchRequest(keyword: '   '),
        throwsArgumentError,
      );
      expect(
        () => adapter.createSearchRequest(keyword: 'test', limit: 0),
        throwsArgumentError,
      );
      expect(
        () => adapter.createSearchRequest(keyword: 'test', offset: -1),
        throwsArgumentError,
      );
    });
  });

  group('NeteaseAdapter search response', () {
    test('maps the confirmed response shape to a search page', () {
      final page = adapter.parseSearchResponse(
        const {
          'code': 200,
          'msg': 'success',
          'data': {
            'songs': [
              {
                'id': 123456,
                'name': 'Test Track',
                'artists': 'Test Artist',
                'album': 'Test Album',
                'picUrl': 'https://cover.invalid/test.jpg',
                'duration': 123456,
              },
            ],
            'total': 31,
          },
        },
        limit: 3,
        offset: 6,
      );

      expect(page.platform, MusicPlatform.netease);
      expect(page.offset, 6);
      expect(page.limit, 3);
      expect(page.total, 31);
      expect(page.nextCursor, isNull);
      expect(page.items, hasLength(1));
      final track = page.items.single;
      expect(track.ref.platform, MusicPlatform.netease);
      expect(track.ref.trackId, '123456');
      expect(track.title, 'Test Track');
      expect(track.artists, ['Test Artist']);
      expect(track.album, 'Test Album');
      expect(track.coverUri, Uri.parse('https://cover.invalid/test.jpg'));
      expect(track.duration, const Duration(milliseconds: 123456));
      expect(track.availability, TrackAvailability.unknown);
      expect(track.searchOrdinal, isNull);
    });

    test('accepts empty results and ignores unusable cover URLs', () {
      final emptyPage = adapter.parseSearchResponse(
        const {
          'code': 200,
          'msg': 'success',
          'data': {'songs': <Object?>[], 'total': 0},
        },
        limit: 30,
        offset: 0,
      );
      final pageWithInvalidCover = adapter.parseSearchResponse(
        const {
          'code': 200,
          'msg': 'success',
          'data': {
            'songs': [
              {
                'id': 1,
                'name': 'Test Track',
                'artists': 'Test Artist',
                'album': 'Test Album',
                'picUrl': 'not-an-http-url',
                'duration': 1,
              },
            ],
            'total': 1,
          },
        },
        limit: 30,
        offset: 0,
      );

      expect(emptyPage.items, isEmpty);
      expect(emptyPage.total, 0);
      expect(pageWithInvalidCover.items.single.coverUri, isNull);
    });

    test('upgrades an HTTP search cover candidate to HTTPS', () {
      final page = adapter.parseSearchResponse(
        const {
          'code': 200,
          'msg': 'success',
          'data': {
            'songs': [
              {
                'id': 1,
                'name': 'Test Track',
                'artists': 'Test Artist',
                'album': 'Test Album',
                'picUrl': 'http://cover.invalid/test.jpg',
                'duration': 1,
              },
            ],
            'total': 1,
          },
        },
        limit: 30,
        offset: 0,
      );

      expect(
        page.items.single.coverUri,
        Uri.parse('https://cover.invalid/test.jpg'),
      );
    });

    test('rejects malformed responses with a safe error', () {
      const secretUrl = 'https://media.invalid/test?signature=TEST_ONLY';
      final malformedBodies = <Map<String, dynamic>>[
        const {'code': 200, 'msg': 'success'},
        const {
          'code': 200,
          'msg': 'success',
          'data': {'songs': 'invalid', 'total': 0},
        },
        const {
          'code': 200,
          'msg': 'success',
          'data': {'songs': <Object?>[], 'total': '0'},
        },
        const {
          'code': 200,
          'msg': 'success',
          'data': {
            'songs': [
              {
                'id': '123',
                'name': 'Test Track',
                'artists': 'Test Artist',
                'album': 'Test Album',
                'picUrl': secretUrl,
                'duration': 1,
              },
            ],
            'total': 1,
          },
        },
      ];

      for (final body in malformedBodies) {
        expect(
          () => adapter.parseSearchResponse(body, limit: 30, offset: 0),
          throwsA(
            isA<ChkszException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  ChkszErrorKind.invalidResponse,
                )
                .having(
                  (error) => error.toString(),
                  'safe error',
                  isNot(contains(secretUrl)),
                ),
          ),
        );
      }
    });

    test('requires the confirmed business success marker', () {
      const failure = {'code': 403, 'msg': 'denied'};

      expect(adapter.isBusinessSuccess(failure), isFalse);
      expect(
        () => adapter.parseSearchResponse(failure, limit: 30, offset: 0),
        throwsA(
          isA<ChkszException>().having(
            (error) => error.kind,
            'kind',
            ChkszErrorKind.invalidResponse,
          ),
        ),
      );
    });
  });

  group('NeteaseAdapter resolve request', () {
    test('builds the confirmed lossless request without an API key', () {
      final request = adapter.createResolveRequest(
        const PlatformTrackRef(
          platform: MusicPlatform.netease,
          trackId: '123456',
        ),
      );

      expect(request.path, '/api/163_music');
      expect(request.method, ChkszHttpMethod.get);
      expect(request.queryParameters, {
        'id': '123456',
        'level': 'lossless',
        'type': 'json',
      });
      expect(request.queryParameters, isNot(contains('apikey')));
    });

    test('rejects empty, non-numeric, and non-NetEase references', () {
      const invalidRefs = [
        PlatformTrackRef(platform: MusicPlatform.netease, trackId: ''),
        PlatformTrackRef(platform: MusicPlatform.netease, trackId: 'track'),
        PlatformTrackRef(platform: MusicPlatform.qq, trackId: '123456'),
      ];

      for (final ref in invalidRefs) {
        expect(() => adapter.createResolveRequest(ref), throwsArgumentError);
      }
    });
  });

  group('NeteaseAdapter resolve response', () {
    const ref = PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: '123456',
    );
    final resolvedAt = DateTime.utc(2026, 8, 14, 12);

    test('maps the confirmed response to an in-memory stream', () {
      final stream = adapter.parseResolveResponse(
        const {
          'code': 200,
          'msg': 'success',
          'data': {
            'id': 123456,
            'url': 'https://media.invalid/test.flac?signature=TEST_ONLY',
            'br': 1000000,
            'level': 'lossless',
            'size': 12345678,
            'md5': 'TEST_ONLY_CHECKSUM',
            'name': 'Test Track',
            'artist': 'Test Artist',
            'album': 'Test Album',
            'picUrl': 'https://cover.invalid/test.jpg',
          },
        },
        expectedRef: ref,
        resolvedAt: resolvedAt,
      );

      expect(stream.ref, ref);
      expect(
        stream.uri,
        Uri.parse('https://media.invalid/test.flac?signature=TEST_ONLY'),
      );
      expect(stream.requestedQuality, NeteaseAdapter.defaultQuality);
      expect(stream.coverUri, Uri.parse('https://cover.invalid/test.jpg'));
      expect(stream.toString(), isNot(contains('cover.invalid')));
      expect(stream.actualQuality, 'lossless');
      expect(stream.bitrate, 1000000);
      expect(stream.format, isNull);
      expect(stream.resolvedAt, resolvedAt);
      expect(stream.expiresAt, isNull);
    });

    test('ignores unusable optional resolve covers without failing', () {
      for (final cover in <Object?>[
        null,
        1,
        'not-an-http-url',
        'http://cover.invalid/test.jpg',
      ]) {
        final body = _resolveBody();
        final data = Map<String, dynamic>.from(body['data']! as Map);
        data['picUrl'] = cover;
        body['data'] = data;

        final stream = adapter.parseResolveResponse(
          body,
          expectedRef: ref,
          resolvedAt: resolvedAt,
        );

        expect(stream.coverUri, isNull);
      }
    });

    test('rejects an unrequested quality instead of degrading silently', () {
      final body = _resolveBody(level: 'standard');

      expect(
        () => adapter.parseResolveResponse(
          body,
          expectedRef: ref,
          resolvedAt: resolvedAt,
        ),
        throwsA(
          isA<ChkszException>().having(
            (error) => error.kind,
            'kind',
            ChkszErrorKind.businessFailure,
          ),
        ),
      );
    });

    test('rejects mismatched IDs and malformed stream fields safely', () {
      const secretUrl =
          'https://media.invalid/test.flac?signature=SECRET_TEST_ONLY';
      final malformedBodies = [
        _resolveBody(id: 654321, url: secretUrl),
        _resolveBody(url: 'not-an-http-url'),
        _resolveBody(url: secretUrl, bitrate: 'invalid'),
      ];

      for (final body in malformedBodies) {
        expect(
          () => adapter.parseResolveResponse(
            body,
            expectedRef: ref,
            resolvedAt: resolvedAt,
          ),
          throwsA(
            isA<ChkszException>()
                .having(
                  (error) => error.kind,
                  'kind',
                  ChkszErrorKind.invalidResponse,
                )
                .having(
                  (error) => error.toString(),
                  'safe error',
                  isNot(contains(secretUrl)),
                ),
          ),
        );
      }
    });
  });
}

Map<String, dynamic> _resolveBody({
  int id = 123456,
  String url = 'https://media.invalid/test.flac',
  Object bitrate = 1000000,
  String level = 'lossless',
}) => {
  'code': 200,
  'msg': 'success',
  'data': {'id': id, 'url': url, 'br': bitrate, 'level': level},
};
