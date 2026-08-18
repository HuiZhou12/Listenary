import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';

void main() {
  test('maps structured requests and all HTTP responses', () async {
    final adapter = _FakeDioAdapter(
      (options, _) async => ResponseBody.fromString(
        jsonEncode({'code': 503, 'msg': 'unavailable'}),
        503,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          'x-test-multi': ['first', 'second'],
        },
      ),
    );
    final transport = ChkszDioTransport(dio: _dio(adapter));
    final request = ChkszRequest(
      path: '/api/163_search',
      queryParameters: const {'keyword': 'Test Track'},
    ).authorize(_fakeApiKey);

    final response = await transport.send(
      request,
      cancelToken: ChkszCancelToken(),
    );

    final sent = adapter.requests.single;
    expect(sent.method, 'GET');
    expect(sent.uri.scheme, 'https');
    expect(sent.uri.host, 'api.chksz.com');
    expect(sent.path, '/api/163_search');
    expect(sent.queryParameters, {
      'keyword': 'Test Track',
      'apikey': _fakeApiKey,
    });
    expect(response.statusCode, 503);
    expect(response.data, {'code': 503, 'msg': 'unavailable'});
    expect(response.headers['x-test-multi'], ['first', 'second']);
  });

  test('preserves the authorized request method', () async {
    final adapter = _FakeDioAdapter(
      (_, _) async => ResponseBody.fromString(
        jsonEncode({'code': 200}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
    final transport = ChkszDioTransport(dio: _dio(adapter));
    final request = ChkszRequest(
      path: '/api/test',
      method: ChkszHttpMethod.post,
    ).authorize(_fakeApiKey);

    await transport.send(request, cancelToken: ChkszCancelToken());

    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.data, isNull);
  });

  test('bridges cancellation to Dio and the client safe error', () async {
    final cancellationObserved = Completer<void>();
    final adapter = _FakeDioAdapter((_, cancelFuture) {
      cancelFuture?.then((_) {
        if (!cancellationObserved.isCompleted) {
          cancellationObserved.complete();
        }
      });
      return Completer<ResponseBody>().future;
    });
    final client = _client(ChkszDioTransport(dio: _dio(adapter)));
    final token = ChkszCancelToken();

    final future = client.sendJson(
      ChkszRequest(path: '/api/163_search'),
      isBusinessSuccess: (_) => true,
      cancelToken: token,
    );
    while (adapter.requests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    token.cancel();

    final error = await _captureChkszException(future);
    expect(error.kind, ChkszErrorKind.cancelled);
    await cancellationObserved.future;
  });

  test('keeps Dio failures safe through ChkszClient', () async {
    const secret = 'chksz_SECRET_TEST_ONLY';
    final adapter = _FakeDioAdapter((options, _) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'https://api.chksz.com/api/test?apikey=$secret',
      );
    });
    final client = _client(ChkszDioTransport(dio: _dio(adapter)));

    final error = await _captureChkszException(
      client.sendJson(
        ChkszRequest(path: '/api/163_search'),
        isBusinessSuccess: (_) => true,
      ),
    );

    expect(error.kind, ChkszErrorKind.network);
    expect(error.toString(), isNot(contains(secret)));
    expect(error.toString(), isNot(contains('api.chksz.com')));
  });
}

Dio _dio(HttpClientAdapter adapter) {
  return Dio(BaseOptions(baseUrl: 'https://api.chksz.com'))
    ..httpClientAdapter = adapter;
}

ChkszClient _client(ChkszTransport transport) {
  return ChkszClient(
    transport: transport,
    credentialProvider: InMemoryChkszCredentialProvider(
      initialApiKey: _fakeApiKey,
    ),
  );
}

Future<ChkszException> _captureChkszException(Future<Object?> future) async {
  try {
    await future;
  } on ChkszException catch (error) {
    return error;
  }
  throw StateError('Expected ChkszException');
}

typedef _AdapterHandler =
    Future<ResponseBody> Function(
      RequestOptions options,
      Future<void>? cancelFuture,
    );

final class _FakeDioAdapter implements HttpClientAdapter {
  _FakeDioAdapter(this._handler);

  final _AdapterHandler _handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return _handler(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
