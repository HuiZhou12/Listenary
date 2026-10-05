import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';

JsonPath _p(String source) => JsonPath.tryParse(source)!;

/// ChkSz 搜索：`GET /api/163_search?keyword&limit&offset&apikey`，信封 `data`，
/// `artists` 是字符串。
final chkszSearchBinding = OnlineMusicDeclarativeCapabilityBinding(
  request: const OnlineMusicRequestSpec(
    path: '/api/163_search',
    query: [
      OnlineMusicParamBinding(
        name: 'keyword',
        source: OnlineMusicInputSource.keyword,
        required: true,
      ),
      OnlineMusicParamBinding(
        name: 'limit',
        source: OnlineMusicInputSource.limit,
        defaultValue: 30,
      ),
      OnlineMusicParamBinding(
        name: 'offset',
        source: OnlineMusicInputSource.offset,
        defaultValue: 0,
      ),
    ],
    auth: OnlineMusicQueryAuthPlacement(parameterName: 'apikey'),
  ),
  response: OnlineMusicResponseSpec(
    success: OnlineMusicSuccessSpec(
      allOf: [
        OnlineMusicSuccessPredicate(
          path: _p('code'),
          op: OnlineMusicPredicateOp.eq,
          value: 200,
        ),
        OnlineMusicSuccessPredicate(
          path: _p('msg'),
          op: OnlineMusicPredicateOp.eq,
          value: 'success',
        ),
      ],
    ),
    listPath: _p('data.songs'),
    totalPath: _p('data.total'),
    fields: {
      OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
        candidates: [_p('id')],
        transform: OnlineMusicFieldTransform.asInt,
        required: true,
      ),
      OnlineMusicDomainField.title: OnlineMusicFieldSpec(
        candidates: [_p('name')],
        transform: OnlineMusicFieldTransform.asString,
        required: true,
      ),
      OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
        candidates: [_p('artists')],
        transform: OnlineMusicFieldTransform.asSingleStringList,
        required: true,
      ),
      OnlineMusicDomainField.album: OnlineMusicFieldSpec(
        candidates: [_p('album')],
        transform: OnlineMusicFieldTransform.asString,
      ),
      OnlineMusicDomainField.coverUri: OnlineMusicFieldSpec(
        candidates: [_p('picUrl')],
        transform: OnlineMusicFieldTransform.asHttpsUri,
      ),
      OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
        candidates: [_p('duration')],
        transform: OnlineMusicFieldTransform.asDurationMs,
      ),
    },
    pagination: const OnlineMusicPaginationSpec(
      kind: OnlineMusicPaginationKind.offsetLimit,
    ),
  ),
);

/// MSAPI 搜索：`GET /search?keywords`，信封 `result`，`artists` 是对象数组，
/// `album` 是对象。**本轮只有 Search 的真实样本**（见 Spec §11）。
final msapiSearchBinding = OnlineMusicDeclarativeCapabilityBinding(
  request: const OnlineMusicRequestSpec(
    path: '/search',
    query: [
      OnlineMusicParamBinding(
        name: 'keywords',
        source: OnlineMusicInputSource.keyword,
        required: true,
      ),
      OnlineMusicParamBinding(
        name: 'limit',
        source: OnlineMusicInputSource.limit,
      ),
      OnlineMusicParamBinding(
        name: 'offset',
        source: OnlineMusicInputSource.offset,
      ),
    ],
  ),
  response: OnlineMusicResponseSpec(
    listPath: _p('result.songs'),
    fields: {
      OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
        candidates: [_p('id')],
        transform: OnlineMusicFieldTransform.asInt,
        required: true,
      ),
      OnlineMusicDomainField.title: OnlineMusicFieldSpec(
        candidates: [_p('name')],
        transform: OnlineMusicFieldTransform.asString,
        required: true,
      ),
      OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
        candidates: [_p('artists[*].name')],
        transform: OnlineMusicFieldTransform.asStringList,
        required: true,
      ),
      OnlineMusicDomainField.album: OnlineMusicFieldSpec(
        candidates: [_p('album.name')],
        transform: OnlineMusicFieldTransform.asString,
      ),
      OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
        candidates: [_p('duration')],
        transform: OnlineMusicFieldTransform.asDurationMs,
      ),
    },
    pagination: const OnlineMusicPaginationSpec(
      kind: OnlineMusicPaginationKind.offsetLimit,
    ),
  ),
);

