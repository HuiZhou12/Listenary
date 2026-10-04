import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';

void main() {
  test('creates production Dio with the confirmed fixed options', () {
    final dio = createChkszDio();
    addTearDown(() => dio.close(force: true));

    expect(dio.options.baseUrl, ChkszProviderConfig.defaults.baseUrl);
    expect(dio.options.baseUrl, 'https://api.chksz.com');
    expect(dio.options.connectTimeout, const Duration(seconds: 8));
    expect(dio.options.sendTimeout, const Duration(seconds: 8));
    expect(dio.options.receiveTimeout, const Duration(seconds: 10));
    expect(dio.interceptors.whereType<LogInterceptor>(), isEmpty);
  });

  test('applies an independently configured connection', () {
    const config = ChkszProviderConfig(
      baseUrl: 'https://mirror.invalid:8443',
      connectTimeout: Duration(seconds: 2),
      sendTimeout: Duration(seconds: 3),
      receiveTimeout: Duration(seconds: 4),
    );
    final dio = createChkszDio(config: config);
    addTearDown(() => dio.close(force: true));

    expect(dio.options.baseUrl, 'https://mirror.invalid:8443');
    expect(dio.options.connectTimeout, const Duration(seconds: 2));
    expect(dio.options.sendTimeout, const Duration(seconds: 3));
    expect(dio.options.receiveTimeout, const Duration(seconds: 4));
  });

  test('normalizes an unusable base URL back to the default', () {
    expect(normalizeOnlineMusicBaseUrl(null), defaultOnlineMusicBaseUrl);
    expect(normalizeOnlineMusicBaseUrl(''), defaultOnlineMusicBaseUrl);
    expect(normalizeOnlineMusicBaseUrl('   '), defaultOnlineMusicBaseUrl);
    expect(
      normalizeOnlineMusicBaseUrl('ftp://api.invalid'),
      defaultOnlineMusicBaseUrl,
    );
    expect(
      normalizeOnlineMusicBaseUrl('/relative/path'),
      defaultOnlineMusicBaseUrl,
    );
    expect(normalizeOnlineMusicBaseUrl('https://'), defaultOnlineMusicBaseUrl);
    expect(
      normalizeOnlineMusicBaseUrl(' https://api.invalid '),
      'https://api.invalid',
    );
    expect(
      normalizeOnlineMusicBaseUrl('http://127.0.0.1:8080'),
      'http://127.0.0.1:8080',
    );
  });

  test('normalizes unusable timeouts back to the defaults', () {
    expect(
      normalizeOnlineMusicTimeout(
        null,
        defaultValue: defaultOnlineMusicConnectTimeout,
      ),
      defaultOnlineMusicConnectTimeout,
    );
    expect(
      normalizeOnlineMusicTimeout(
        0,
        defaultValue: defaultOnlineMusicSendTimeout,
      ),
      defaultOnlineMusicSendTimeout,
    );
    expect(
      normalizeOnlineMusicTimeout(
        -5,
        defaultValue: defaultOnlineMusicReceiveTimeout,
      ),
      defaultOnlineMusicReceiveTimeout,
    );
    expect(
      normalizeOnlineMusicTimeout(
        'abc',
        defaultValue: defaultOnlineMusicSendTimeout,
      ),
      defaultOnlineMusicSendTimeout,
    );
    expect(
      normalizeOnlineMusicTimeout(
        '2500',
        defaultValue: defaultOnlineMusicSendTimeout,
      ),
      const Duration(milliseconds: 2500),
    );
    expect(
      normalizeOnlineMusicTimeout(
        1500,
        defaultValue: defaultOnlineMusicSendTimeout,
      ),
      const Duration(milliseconds: 1500),
    );
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
