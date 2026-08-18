import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';

void main() {
  test('creates production Dio with the confirmed fixed options', () {
    final dio = createChkszDio();
    addTearDown(() => dio.close(force: true));

    expect(dio.options.baseUrl, chkszBaseUrl);
    expect(dio.options.baseUrl, 'https://api.chksz.com');
    expect(dio.options.connectTimeout, const Duration(seconds: 8));
    expect(dio.options.sendTimeout, const Duration(seconds: 8));
    expect(dio.options.receiveTimeout, const Duration(seconds: 10));
    expect(dio.interceptors.whereType<LogInterceptor>(), isEmpty);
  });

  test(
    'creates one runtime without requesting and owns Dio disposal',
    () async {
      final adapter = _RecordingDioAdapter();
      final dio = createChkszDio()..httpClientAdapter = adapter;
      final credentials = InMemoryChkszCredentialProvider(
        initialApiKey: _fakeApiKey,
      );
      final runtime = createChkszRuntime(
        credentialProvider: credentials,
        dio: dio,
      );

      expect(adapter.requestCount, 0);
      expect(await runtime.readApiKey(), _fakeApiKey);
      runtime.dispose();
      runtime.dispose();

      expect(adapter.closeCount, 1);
      expect(adapter.forceClosed, isTrue);
      expect(await credentials.readApiKey(), _fakeApiKey);
    },
  );
}

final class _RecordingDioAdapter implements HttpClientAdapter {
  int requestCount = 0;
  int closeCount = 0;
  bool forceClosed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requestCount++;
    throw StateError('Runtime construction must not send a request');
  }

  @override
  void close({bool force = false}) {
    closeCount++;
    forceClosed = force;
  }
}