/// ChkSz 播放解析：信封 `data`，字段相对 `data`。
final chkszStreamBinding = OnlineMusicDeclarativeCapabilityBinding(
  request: const OnlineMusicRequestSpec(
    path: '/api/163_music',
    query: [
      OnlineMusicParamBinding(
        name: 'id',
        source: OnlineMusicInputSource.trackId,
        required: true,
      ),
      OnlineMusicParamBinding(
        name: 'level',
        source: OnlineMusicInputSource.quality,
        defaultValue: 'lossless',
      ),
      OnlineMusicParamBinding(
        name: 'type',
        source: OnlineMusicInputSource.cursor,
        defaultValue: 'json',
      ),
    ],
    auth: OnlineMusicQueryAuthPlacement(parameterName: 'apikey'),
  ),
  response: OnlineMusicResponseSpec(
    success: OnlineMusicSuccessSpec(
      allOf: [
        OnlineMusicSuccessPredicate(
          path: _p('code'),
          op: OnlineMusicPredicateOp.eq,
          value: 200,
        ),
      ],
    ),
    fieldsRootPath: _p('data'),
    fields: {
      OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
        candidates: [_p('url')],
        transform: OnlineMusicFieldTransform.asUri,
        required: true,
      ),
      OnlineMusicDomainField.streamQuality: OnlineMusicFieldSpec(
        candidates: [_p('level')],
        transform: OnlineMusicFieldTransform.asString,
      ),
      OnlineMusicDomainField.streamBitrate: OnlineMusicFieldSpec(
        candidates: [_p('br')],
        transform: OnlineMusicFieldTransform.asInt,
      ),
      OnlineMusicDomainField.coverUri: OnlineMusicFieldSpec(
        candidates: [_p('picUrl')],
        transform: OnlineMusicFieldTransform.asUri,
      ),
      OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
        candidates: [_p('id')],
        transform: OnlineMusicFieldTransform.asInt,
      ),
    },
  ),
);

/// 用户提供的 ChkSz 搜索响应样本（截图右侧，字段原样保留）。
const chkszSearchSample = <String, Object?>{
  'code': 200,
  'msg': 'success',
  'data': {
    'songs': [
      {
        'id': 65800,
        'name': '最佳损友',
        'artists': '陈奕迅',
        'album': 'Life Continues',
        'picUrl': 'http://p3.music.126.net/3mi073axzjg-g-790bwBQ==/109951171836582062.jpg',
        'duration': 233560,
      },
      {
        'id': 66285,
        'name': '葡萄成熟时',
        'artists': '陈奕迅',
        'album': 'U87',
        'picUrl': 'http://p3.music.126.net/W9imJx0w_JeCGgs43dfjFg==/109951171529987110.jpg',
        'duration': 279946,
      },
    ],
    'total': 291,
  },
};

/// 用户提供的 MSAPI 搜索响应样本（截图左侧的可见字段，未出现的字段不臆造）。
const msapiSearchSample = <String, Object?>{
  'result': {
    'songs': [
      {
        'id': 347230,
        'name': '海阔天空',
        'duration': 239560,
        'artists': [
          {'id': 11127, 'name': 'Beyond'},
        ],
        'album': {'id': 78372827, 'name': '华纳廿三周年纪念精选系列 - Beyond'},
        'fee': 1,
      },
    ],
  },
};

/// ChkSz 播放解析样本（既有测试里一直在用的形状）。
const chkszStreamSample = <String, Object?>{
  'code': 200,
  'msg': 'success',
  'data': {
    'id': 123456,
    'url': 'https://media.invalid/test.flac',
    'br': 1000000,
    'level': 'lossless',
    'picUrl': 'https://cover.invalid/test.jpg',
  },
};

