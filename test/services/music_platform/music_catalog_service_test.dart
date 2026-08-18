import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';

void main() {
  test('builds and maps a paged NetEase search', () async {
    final transport = _FakeTransport(
      (_, _) async =>
          ChkszTransportResponse(statusCode: 200, data: _searchBody()),
    );
    final service = MusicCatalogService(client: _client(transport));
    final token = ChkszCancelToken();

    final page = await service.searchNetease(
      keyword: 'Test Track',
      limit: 3,
      offset: 6,
      cancelToken: token,
    );

    final sent = transport.requests.single;
    expect(transport.cancelTokens.single, same(token));
    expect(sent.path, '/api/163_search');
    expect(sent.queryParameters, {
      'keyword': 'Test Track',
      'limit': '3',
      'offset': '6',
      'apikey': _fakeApiKey,
    });
    expect(page.platform, MusicPlatform.netease);
    expect(page.limit, 3);
    expect(page.offset, 6);
    expect(page.total, 31);
    expect(page.items.single.ref.trackId, '123456');
    expect(page.items.single.title, 'Test Track');
  });

  test('rejects invalid searches before transport', () async {
    final transport = _FakeTransport(
      (_, _) async =>
          ChkszTransportResponse(statusCode: 200, data: _searchBody()),
    );
    final service = MusicCatalogService(client: _client(transport));

    await expectLater(
      service.searchNetease(keyword: '   ', cancelToken: ChkszCancelToken()),
      throwsArgumentError,
    );
    await expectLater(
      service.searchNetease(
        keyword: 'test',
        limit: 0,
        cancelToken: ChkszCancelToken(),
      ),
      throwsArgumentError,
    );
    await expectLater(
      service.searchNetease(
        keyword: 'test',
        offset: -1,
        cancelToken: ChkszCancelToken(),
      ),
      throwsArgumentError,
    );
    expect(transport.requests, isEmpty);
  });

  test('builds and maps a complete NetEase playlist snapshot', () async {
    final transport = _FakeTransport(
      (_, _) async =>
          ChkszTransportResponse(statusCode: 200, data: _playlistBody()),
    );
    final service = MusicCatalogService(client: _client(transport));
    final token = ChkszCancelToken();

    final playlist = await service.fetchNeteasePlaylist(
      playlistId: '5202687076',
      cancelToken: token,
    );

    final sent = transport.requests.single;
    expect(transport.cancelTokens.single, same(token));
    expect(sent.path, '/api/163_playlist');
    expect(sent.queryParameters, {
      'id': '5202687076',
      'apikey': _fakeApiKey,
    });
    expect(playlist.id, '5202687076');
    expect(playlist.tracks, hasLength(2));
  });

  test('honours playlist cancellation before and after transport', () async {
    final response = Completer<ChkszTransportResponse>();
    final transport = _FakeTransport((_, _) => response.future);
    final service = MusicCatalogService(client: _client(transport));
    final cancelledBefore = ChkszCancelToken()..cancel();

    final earlyError = await _captureChkszException(
      service.fetchNeteasePlaylist(
        playlistId: '5202687076',
        cancelToken: cancelledBefore,
      ),
    );
    expect(earlyError.kind, ChkszErrorKind.cancelled);
    expect(transport.requests, isEmpty);

    final token = ChkszCancelToken();
    final future = service.fetchNeteasePlaylist(
      playlistId: '5202687076',
      cancelToken: token,
    );
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    response.complete(
      ChkszTransportResponse(statusCode: 200, data: _playlistBody()),
    );

    final lateError = await _captureChkszException(future);
    expect(lateError.kind, ChkszErrorKind.cancelled);
    expect(transport.cancelTokens.single, same(token));
  });

  test('honours cancellation before and after transport', () async {
    final response = Completer<ChkszTransportResponse>();
    final transport = _FakeTransport((_, _) => response.future);
    final service = MusicCatalogService(client: _client(transport));
    final cancelledBefore = ChkszCancelToken()..cancel();

    final earlyError = await _captureChkszException(
      service.searchNetease(keyword: 'test', cancelToken: cancelledBefore),
    );
    expect(earlyError.kind, ChkszErrorKind.cancelled);
    expect(transport.requests, isEmpty);

    final token = ChkszCancelToken();
    final future = service.searchNetease(keyword: 'test', cancelToken: token);
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    response.complete(
      ChkszTransportResponse(statusCode: 200, data: _searchBody()),
    );

    final lateError = await _captureChkszException(future);
    expect(lateError.kind, ChkszErrorKind.cancelled);
    expect(transport.cancelTokens.single, same(token));
  });

  test('preserves safe HTTP and business errors', () async {
    const secret = 'chksz_SECRET_TEST_ONLY';
    final responses = [
      ChkszTransportResponse(
        statusCode: 503,
        data: const {'msg': 'apikey=$secret'},
      ),
      ChkszTransportResponse(
        statusCode: 200,
        data: const {'code': 403, 'msg': 'apikey=$secret'},
      ),
    ];
    final expectedKinds = [
      ChkszErrorKind.unavailable,
      ChkszErrorKind.businessFailure,
    ];

    for (var index = 0; index < responses.length; index++) {
      final transport = _FakeTransport((_, _) async => responses[index]);
      final service = MusicCatalogService(client: _client(transport));
      final error = await _captureChkszException(
        service.searchNetease(keyword: 'test', cancelToken: ChkszCancelToken()),
      );

      expect(error.kind, expectedKinds[index]);
      expect(error.toString(), isNot(contains(secret)));
    }
  });

  test('preserves safe errors for invalid search responses', () async {
    const secretUrl =
        'https://cover.invalid/test.jpg?signature=SECRET_TEST_ONLY';
    final responses = [
      const <String, dynamic>{'code': 200, 'msg': 'success'},
      const <String, dynamic>{
        'code': 200,
        'msg': 'success',
        'data': {'songs': 'invalid', 'total': 1},
      },
      _searchBody(id: 'invalid', coverUrl: secretUrl),
    ];

    for (final body in responses) {
      final transport = _FakeTransport(
        (_, _) async => ChkszTransportResponse(statusCode: 200, data: body),
      );
      final service = MusicCatalogService(client: _client(transport));
      final error = await _captureChkszException(
        service.searchNetease(keyword: 'test', cancelToken: ChkszCancelToken()),
      );

      expect(error.kind, ChkszErrorKind.invalidResponse);
      expect(error.toString(), isNot(contains(secretUrl)));
      expect(error.safeMessage, isNot(contains(secretUrl)));
    }
  });
}

