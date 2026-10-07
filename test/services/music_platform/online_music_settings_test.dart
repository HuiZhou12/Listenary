import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';

void main() {
  group('OnlineMusicSettings defaults', () {
    test('falls back to the confirmed default provider', () {
      final settings = OnlineMusicSettings.fromJson(null);

      expect(settings.providers, hasLength(1));
      final provider = settings.providers.single;
      expect(provider.id, defaultOnlineMusicProviderId);
      expect(provider.protocol, defaultOnlineMusicProtocol);
      expect(provider.baseUrl, 'https://api.chksz.com');
      expect(provider.connectTimeout, const Duration(seconds: 8));
      expect(provider.sendTimeout, const Duration(seconds: 8));
      expect(provider.receiveTimeout, const Duration(seconds: 10));
      expect(
        provider.credentialReference,
        OnlineMusicProviderDefinition.defaultCredentialReference,
      );
      expect(provider.parameterName, 'apikey');
      expect(settings.defaultProviderId, defaultOnlineMusicProviderId);
      expect(settings.capabilityProviders, isEmpty);
      for (final capability in OnlineMusicCapability.values) {
        expect(provider.authFor(capability), isA<OnlineMusicApiKeyAuth>());
      }
    });

    test('treats a non-map configuration as absent', () {
      for (final value in <Object?>['text', 1, <Object?>[]]) {
        expect(OnlineMusicSettings.fromJson(value).providers, hasLength(1));
      }
    });
  });

  group('OnlineMusicSettings providers', () {
    test(
      'an empty or fully invalid provider list falls back to the default',
      () {
        expect(
          OnlineMusicSettings.fromJson({
            'providers': <Object?>[],
          }).providers.single.id,
          defaultOnlineMusicProviderId,
        );
        expect(
          OnlineMusicSettings.fromJson({
            'providers': [
              'text',
              {'protocol': 'chksz'},
              {'id': '   '},
            ],
          }).providers.single.id,
          defaultOnlineMusicProviderId,
        );
      },
    );

    test('an unknown protocol is ignored', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'custom', 'protocol': 'other'},
          {'id': 'chksz'},
        ],
      });

      expect(settings.providers.map((provider) => provider.id), ['chksz']);
    });

    test('a duplicated id keeps the first definition', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'a', 'baseUrl': 'https://first.invalid'},
          {'id': 'a', 'baseUrl': 'https://second.invalid'},
        ],
      });

      expect(settings.providers, hasLength(1));
      expect(settings.providers.single.baseUrl, 'https://first.invalid');
    });

    test('normalizes an unusable base URL and timeouts per entry', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'a',
            'baseUrl': 'ftp://invalid',
            'connectTimeoutMs': 0,
            'sendTimeoutMs': -1,
            'receiveTimeoutMs': 'abc',
          },
          {
            'id': 'b',
            'baseUrl': ' http://127.0.0.1:9000 ',
            'connectTimeoutMs': '2500',
            'sendTimeoutMs': 3000,
          },
        ],
      });

      final first = settings.providers.first;
      expect(first.baseUrl, defaultOnlineMusicBaseUrl);
      expect(first.connectTimeout, defaultOnlineMusicConnectTimeout);
      expect(first.sendTimeout, defaultOnlineMusicSendTimeout);
      expect(first.receiveTimeout, defaultOnlineMusicReceiveTimeout);

      final second = settings.providers.last;
      expect(second.baseUrl, 'http://127.0.0.1:9000');
      expect(second.connectTimeout, const Duration(milliseconds: 2500));
      expect(second.sendTimeout, const Duration(milliseconds: 3000));
      expect(second.receiveTimeout, defaultOnlineMusicReceiveTimeout);
    });

    test('an unregistered default provider falls back to the first entry', () {
      final settings = OnlineMusicSettings.fromJson({
        'defaultProvider': 'missing',
        'providers': [
          {'id': 'a'},
          {'id': 'b'},
        ],
      });

      expect(settings.defaultProviderId, 'a');
    });
  });

  group('OnlineMusicSettings auth', () {
    test('auth.kind none removes the credential requirement', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'self',
            'baseUrl': 'http://127.0.0.1:8080',
            'auth': {'kind': 'none'},
          },
        ],
      });

      final provider = settings.providers.single;
      expect(provider.requiresCredential, isFalse);
      expect(provider.credentialReference, isNull);
      for (final capability in OnlineMusicCapability.values) {
        expect(provider.authFor(capability), isA<OnlineMusicNoAuth>());
      }
    });

    test('each entry can carry its own credential reference and parameter', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'a',
            'auth': {
              'kind': 'apiKey',
              'reference': 'PureMusic/A/APIKey',
              'parameter': 'token',
            },
          },
          {
            'id': 'b',
            'auth': {'kind': 'apiKey', 'reference': 'PureMusic/B/APIKey'},
          },
        ],
      });

      expect(
        settings.providers.first.credentialReference,
        'PureMusic/A/APIKey',
      );
      expect(
        settings.providers.first.authFor(OnlineMusicCapability.search),
        isA<OnlineMusicApiKeyAuth>().having(
          (auth) => auth.parameterName,
          'parameterName',
          'token',
        ),
      );
      expect(settings.providers.last.credentialReference, 'PureMusic/B/APIKey');
      expect(
        settings.providers.last.authFor(OnlineMusicCapability.search),
        isA<OnlineMusicApiKeyAuth>().having(
          (auth) => auth.parameterName,
          'parameterName',
          'apikey',
        ),
      );
    });

    test('an apiKey entry without a reference keeps the confirmed default', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'a',
            'auth': {'kind': 'apiKey'},
          },
        ],
      });

      expect(
        settings.providers.single.credentialReference,
        OnlineMusicProviderDefinition.defaultCredentialReference,
      );
    });

    test('capabilityAuth overrides a single capability', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'a',
            'capabilityAuth': {'lyric': 'none', 'search': 'unknown'},
          },
        ],
      });

      final provider = settings.providers.single;
      expect(
        provider.authFor(OnlineMusicCapability.lyric),
        isA<OnlineMusicNoAuth>(),
      );
      expect(
        provider.authFor(OnlineMusicCapability.search),
        isA<OnlineMusicApiKeyAuth>(),
      );
      expect(
        provider.authFor(OnlineMusicCapability.stream),
        isA<OnlineMusicApiKeyAuth>(),
      );
    });
  });

  group('OnlineMusicSettings capability mapping', () {
    test('keeps registered targets and drops unknown ones', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'a'},
          {'id': 'b'},
        ],
        'capabilities': {
          'search': 'b',
          'playlist': 'missing',
          'lyric': '   ',
          'stream': 2,
        },
      });

      expect(settings.capabilityProviders, {OnlineMusicCapability.search: 'b'});
    });

    test('a non-map capability section is ignored', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {'id': 'a'},
        ],
        'capabilities': 'text',
      });

      expect(settings.capabilityProviders, isEmpty);
    });
  });

  group('online music composition', () {
    test('the default composition keeps the confirmed single provider', () {
      final composition = createOnlineMusicComposition(portableBuild: true);
      addTearDown(composition.service.dispose);

      final capabilities = composition.service.capabilities;
      expect(capabilities.searchablePlatforms, {MusicPlatform.netease});
      expect(capabilities.playlistPlatforms, {MusicPlatform.netease});
      expect(capabilities.lyricPlatforms, {MusicPlatform.netease});
      expect(capabilities.resolvablePlatforms, {MusicPlatform.netease});
      expect(composition.credentialControllers.keys, [
        defaultOnlineMusicProviderId,
      ]);
    });

    test('data and playback providers can be configured separately', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'baseUrl': 'http://127.0.0.1:8080',
            'auth': {'kind': 'none'},
          },
          {
            'id': 'playback',
            'auth': {
              'kind': 'apiKey',
              'reference': 'PureMusic/Playback/APIKey',
            },
          },
        ],
        'capabilities': {
          'search': 'selfData',
          'playlist': 'selfData',
          'lyric': 'selfData',
          'stream': 'playback',
        },
      });
      final composition = createOnlineMusicComposition(
        settings: settings,
        portableBuild: true,
      );
      addTearDown(composition.service.dispose);

      final registry =
          (composition.service as CompositeOnlineMusicService).registry;
      expect(registry.providerIdFor(OnlineMusicCapability.search), 'selfData');
      expect(
        registry.providerIdFor(OnlineMusicCapability.playlist),
        'selfData',
      );
      expect(registry.providerIdFor(OnlineMusicCapability.lyric), 'selfData');
      expect(registry.providerIdFor(OnlineMusicCapability.stream), 'playback');

      expect(composition.service.capabilities.searchablePlatforms, {
        MusicPlatform.netease,
      });
      // 每个条目都有各自的凭据入口，界面不再需要「谁是凭据所有者」的推断。
      expect(
        composition.credentialControllers.keys,
        containsAll(<String>['selfData', 'playback']),
      );
    });

    test('every entry exposes its own credential entry', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'auth': {'kind': 'none'},
          },
        ],
      });
      final composition = createOnlineMusicComposition(
        settings: settings,
        portableBuild: true,
      );
      addTearDown(composition.service.dispose);

      expect(composition.credentialControllers.keys, ['selfData']);
    });
  });

  group('平台启用开关（D8:A）', () {
    test('默认全部启用，且不写盘', () {
      const settings = OnlineMusicSettings.defaults;

      for (final platform in MusicPlatform.values) {
        expect(settings.isPlatformEnabled(platform), isTrue);
      }
      expect(
        settings.toJson().containsKey('enabledPlatforms'),
        isFalse,
        reason: '全部启用 = 空集，不写该键（D13:A：默认配置落盘内容不变）',
      );
    });

    test('停用平台会写盘，并可从 JSON 读回', () {
      final settings = OnlineMusicSettings.defaults.withPlatformEnabled(
        MusicPlatform.kugou,
        enabled: false,
      );

      expect(settings.isPlatformEnabled(MusicPlatform.kugou), isFalse);
      expect(settings.isPlatformEnabled(MusicPlatform.netease), isTrue);
      expect(settings.toJson()['enabledPlatforms'], ['netease', 'qq']);

      final restored = OnlineMusicSettings.fromJson(settings.toJson());
      expect(restored, settings);
      expect(restored.isPlatformEnabled(MusicPlatform.kugou), isFalse);
    });

    test('重新启用所有平台后回到空集（落盘不再带该键）', () {
      final disabled = OnlineMusicSettings.defaults.withPlatformEnabled(
        MusicPlatform.qq,
        enabled: false,
      );
      final restored = disabled.withPlatformEnabled(
        MusicPlatform.qq,
        enabled: true,
      );

      expect(restored.enabledPlatforms, isEmpty);
      expect(restored.toJson().containsKey('enabledPlatforms'), isFalse);
    });

    test('不允许停用最后一个启用的平台（空集只能表示"全部启用"）', () {
      var settings = OnlineMusicSettings.defaults;
      settings = settings.withPlatformEnabled(MusicPlatform.qq, enabled: false);
      settings = settings.withPlatformEnabled(
        MusicPlatform.kugou,
        enabled: false,
      );
      expect(settings.enabledPlatforms, {MusicPlatform.netease});

      final blocked = settings.withPlatformEnabled(
        MusicPlatform.netease,
        enabled: false,
      );
      expect(blocked, same(settings));
      expect(blocked.isPlatformEnabled(MusicPlatform.netease), isTrue);
    });

    test('无法识别的平台名被忽略，覆盖全部平台时归一化为空集', () {
      expect(
        OnlineMusicSettings.fromJson({
          'providers': [
            {'id': 'chksz', 'protocol': 'chksz'},
          ],
          'enabledPlatforms': ['netease', 'qq', 'kugou', 'bilibili'],
        }).enabledPlatforms,
        isEmpty,
      );
      expect(
        OnlineMusicSettings.fromJson({
          'providers': [
            {'id': 'chksz', 'protocol': 'chksz'},
          ],
          'enabledPlatforms': ['netease'],
        }).enabledPlatforms,
        {MusicPlatform.netease},
      );
    });

    test('被停用的平台不进入组合出的可搜索集合', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'full',
            'contentPlatform': 'netease',
            'auth': {'kind': 'none'},
            'capabilities': {
              'search': {'kind': 'builtin', 'builtin': 'chksz'},
              'stream': {'kind': 'builtin', 'builtin': 'chksz'},
            },
          },
        ],
        'enabledPlatforms': ['qq'],
      });
      final composition = createOnlineMusicComposition(
        settings: settings,
        portableBuild: true,
      );
      addTearDown(composition.service.dispose);

      // 条目代理的是 netease，而 netease 被停用 ⇒ 没有任何可搜索平台。
      expect(composition.service.capabilities.searchablePlatforms, isEmpty);
    });
  });

  group('AppPreference onlineMusic key', () {
    test('reads the key and falls back to defaults when absent', () {
      final preference = AppPreference();
      preference.applyStoredMap(const <String, Object?>{
        'onlineMusic': {
          'defaultProvider': 'selfData',
          'providers': [
            {
              'id': 'selfData',
              'auth': {'kind': 'none'},
            },
          ],
          'capabilities': {'stream': 'selfData'},
        },
      });

      expect(preference.onlineMusicSettings.defaultProviderId, 'selfData');
      expect(
        preference.onlineMusicSettings.providers.single.requiresCredential,
        isFalse,
      );
      expect(preference.onlineMusicSettings.capabilityProviders, {
        OnlineMusicCapability.stream: 'selfData',
      });

      final fallback = AppPreference();
      fallback.applyStoredMap(const <String, Object?>{});
      expect(
        fallback.onlineMusicSettings.providers.single.id,
        defaultOnlineMusicProviderId,
      );
    });

    test('an invalid key does not throw and keeps the default', () {
      final preference = AppPreference();
      preference.applyStoredMap(const <String, Object?>{
        'onlineMusic': 'not-a-map',
      });
      expect(
        preference.onlineMusicSettings.providers.single.id,
        defaultOnlineMusicProviderId,
      );
    });
  });

  group('composition reaches the configured provider', () {
    const ref = PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: '123456',
    );

    test('maps an entry to its own connection config', () {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'mirror',
            'baseUrl': 'http://127.0.0.1:9123',
            'connectTimeoutMs': 1500,
            'sendTimeoutMs': 2500,
            'receiveTimeoutMs': 3500,
          },
        ],
      });

      final config = chkszProviderConfigFor(settings.providers.single);
      final dio = createChkszDio(config: config);
      addTearDown(() => dio.close(force: true));

      expect(dio.options.baseUrl, 'http://127.0.0.1:9123');
      expect(dio.options.connectTimeout, const Duration(milliseconds: 1500));
      expect(dio.options.sendTimeout, const Duration(milliseconds: 2500));
      expect(dio.options.receiveTimeout, const Duration(milliseconds: 3500));
    });

    test('resolve goes to the playback entry and search does not', () async {
      final dataDio = _recordingDio();
      final playbackDio = _recordingDio();
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'data',
            'auth': {'kind': 'apiKey', 'reference': 'PureMusic/Data/APIKey'},
          },
          {
            'id': 'playback',
            'auth': {'kind': 'none'},
          },
        ],
        'capabilities': {
          'search': 'data',
          'playlist': 'data',
          'lyric': 'data',
          'stream': 'playback',
        },
      });
      final composition = createOnlineMusicComposition(
        settings: settings,
        portableBuild: true,
        dioFactory: (definition) =>
            definition.id == 'data' ? dataDio.dio : playbackDio.dio,
      );
      addTearDown(composition.service.dispose);

      final stream = await composition.service.resolve(
        ref,
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(stream.ref, ref);
      expect(playbackDio.adapter.requests, hasLength(1));
      expect(playbackDio.adapter.requests.single.path, '/api/163_music');
      expect(
        playbackDio.adapter.requests.single.queryParameters.containsKey(
          'apikey',
        ),
        isFalse,
        reason: '播放条目声明 auth.kind = none，不应注入凭据',
      );

      // 搜索被显式配置到 data 条目，它需要 Key；portable 内存凭据为空，
      // 因此 data 一定失败。**D17:b**：用户显式指给 (netease, search) 的候选只有 data，
      // 隐式条目（playback）不参与救场 —— 于是搜索以 notConfigured 失败，
      // 而**不会**偷偷落到用户从未指派给搜索的 playback 条目。
      await expectLater(
        composition.service.search(
          platform: MusicPlatform.netease,
          keyword: 'test',
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.notConfigured,
          ),
        ),
      );
      expect(dataDio.adapter.requests, isEmpty, reason: '缺凭据时不应发出请求');

      final route =
          (composition.service as CompositeOnlineMusicService).lastRoute!;
      expect(route.attempts.single.providerId, 'data');
      expect(route.attempts.single.kind, OnlineMusicErrorKind.notConfigured);
      expect(route.winnerProviderId, isNull, reason: '隐式候选不参与救场（D17:b）');
      expect(
        playbackDio.adapter.requests,
        hasLength(1),
        reason: '仍然只有 resolve 那一次请求：搜索不得改用 playback 条目',
      );
    });

    test('a credential-free entry reports why saving is impossible', () async {
      final settings = OnlineMusicSettings.fromJson({
        'providers': [
          {
            'id': 'selfData',
            'auth': {'kind': 'none'},
          },
        ],
      });
      final composition = createOnlineMusicComposition(
        settings: settings,
        portableBuild: true,
      );
      addTearDown(composition.service.dispose);

      final credentials = composition.credentialControllers['selfData']!;
      expect(await credentials.isConfigured(), isFalse);
      await expectLater(
        credentials.saveCredential('chksz_TEST_ONLY'),
        throwsA(
          isA<OnlineMusicCredentialException>()
              .having(
                (error) => error.operation,
                'operation',
                OnlineMusicCredentialOperation.save,
              )
              .having(
                (error) => error.safeMessage,
                'safeMessage',
                contains('不需要 API Key'),
              ),
        ),
      );
      // 不需要凭据的 Provider 仍然可以正常清除（无操作）。
      await credentials.clearCredential();
    });
  });
}

final class _RecordingDio {
  _RecordingDio()
    : adapter = _FakeDioAdapter(
        (options, _) async => ResponseBody.fromString(
          jsonEncode({
            'code': 200,
            'msg': 'success',
            'data': {
              'id': 123456,
              'url': 'https://media.invalid/test.flac',
              'br': 1000000,
              'level': 'lossless',
              'songs': <Object?>[],
              'total': 0,
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        ),
      ) {
    dio = Dio(BaseOptions(baseUrl: 'https://api.chksz.com'))
      ..httpClientAdapter = adapter;
  }

  final _FakeDioAdapter adapter;
  late final Dio dio;
}

_RecordingDio _recordingDio() => _RecordingDio();

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