void main() {
  group('request builder', () {
    test('builds the ChkSz search request with auth in the query', () {
      final request = buildDeclarativeRequest(
        spec: chkszSearchBinding.request,
        inputs: const DeclarativeInputs(
          keyword: '陈奕迅',
          limit: 3,
          offset: 6,
        ),
        credential: 'chksz_TEST_ONLY',
      );

      expect(request.method, 'GET');
      expect(request.path, '/api/163_search');
      expect(request.query, {
        'keyword': '陈奕迅',
        'limit': '3',
        'offset': '6',
        'apikey': 'chksz_TEST_ONLY',
      });
      expect(request.body, isNull);
    });

    test('builds the MSAPI search request with a renamed keyword parameter', () {
      final request = buildDeclarativeRequest(
        spec: msapiSearchBinding.request,
        inputs: const DeclarativeInputs(keyword: '海阔天空'),
      );

      expect(request.path, '/search');
      expect(request.query, {'keywords': '海阔天空'});
      expect(request.query.containsKey('apikey'), isFalse);
    });

    test('substitutes path placeholders and stays URL-safe', () {
      const spec = OnlineMusicRequestSpec(
        path: '/song/{trackId}/url',
        query: [
          OnlineMusicParamBinding(
            name: 'id',
            source: OnlineMusicInputSource.trackId,
          ),
        ],
      );

      final request = buildDeclarativeRequest(
        spec: spec,
        inputs: const DeclarativeInputs(trackId: 'a b/c'),
      );

      expect(request.path, '/song/a%20b%2Fc/url');
      expect(request.query['id'], 'a b/c');
    });

    test('POST + JSON body + header auth', () {
      const spec = OnlineMusicRequestSpec(
        verb: OnlineMusicHttpVerb.post,
        path: '/api/v1/search',
        query: [
          OnlineMusicParamBinding(
            name: 'size',
            source: OnlineMusicInputSource.limit,
            defaultValue: 20,
          ),
        ],
        headers: [OnlineMusicHeaderSpec(name: 'Accept', value: 'application/json')],
        body: OnlineMusicRequestBodySpec(
          fields: [
            OnlineMusicParamBinding(
              name: 'q',
              source: OnlineMusicInputSource.keyword,
              required: true,
            ),
          ],
        ),
        auth: OnlineMusicHeaderAuthPlacement(
          headerName: 'Authorization',
          prefix: 'Bearer ',
        ),
      );

      final request = buildDeclarativeRequest(
        spec: spec,
        inputs: const DeclarativeInputs(keyword: 'jazz'),
        credential: 'token-123',
      );

      expect(request.method, 'POST');
      expect(request.headers['Accept'], 'application/json');
      expect(request.headers['Authorization'], 'Bearer token-123');
      expect(request.query, {'size': '20'});
      expect(request.body, {'q': 'jazz'});
      expect(request.isForm, isFalse);
    });

    test('auth in a form body', () {
      const spec = OnlineMusicRequestSpec(
        verb: OnlineMusicHttpVerb.post,
        path: '/search',
        body: OnlineMusicRequestBodySpec(
          isForm: true,
          fields: [
            OnlineMusicParamBinding(
              name: 'q',
              source: OnlineMusicInputSource.keyword,
              required: true,
            ),
          ],
        ),
        auth: OnlineMusicBodyAuthPlacement(fieldName: 'key'),
      );

      final request = buildDeclarativeRequest(
        spec: spec,
        inputs: const DeclarativeInputs(keyword: 'x'),
        credential: 'k',
      );

      expect(request.isForm, isTrue);
      expect(request.body, {'q': 'x', 'key': 'k'});
    });

    test('declaring authentication without a credential is a controlled error', () {
      expect(
        () => buildDeclarativeRequest(
          spec: chkszSearchBinding.request,
          inputs: const DeclarativeInputs(keyword: 'x'),
        ),
        throwsA(
          isA<DeclarativeRequestException>().having(
            (error) => error.kind,
            'kind',
            DeclarativeRequestErrorKind.missingCredential,
          ),
        ),
      );
    });

    test('a missing required input is a controlled error', () {
      expect(
        () => buildDeclarativeRequest(
          spec: msapiSearchBinding.request,
          inputs: const DeclarativeInputs(),
        ),
        throwsA(
          isA<DeclarativeRequestException>().having(
            (error) => error.kind,
            'kind',
            DeclarativeRequestErrorKind.missingRequiredInput,
          ),
        ),
      );
    });
  });

  group('success predicate', () {
    test('ChkSz needs code+msg, not just HTTP 200', () {
      expect(
        declarativeResponseIsSuccess(
          spec: chkszSearchBinding.response.success,
          statusCode: 200,
          body: chkszSearchSample,
        ),
        isTrue,
      );
      expect(
        declarativeResponseIsSuccess(
          spec: chkszSearchBinding.response.success,
          statusCode: 200,
          body: const {'code': 403, 'msg': 'apikey=secret'},
        ),
        isFalse,
      );
    });

    test('an empty predicate list accepts any 2xx', () {
      const spec = OnlineMusicSuccessSpec();
      expect(
        declarativeResponseIsSuccess(spec: spec, statusCode: 204, body: null),
        isTrue,
      );
      expect(
        declarativeResponseIsSuccess(spec: spec, statusCode: 404, body: null),
        isFalse,
      );
    });

    test('explicit status codes override the 2xx default', () {
      const spec = OnlineMusicSuccessSpec(okStatusCodes: [200, 304]);
      expect(
        declarativeResponseIsSuccess(spec: spec, statusCode: 304, body: null),
        isTrue,
      );
      expect(
        declarativeResponseIsSuccess(spec: spec, statusCode: 201, body: null),
        isFalse,
      );
    });

    test('inList and exists work on string codes', () {
      final spec = OnlineMusicSuccessSpec(
        allOf: [
          OnlineMusicSuccessPredicate(
            path: _p('status'),
            op: OnlineMusicPredicateOp.inList,
            value: const [0, 'ok'],
          ),
        ],
      );
      expect(
        declarativeResponseIsSuccess(
          spec: spec,
          statusCode: 200,
          body: const {'status': 'ok'},
        ),
        isTrue,
      );
      expect(
        declarativeResponseIsSuccess(
          spec: spec,
          statusCode: 200,
          body: const {'status': '0'},
        ),
        isTrue,
      );
      expect(
        declarativeResponseIsSuccess(
          spec: spec,
          statusCode: 200,
          body: const {'status': 'bad'},
        ),
        isFalse,
      );
    });
  });

  group('acceptance 1: one model, two real protocols (search)', () {
    test('ChkSz sample maps to the expected search page', () {
      final page = mapDeclarativeSearchResponse(
        spec: chkszSearchBinding.response,
        body: chkszSearchSample,
        platform: MusicPlatform.netease,
        limit: 3,
        offset: 6,
      );

      expect(page.total, 291);
      expect(page.limit, 3);
      expect(page.offset, 6);
      expect(page.items, hasLength(2));
      final first = page.items.first;
      expect(first.ref, const PlatformTrackRef(platform: MusicPlatform.netease, trackId: '65800'));
      expect(first.title, '最佳损友');
      expect(first.artists, ['陈奕迅']);
      expect(first.album, 'Life Continues');
      expect(first.duration, const Duration(milliseconds: 233560));
      // asHttpsUri：与既有 ChkSz 搜索封面行为一致（http 提升为 https）。
      expect(
        first.coverUri,
        Uri.parse(
          'https://p3.music.126.net/3mi073axzjg-g-790bwBQ==/109951171836582062.jpg',
        ),
      );
    });

    test('MSAPI sample maps to the same domain model', () {
      final page = mapDeclarativeSearchResponse(
        spec: msapiSearchBinding.response,
        body: msapiSearchSample,
        platform: MusicPlatform.netease,
        limit: 30,
        offset: 0,
      );

      expect(page.total, isNull);
      expect(page.items, hasLength(1));
      final track = page.items.single;
      expect(track.ref.trackId, '347230');
      expect(track.title, '海阔天空');
      expect(track.artists, ['Beyond']);
      expect(track.album, '华纳廿三周年纪念精选系列 - Beyond');
      expect(track.duration, const Duration(milliseconds: 239560));
      // 样本里没有可见的封面字段，因此按未映射处理。
      expect(track.coverUri, isNull);
    });
  });

  group('acceptance 2: declarative stream (ChkSz real sample + fakes)', () {
    test('the ChkSz stream sample maps to a playable resolved stream', () {
      const ref = PlatformTrackRef(
        platform: MusicPlatform.netease,
        trackId: '123456',
      );
      final resolvedAt = DateTime.utc(2026, 10, 5);

      final stream = mapDeclarativeResolveResponse(
        spec: chkszStreamBinding.response,
        body: chkszStreamSample,
        expectedRef: ref,
        requestedQuality: 'lossless',
        resolvedAt: resolvedAt,
      );

      expect(stream.ref, ref);
      expect(stream.uri, Uri.parse('https://media.invalid/test.flac'));
      expect(stream.requestedQuality, 'lossless');
      expect(stream.actualQuality, 'lossless');
      expect(stream.bitrate, 1000000);
      expect(stream.coverUri, Uri.parse('https://cover.invalid/test.jpg'));
      expect(stream.resolvedAt, resolvedAt);
      expect(stream.isExpiredAt(resolvedAt), isFalse);
    });

    test('a mismatched track id is rejected instead of playing the wrong song', () {
      const ref = PlatformTrackRef(
        platform: MusicPlatform.netease,
        trackId: '999999',
      );

      expect(
        () => mapDeclarativeResolveResponse(
          spec: chkszStreamBinding.response,
          body: chkszStreamSample,
          expectedRef: ref,
          requestedQuality: 'lossless',
          resolvedAt: DateTime.utc(2026, 10, 5),
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });
  });

  group('mapping failure paths', () {
    test('a missing required field is reported, not guessed', () {
      final body = <String, Object?>{
        'code': 200,
        'data': {
          'songs': [
            {'name': 'no id here'},
          ],
          'total': 1,
        },
      };

      expect(
        () => mapDeclarativeSearchResponse(
          spec: chkszSearchBinding.response,
          body: body,
          platform: MusicPlatform.netease,
          limit: 30,
          offset: 0,
        ),
        throwsA(
          isA<DeclarativeMappingException>().having(
            (error) => error.reason,
            'reason',
            contains('trackId'),
          ),
        ),
      );
    });

    test('a list path that is not an array is reported', () {
      expect(
        () => mapDeclarativeSearchResponse(
          spec: chkszSearchBinding.response,
          body: const {'code': 200, 'data': {'songs': 'nope'}},
          platform: MusicPlatform.netease,
          limit: 30,
          offset: 0,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });

    test('optional fields fall back to defaults instead of failing', () {
      final body = <String, Object?>{
        'code': 200,
        'data': {
          'songs': [
            {'id': 1, 'name': 'only the essentials'},
          ],
        },
      };

      final page = mapDeclarativeSearchResponse(
        spec: chkszSearchBinding.response,
        body: body,
        platform: MusicPlatform.netease,
        limit: 30,
        offset: 0,
      );

      final track = page.items.single;
      expect(track.artists, isEmpty);
      expect(track.album, '');
      expect(track.coverUri, isNull);
      expect(track.duration, Duration.zero);
      expect(page.total, isNull);
    });

    test('firstOf picks the first usable candidate path', () {
      final spec = OnlineMusicResponseSpec(
        listPath: _p('result.songs'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('songId'), _p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('songName'), _p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      );

      final page = mapDeclarativeSearchResponse(
        spec: spec,
        body: const {
          'result': {
            'songs': [
              {'songId': 7, 'name': 'second candidate'},
            ],
          },
        },
        platform: MusicPlatform.netease,
        limit: 30,
        offset: 0,
      );

      expect(page.items.single.ref.trackId, '7');
      expect(page.items.single.title, 'second candidate');
    });
  });
}
