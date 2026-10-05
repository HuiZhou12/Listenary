import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

void main() {
  group('provider edits', () {
    test('adds, updates and removes entries with fallbacks', () async {
      final controller = _controller();

      expect(
        controller.settings.providers.single.id,
        defaultOnlineMusicProviderId,
      );

      await controller.addProvider(
        OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'http://127.0.0.1:8080',
          requiresCredential: false,
        ),
      );
      expect(controller.providerIds, {'chksz', 'selfData'});
      expect(controller.settings.providerById('selfData')!.requiresCredential,
          isFalse);

      // 重复标识被忽略。
      await controller.addProvider(
        OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'http://127.0.0.1:9999',
          requiresCredential: false,
        ),
      );
      expect(
        controller.settings.providerById('selfData')!.baseUrl,
        'http://127.0.0.1:8080',
      );

      await controller.updateProvider(
        controller.settings.providerById('selfData')!.editedBy(
          baseUrl: 'https://self.invalid',
          requiresCredential: true,
        ),
      );
      final updated = controller.settings.providerById('selfData')!;
      expect(updated.baseUrl, 'https://self.invalid');
      expect(updated.requiresCredential, isTrue);
      expect(
        updated.credentialReference,
        deriveOnlineMusicCredentialReference('selfData'),
      );

      // 删除默认条目：默认与指向它的能力分配都回落到剩下的第一个条目。
      await controller.assignCapability(
        OnlineMusicCapability.stream,
        defaultOnlineMusicProviderId,
      );
      await controller.removeProvider(defaultOnlineMusicProviderId);

      expect(controller.providerIds, {'selfData'});
      expect(controller.settings.defaultProviderId, 'selfData');
      expect(
        controller.settings.resolvedProviderIdFor(OnlineMusicCapability.stream),
        'selfData',
      );

      // 只剩一个条目时不允许再删。
      await controller.removeProvider('selfData');
      expect(controller.providerIds, {'selfData'});
      controller.dispose();
    });

    test('keeps an unusable base URL at the documented default', () async {
      final controller = _controller();
      await controller.updateProvider(
        controller.settings.providers.single.editedBy(
          baseUrl: 'ftp://invalid',
          requiresCredential: true,
        ),
      );

      expect(
        controller.settings.providers.single.baseUrl,
        defaultOnlineMusicBaseUrl,
      );
      controller.dispose();
    });

    test('assigns capabilities and the default provider', () async {
      final controller = _controller();
      await controller.addProvider(
        OnlineMusicProviderDefinition.custom(
          id: 'playback',
          baseUrl: 'https://play.invalid',
          requiresCredential: true,
        ),
      );
      await controller.setDefaultProvider('playback');
      await controller.assignCapability(
        OnlineMusicCapability.search,
        'playback',
      );

      expect(controller.settings.defaultProviderId, 'playback');
      expect(
        controller.settings.resolvedProviderIdFor(OnlineMusicCapability.search),
        'playback',
      );
      expect(
        controller.settings.resolvedProviderIdFor(OnlineMusicCapability.lyric),
        'playback',
      );

      // 指向未注册 id 的分配被忽略。
      await controller.assignCapability(OnlineMusicCapability.lyric, 'missing');
      expect(
        controller.settings.resolvedProviderIdFor(OnlineMusicCapability.lyric),
        'playback',
      );
      controller.dispose();
    });
  });

  group('pending restart', () {
    test('is false while the saved configuration matches the running one', () {
      final controller = _controller();
      expect(controller.hasPendingRestart, isFalse);
      expect(controller.activeSettings, OnlineMusicSettings.defaults);
      controller.dispose();
    });

    test('becomes true after an edit and false again when reverted', () async {
      final controller = _controller();
      await controller.addProvider(
        OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'http://127.0.0.1:8080',
          requiresCredential: false,
        ),
      );
      expect(controller.hasPendingRestart, isTrue);

      await controller.removeProvider('selfData');
      expect(controller.hasPendingRestart, isFalse);
      controller.dispose();
    });

    test('rolls back and reports failure when the store refuses to write', () async {
      final store = _MemorySettingsStore(OnlineMusicSettings.defaults)
        ..acceptWrites = false;
      final controller = OnlineMusicProviderSettingsController(
        activeSettings: OnlineMusicSettings.defaults,
        store: store,
        fallbackCredentials: _FakeCredentialAccess(),
      );

      final saved = await controller.addProvider(
        OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'http://127.0.0.1:8080',
          requiresCredential: false,
        ),
      );

      expect(saved, isFalse);
      expect(controller.providerIds, {defaultOnlineMusicProviderId});
      expect(controller.hasPendingRestart, isFalse);
      controller.dispose();
    });
  });

  group('per-entry credentials', () {
    test('two entries read and write independent slots', () async {
      final credentials = _FakeCredentialAccess();
      final controller = _controller(credentials: credentials);
      final first = controller.settings.providers.single;
      await controller.addProvider(
        OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'https://self.invalid',
          requiresCredential: true,
        ),
      );
      final second = controller.settings.providerById('selfData')!;

      await controller.saveCredential(first, 'chksz_FIRST_TEST_ONLY');
      await controller.saveCredential(second, 'chksz_SECOND_TEST_ONLY');

      expect(await controller.isCredentialConfigured(first), isTrue);
      expect(await controller.isCredentialConfigured(second), isTrue);
      expect(credentials.saved, {
        OnlineMusicProviderDefinition.defaultCredentialReference:
            'chksz_FIRST_TEST_ONLY',
        deriveOnlineMusicCredentialReference('selfData'):
            'chksz_SECOND_TEST_ONLY',
      });

      await controller.clearCredential(first);
      expect(await controller.isCredentialConfigured(first), isFalse);
      expect(await controller.isCredentialConfigured(second), isTrue);
      controller.dispose();
    });

    test('a credential-free entry has no credential operations', () async {
      final controller = _controller();
      await controller.addProvider(
        OnlineMusicProviderDefinition.custom(
          id: 'selfData',
          baseUrl: 'https://self.invalid',
          requiresCredential: false,
        ),
      );
      final definition = controller.settings.providerById('selfData')!;

      expect(await controller.isCredentialConfigured(definition), isFalse);
      await expectLater(
        controller.saveCredential(definition, 'chksz_TEST_ONLY'),
        throwsA(isA<FormatException>()),
      );
      await controller.clearCredential(definition);
      controller.dispose();
    });

    test('running providers keep their own credential entry', () async {
      final running = _FakeCredentialAccess()..configured.add('running');
      final controller = OnlineMusicProviderSettingsController(
        activeSettings: OnlineMusicSettings.defaults,
        store: _MemorySettingsStore(OnlineMusicSettings.defaults),
        fallbackCredentials: _FakeCredentialAccess(),
        runningCredentials: {
          defaultOnlineMusicProviderId: _RunningCredentialController(
            running,
            'running',
          ),
        },
      );

      final definition = controller.settings.providers.single;
      expect(await controller.isCredentialConfigured(definition), isTrue);
      await controller.saveCredential(definition, 'chksz_RUNNING_TEST_ONLY');
      expect(running.saved['running'], 'chksz_RUNNING_TEST_ONLY');
      controller.dispose();
    });
  });

  group('serialization', () {
    test('round-trips through fromJson', () {
      final settings = OnlineMusicSettings.fromJson({
        'defaultProvider': 'selfData',
        'providers': [
          {
            'id': 'chksz',
            'baseUrl': 'https://api.chksz.com',
            'connectTimeoutMs': 8000,
            'sendTimeoutMs': 8000,
            'receiveTimeoutMs': 10000,
            'auth': {
              'kind': 'apiKey',
              'reference': 'PureMusic/ChKSz/APIKey',
              'parameter': 'apikey',
            },
          },
          {
            'id': 'selfData',
            'baseUrl': 'http://127.0.0.1:8080',
            'auth': {'kind': 'none'},
            'capabilityAuth': {'lyric': 'none'},
          },
        ],
        'capabilities': {'search': 'selfData', 'stream': 'selfData'},
      });

      final roundTripped = OnlineMusicSettings.fromJson(settings.toJson());

      expect(roundTripped, settings);
      expect(roundTripped.defaultProviderId, 'selfData');
      expect(roundTripped.toJson()['providers'], hasLength(2));
      expect(
        roundTripped.resolvedProviderIdFor(OnlineMusicCapability.search),
        'selfData',
      );
      expect(roundTripped.providerById('chksz')!.requiresCredential, isTrue);
      expect(roundTripped.providerById('selfData')!.requiresCredential, isFalse);
    });

    test('values compare by content', () {
      expect(
        OnlineMusicSettings.fromJson(OnlineMusicSettings.defaults.toJson()),
        OnlineMusicSettings.defaults,
      );
      expect(
        OnlineMusicSettings.defaults.withCapabilityProvider(
          OnlineMusicCapability.search,
          defaultOnlineMusicProviderId,
        ),
        isNot(OnlineMusicSettings.defaults),
      );
    });
  });

  group('id validation', () {
    test('rejects empty, spaced, reserved and duplicate ids', () {
      expect(
        validateOnlineMusicProviderId('', existingIds: const {}),
        '请填写标识',
      );
      expect(
        validateOnlineMusicProviderId('a b', existingIds: const {}),
        '标识不能包含空白',
      );
      expect(
        validateOnlineMusicProviderId('a/b', existingIds: const {}),
        '标识只能包含字母、数字、下划线或连字符',
      );
      expect(
        validateOnlineMusicProviderId(
          defaultOnlineMusicProviderId,
          existingIds: const {},
        ),
        '该标识已被占用',
      );
      expect(
        validateOnlineMusicProviderId('selfData', existingIds: const {'selfData'}),
        '该标识已存在',
      );
      expect(
        validateOnlineMusicProviderId('selfData', existingIds: const {}),
        isNull,
      );
    });
  });

  group('AppPreference onlineMusic write path', () {
    test('keeps a hand-written key untouched until the UI edits it', () {
      final preference = AppPreference();
      const handwritten = <String, Object?>{
        'defaultProvider': 'selfData',
        'providers': [
          {'id': 'selfData', 'protocol': 'chksz', 'auth': {'kind': 'none'}},
        ],
        'capabilities': {'stream': 'selfData'},
      };
      preference.applyStoredMap(const <String, Object?>{
        'onlineMusic': handwritten,
      });

      // 没改过：写盘结构里仍是用户手写的原始内容。
      expect(preference.buildPreferenceMap()['onlineMusic'], handwritten);

      // 改过之后：按规范化结果写回。
      preference.setOnlineMusicSettings(
        OnlineMusicSettings.fromJson(handwritten).withCapabilityProvider(
          OnlineMusicCapability.search,
          'selfData',
        ),
      );
      final written = preference.buildPreferenceMap()['onlineMusic'] as Map;
      expect(written['capabilities'], {'stream': 'selfData', 'search': 'selfData'});
      expect(written['defaultProvider'], 'selfData');
    });
  });
}