ChkszClient _client(_FakeTransport transport) {
  return ChkszClient(
    transport: transport,
    credentialProvider: InMemoryChkszCredentialProvider(
      initialApiKey: _fakeApiKey,
    ),
  );
}

Map<String, dynamic> _searchBody({
  Object id = 123456,
  String coverUrl = 'https://cover.invalid/test.jpg',
}) => {
  'code': 200,
  'msg': 'success',
  'data': {
    'songs': [
      {
        'id': id,
        'name': 'Test Track',
        'artists': 'Test Artist',
        'album': 'Test Album',
        'picUrl': coverUrl,
        'duration': 123456,
      },
    ],
    'total': 31,
  },
};

Map<String, dynamic> _playlistBody() => {
  'code': 200,
  'msg': 'success',
  'data': {
    'id': 5202687076,
    'name': 'Test Playlist',
    'trackCount': 2,
    'tracks': [
      {
        'id': 123456,
        'name': 'Test Track',
        'ar': [{'name': 'Test Artist'}],
        'al': {'name': 'Test Album'},
      },
      {
        'id': 654321,
        'name': 'Second Track',
        'ar': [{'name': 'Second Artist'}],
        'al': {'name': 'Second Album'},
      },
    ],
  },
};

Future<ChkszException> _captureChkszException(Future<Object?> future) async {
  try {
    await future;
  } on ChkszException catch (error) {
    return error;
  }
  throw StateError('Expected ChkszException');
}

typedef _TransportHandler =
    Future<ChkszTransportResponse> Function(
      ChkszAuthorizedRequest request,
      ChkszCancelToken cancelToken,
    );

final class _FakeTransport implements ChkszTransport {
  _FakeTransport(this._handler);

  final _TransportHandler _handler;
  final List<ChkszAuthorizedRequest> requests = [];
  final List<ChkszCancelToken> cancelTokens = [];

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) {
    requests.add(request);
    cancelTokens.add(cancelToken);
    return _handler(request, cancelToken);
  }
}
