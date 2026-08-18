import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';
const _ref = PlatformTrackRef(
  platform: MusicPlatform.netease,
  trackId: '123456',
);

void main() {
  final resolvedAt = DateTime.utc(2026, 8, 14, 12);

  test('implements the remote resolver contract and maps a stream', () async {
    final transport = _FakeTransport(
      (request, _) async =>
          ChkszTransportResponse(statusCode: 200, data: _resolveBody()),
    );
    final service = NeteaseStreamResolver(
      client: _client(transport),
      clock: () => resolvedAt,
    );
    final RemoteStreamResolver resolver = service.resolve;
    final token = ChkszCancelToken();

    final stream = await resolver(
      _ref,
      requestedQuality: NeteaseAdapter.defaultQuality,
      cancelToken: token,
    );

    final sent = transport.requests.single;
    expect(transport.cancelTokens.single, same(token));
    expect(sent.path, '/api/163_music');
    expect(sent.queryParameters, {
      'id': '123456',
      'level': 'lossless',
      'type': 'json',
      'apikey': _fakeApiKey,
    });
    expect(stream.ref, _ref);
    expect(stream.uri, Uri.parse('https://media.invalid/test.flac'));
    expect(stream.requestedQuality, 'lossless');
    expect(stream.actualQuality, 'lossless');
    expect(stream.bitrate, 1000000);
    expect(stream.resolvedAt, resolvedAt);
    expect(stream.expiresAt, isNull);
  });

  test('rejects unsupported quality and invalid references locally', () async {
    final transport = _FakeTransport(
      (_, _) async =>
          ChkszTransportResponse(statusCode: 200, data: _resolveBody()),
    );
    final resolver = NeteaseStreamResolver(client: _client(transport));

    final qualityError = await _captureChkszException(
      resolver.resolve(
        _ref,
        requestedQuality: 'standard',
        cancelToken: ChkszCancelToken(),
      ),
    );
    expect(qualityError.kind, ChkszErrorKind.businessFailure);
    await expectLater(
      resolver.resolve(
        const PlatformTrackRef(platform: MusicPlatform.qq, trackId: '123456'),
        requestedQuality: 'lossless',
        cancelToken: ChkszCancelToken(),
      ),
      throwsArgumentError,
    );
    await expectLater(
      resolver.resolve(
        const PlatformTrackRef(
          platform: MusicPlatform.netease,
          trackId: 'track',
        ),
        requestedQuality: 'lossless',
        cancelToken: ChkszCancelToken(),
      ),
      throwsArgumentError,
    );
    expect(transport.requests, isEmpty);
  });

  test(
    'uses the same token and honours cancellation after transport',
    () async {
      final response = Completer<ChkszTransportResponse>();
      final transport = _FakeTransport((_, _) => response.future);
      final resolver = NeteaseStreamResolver(client: _client(transport));
      final token = ChkszCancelToken();

      final future = resolver.resolve(
        _ref,
        requestedQuality: 'lossless',
        cancelToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      response.complete(
        ChkszTransportResponse(statusCode: 200, data: _resolveBody()),
      );

      final error = await _captureChkszException(future);
      expect(error.kind, ChkszErrorKind.cancelled);
      expect(transport.cancelTokens.single, same(token));
    },
  );

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
      final resolver = NeteaseStreamResolver(client: _client(transport));
      final error = await _captureChkszException(
        resolver.resolve(
          _ref,
          requestedQuality: 'lossless',
          cancelToken: ChkszCancelToken(),
        ),
      );

      expect(error.kind, expectedKinds[index]);
      expect(error.toString(), isNot(contains(secret)));
    }
  });

  test('preserves safe adapter errors for invalid stream responses', () async {
    const secretUrl =
        'https://media.invalid/test.flac?signature=SECRET_TEST_ONLY';
    final responses = [
      _resolveBody(level: 'standard', url: secretUrl),
      _resolveBody(id: 654321, url: secretUrl),
      _resolveBody(url: 'not-an-http-url'),
    ];
    final expectedKinds = [
      ChkszErrorKind.businessFailure,
      ChkszErrorKind.invalidResponse,
      ChkszErrorKind.invalidResponse,
    ];

    for (var index = 0; index < responses.length; index++) {
      final transport = _FakeTransport(
        (_, _) async =>
            ChkszTransportResponse(statusCode: 200, data: responses[index]),
      );
      final resolver = NeteaseStreamResolver(client: _client(transport));
      final error = await _captureChkszException(
        resolver.resolve(
          _ref,
          requestedQuality: 'lossless',
          cancelToken: ChkszCancelToken(),
        ),
      );

      expect(error.kind, expectedKinds[index]);
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

Map<String, dynamic> _resolveBody({
  int id = 123456,
  String url = 'https://media.invalid/test.flac',
  int bitrate = 1000000,
  String level = 'lossless',
}) => {
  'code': 200,
  'msg': 'success',
  'data': {'id': id, 'url': url, 'br': bitrate, 'level': level},
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