OnlineMusicProviderSettingsController _controller({
  OnlineMusicSettings configured = OnlineMusicSettings.defaults,
  OnlineMusicSettings active = OnlineMusicSettings.defaults,
  _FakeCredentialAccess? credentials,
}) {
  return OnlineMusicProviderSettingsController(
    activeSettings: active,
    store: _MemorySettingsStore(configured),
    fallbackCredentials: credentials ?? _FakeCredentialAccess(),
  );
}

final class _MemorySettingsStore implements OnlineMusicSettingsStore {
  _MemorySettingsStore(this.value);

  OnlineMusicSettings value;
  bool acceptWrites = true;

  @override
  OnlineMusicSettings read() => value;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    if (!acceptWrites) return false;
    value = settings;
    return true;
  }
}

final class _FakeCredentialAccess implements OnlineMusicCredentialAccess {
  final Map<String, String> saved = {};
  final Set<String> configured = {};

  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'chksz_...';

  @override
  bool isValidFormat(String value) => RegExp(r'^chksz_\S+$').hasMatch(value);

  @override
  Future<bool> isConfigured(String reference) async =>
      configured.contains(reference) || saved.containsKey(reference);

  @override
  Future<void> save(String reference, String value) async {
    saved[reference] = value;
  }

  @override
  Future<void> clear(String reference) async {
    saved.remove(reference);
    configured.remove(reference);
  }
}

/// 把某个引用的凭据操作暴露成 Provider 形状的控制器。
final class _RunningCredentialController
    implements OnlineMusicCredentialController {
  _RunningCredentialController(this._access, this._reference);

  final _FakeCredentialAccess _access;
  final String _reference;

  @override
  String get providerDisplayName => 'ChKSz';

  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'chksz_...';

  @override
  bool isCredentialFormatValid(String value) => _access.isValidFormat(value);

  @override
  Future<bool> isConfigured() => _access.isConfigured(_reference);

  @override
  Future<void> saveCredential(String value) =>
      _access.save(_reference, value);

  @override
  Future<void> clearCredential() => _access.clear(_reference);
}
