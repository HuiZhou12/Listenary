import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

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
    test('an empty or fully invalid provider list falls back to the default', () {
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
    });

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

      expect(settings.providers.first.credentialReference, 'PureMusic/A/APIKey');
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

      expect(settings.capabilityProviders, {
        OnlineMusicCapability.search: 'b',
      });
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
      expect(
        composition.credentials,
        isA<ChkszOnlineMusicProvider>().having(
          (provider) => provider.providerId,
          'providerId',
          defaultOnlineMusicProviderId,
        ),
      );
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
            'auth': {'kind': 'apiKey', 'reference': 'PureMusic/Playback/APIKey'},
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

      expect(composition.service.capabilities.searchablePlatforms, {
        MusicPlatform.netease,
      });
      // 默认 Provider 是 selfData（无凭据），设置页凭据入口退到需要凭据的播放 Provider。
      expect(
        composition.credentials,
        isA<ChkszOnlineMusicProvider>().having(
          (provider) => provider.providerId,
          'providerId',
          'playback',
        ),
      );
    });

    test('a credential-free default keeps its own credential entry', () {
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

      expect(
        composition.credentials,
        isA<ChkszOnlineMusicProvider>().having(
          (provider) => provider.providerId,
          'providerId',
          'selfData',
        ),
      );
    });
  });

  group('AppPreference onlineMusic key', () {
    test('reads the key and falls back to defaults when absent', () {
      final preference = AppPreference();
      preference.applyStoredMap(const <String, Object?>{
        'onlineMusic': {
          'defaultProvider': 'selfData',
          'providers': [
            {'id': 'selfData', 'auth': {'kind': 'none'}},
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
}
