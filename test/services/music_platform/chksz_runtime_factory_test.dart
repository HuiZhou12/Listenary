import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

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

  // ⚠️ 语义变更（F0-3 / P-18）：旧实现 `normalizeOnlineMusicBaseUrl` 会把**非法**
  // 地址一律改写成 `https://api.chksz.com`，于是用户带着自己的凭据打到了一台
  // 他从未指定的主机上。现在非法值**原样保留并报错**，只有"缺失"才回落默认值。
  // 这条测试因此被改写 —— 它固化的正是被修掉的那个缺陷行为。
  test('distinguishes a missing base URL from an explicitly invalid one', () {
    // 缺失 ⇒ 用默认值（旧配置行为不变）。
    expect(explicitOnlineMusicBaseUrl(null), isNull);
    expect(explicitOnlineMusicBaseUrl(''), isNull);
    expect(explicitOnlineMusicBaseUrl('   '), isNull);
    expect(
      OnlineMusicProviderDefinition.defaults.effectiveBaseUrl,
      defaultOnlineMusicBaseUrl,
    );

    // 显式提供 ⇒ 原样保留，**不替换**。
    expect(explicitOnlineMusicBaseUrl(' https://api.invalid '), 'https://api.invalid');
    expect(explicitOnlineMusicBaseUrl('ftp://api.invalid'), 'ftp://api.invalid');
    expect(explicitOnlineMusicBaseUrl('/relative/path'), '/relative/path');

    // 非法 ⇒ 给出明确原因，绝不回落。
    expect(onlineMusicBaseUrlIssue('ftp://api.invalid'), isNotNull);
    expect(onlineMusicBaseUrlIssue('/relative/path'), isNotNull);
    expect(onlineMusicBaseUrlIssue('https://'), isNotNull);
    expect(onlineMusicBaseUrlIssue('https://api.invalid'), isNull);
    expect(onlineMusicBaseUrlIssue('http://127.0.0.1:8080'), isNull);
    // 空串 = 缺失 ⇒ 不算非法（这是"不破坏合法旧配置"的那一半）。
    expect(onlineMusicBaseUrlIssue(''), isNull);
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
