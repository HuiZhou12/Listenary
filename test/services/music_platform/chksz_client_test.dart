import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/index.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';

void main() {
  group('ChkszRequest', () {
    test('validates only the confirmed local key rules', () {
      expect(isValidChkszApiKeyFormat(_fakeApiKey), isTrue);
      expect(isValidChkszApiKeyFormat('chksz_测试'), isTrue);
      expect(isValidChkszApiKeyFormat('chksz_'), isFalse);
      expect(isValidChkszApiKeyFormat('other_TEST_ONLY'), isFalse);
      expect(isValidChkszApiKeyFormat('chksz_TEST ONLY'), isFalse);
    });

    test('rejects caller-supplied API keys and unsafe paths', () {
      expect(
        () => ChkszRequest(
          path: '/api/search',
          queryParameters: const {'ApiKey': _fakeApiKey},
        ),
        throwsArgumentError,
      );
      expect(
        () => ChkszRequest(path: '/api/search?keyword=test'),
        throwsArgumentError,
      );
    });
  });

  group('ChkszClient', () {
    test('injects the key only at the transport boundary', () async {
      final transport = _FakeTransport(
        (request, _) async => ChkszTransportResponse(
          statusCode: 200,
          data: const {'code': 200, 'msg': 'ok'},
        ),
      );
      final client = _client(transport);

      await client.sendJson(
        ChkszRequest(
          path: '/api/search',
          queryParameters: const {'keyword': 'test'},
        ),
        isBusinessSuccess: (body) => body['code'] == 200,
      );

      final sent = transport.requests.single;
      expect(sent.queryParameters['keyword'], 'test');
      expect(sent.queryParameters['apikey'], _fakeApiKey);
      expect(sent.toString(), isNot(contains(_fakeApiKey)));
      expect(sent.toString(), isNot(contains('keyword=test')));
    });

    test('reads the current credential for every request', () async {
      final credentials = InMemoryChkszCredentialProvider(
        initialApiKey: _fakeApiKey,
      );
      final transport = _FakeTransport(
        (_, _) async =>
            ChkszTransportResponse(statusCode: 200, data: const {'ok': true}),
      );
      final client = ChkszClient(
        transport: transport,
        credentialProvider: credentials,
      );

      await client.sendJson(
        ChkszRequest(path: '/api/search'),
        isBusinessSuccess: (body) => body['ok'] == true,
      );
      await credentials.writeApiKey('chksz_REPLACED_TEST_ONLY');
      await client.sendJson(
        ChkszRequest(path: '/api/search'),
        isBusinessSuccess: (body) => body['ok'] == true,
      );
      await credentials.clearApiKey();
      final exception = await _captureException(
        client.sendJson(
          ChkszRequest(path: '/api/search'),
          isBusinessSuccess: (body) => body['ok'] == true,
        ),
      );

      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.queryParameters['apikey'], _fakeApiKey);
      expect(
        transport.requests.last.queryParameters['apikey'],
        'chksz_REPLACED_TEST_ONLY',
      );
      expect(exception.kind, ChkszErrorKind.unauthorized);
    });

    test('parses quota headers case-insensitively', () async {
      final client = _client(
        _FakeTransport(
          (_, _) async => ChkszTransportResponse(
            statusCode: 200,
            data: const {'ok': true},
            headers: const {
              'x-ratelimit-limit': ['20'],
              'X-QUOTA-FREE-REMAINING': ['49'],
              'X-Quota-Paid-Remaining': ['-1'],
            },
          ),
        ),
      );

      final response = await client.sendJson(
        ChkszRequest(path: '/api/search'),
        isBusinessSuccess: (body) => body['ok'] == true,
      );

      expect(response.quota.rateLimit, 20);
      expect(response.quota.freeRemaining, 49);
      expect(response.quota.paidRemaining, isNull);
      expect(response.quota.hasData, isTrue);
    });

    test('maps supported HTTP statuses without leaking response secrets', () {
      const expected = <int, ChkszErrorKind>{
        400: ChkszErrorKind.badRequest,
        401: ChkszErrorKind.unauthorized,
        402: ChkszErrorKind.quotaExhausted,
        403: ChkszErrorKind.forbidden,
        404: ChkszErrorKind.notFound,
        429: ChkszErrorKind.rateLimited,
        503: ChkszErrorKind.unavailable,
      };

      for (final entry in expected.entries) {
        final exception = ChkszException.fromResponse(
          statusCode: entry.key,
          data: const {'msg': 'apikey=$_fakeApiKey'},
        );

        expect(exception.kind, entry.value);
        expect(exception.statusCode, entry.key);
        expect(exception.toString(), isNot(contains(_fakeApiKey)));
      }
    });

    test('maps business failure and redacts its message', () async {
      final client = _client(
        _FakeTransport(
          (_, _) async => ChkszTransportResponse(
            statusCode: 200,
            data: const {
              'code': 403,
              'msg': 'https://api.invalid/search?apikey=$_fakeApiKey',
            },
          ),
        ),
      );

      final exception = await _captureException(
        client.sendJson(
          ChkszRequest(path: '/api/search'),
          isBusinessSuccess: (body) => body['code'] == 200,
        ),
      );

      expect(exception.kind, ChkszErrorKind.businessFailure);
      expect(exception.safeMessage, contains('?[redacted]'));
      expect(exception.toString(), isNot(contains(_fakeApiKey)));
    });

    test('rejects a successful response with a non-object body', () async {
      final client = _client(
        _FakeTransport(
          (_, _) async => ChkszTransportResponse(
            statusCode: 200,
            data: const ['not', 'an', 'object'],
          ),
        ),
      );

      final exception = await _captureException(
        client.sendJson(
          ChkszRequest(path: '/api/search'),
          isBusinessSuccess: (_) => true,
        ),
      );

      expect(exception.kind, ChkszErrorKind.invalidResponse);
    });

    test('retries 429 exactly once when Retry-After is valid', () async {
      final delays = <Duration>[];
      final transport = _FakeTransport((_, _) async {
        if (delays.isEmpty) {
          return ChkszTransportResponse(
            statusCode: 429,
            data: const {'msg': 'slow down'},
            headers: const {
              'Retry-After': ['2'],
            },
          );
        }
        return ChkszTransportResponse(
          statusCode: 200,
          data: const {'ok': true},
        );
      });
      final client = _client(
        transport,
        delay: (duration) async => delays.add(duration),
      );

      final response = await client.sendJson(
        ChkszRequest(path: '/api/search'),
        isBusinessSuccess: (body) => body['ok'] == true,
      );

      expect(response.body['ok'], isTrue);
      expect(delays, [const Duration(seconds: 2)]);
      expect(transport.requests, hasLength(2));
    });

    test('does not retry 429 without a valid Retry-After', () async {
      final transport = _FakeTransport(
        (_, _) async => ChkszTransportResponse(
          statusCode: 429,
          data: const {'msg': 'slow down'},
          headers: const {
            'Retry-After': ['invalid'],
          },
        ),
      );
      final client = _client(transport);

      final exception = await _captureException(
        client.sendJson(
          ChkszRequest(path: '/api/search'),
          isBusinessSuccess: (_) => true,
        ),
      );

      expect(exception.kind, ChkszErrorKind.rateLimited);
      expect(transport.requests, hasLength(1));
    });

    test('cancels before calling the transport', () async {
      final transport = _FakeTransport(
        (_, _) async =>
            ChkszTransportResponse(statusCode: 200, data: const {'ok': true}),
      );
      final token = ChkszCancelToken()..cancel();

      final exception = await _captureException(
        _client(transport).sendJson(
          ChkszRequest(path: '/api/search'),
          isBusinessSuccess: (_) => true,
          cancelToken: token,
        ),
      );

      expect(exception.kind, ChkszErrorKind.cancelled);
      expect(transport.requests, isEmpty);
    });

    test('cancels while waiting to retry', () async {
      final delayStarted = Completer<void>();
      final token = ChkszCancelToken();
      final transport = _FakeTransport(
        (_, _) async => ChkszTransportResponse(
          statusCode: 429,
          data: const {'msg': 'slow down'},
          headers: const {
            'Retry-After': ['2'],
          },
        ),
      );
      final future =
          _client(
            transport,
            delay: (_) {
              delayStarted.complete();
              return Completer<void>().future;
            },
          ).sendJson(
            ChkszRequest(path: '/api/search'),
            isBusinessSuccess: (_) => true,
            cancelToken: token,
          );

      await delayStarted.future;
      token.cancel();
      final exception = await _captureException(future);

      expect(exception.kind, ChkszErrorKind.cancelled);
      expect(transport.requests, hasLength(1));
    });

    test('converts transport failures to safe network errors', () async {
      final client = _client(
        _FakeTransport(
          (_, _) => throw StateError(
            'request failed: https://api.invalid?apikey=$_fakeApiKey',
          ),
        ),
      );

      final exception = await _captureException(
        client.sendJson(
          ChkszRequest(path: '/api/search'),
          isBusinessSuccess: (_) => true,
        ),
      );

      expect(exception.kind, ChkszErrorKind.network);
      expect(exception.toString(), isNot(contains(_fakeApiKey)));
      expect(exception.toString(), isNot(contains('api.invalid')));
    });
  });
}

ChkszClient _client(_FakeTransport transport, {ChkszDelay? delay}) {
  return ChkszClient(
    transport: transport,
    credentialProvider: InMemoryChkszCredentialProvider(
      initialApiKey: _fakeApiKey,
    ),
    delay: delay,
  );
}

Future<ChkszException> _captureException(Future<Object?> future) async {
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

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) {
    requests.add(request);
    return _handler(request, cancelToken);
  }
}
