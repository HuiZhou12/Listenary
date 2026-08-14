import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider_factory.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';

void main() {
  group('createChkszCredentialProvider', () {
    test(
      'portable mode stays in memory and never constructs a store',
      () async {
        var storeConstructed = false;
        ChkszCredentialStore createStore() {
          storeConstructed = true;
          throw StateError('Windows store must not be constructed');
        }

        final provider = createChkszCredentialProvider(
          portableBuild: true,
          windowsStoreFactory: createStore,
        );

        expect(provider, isA<InMemoryChkszCredentialProvider>());
        expect(storeConstructed, isFalse);
        await provider.writeApiKey(_fakeApiKey);
        expect(await provider.readApiKey(), _fakeApiKey);

        final restarted = createChkszCredentialProvider(
          portableBuild: true,
          windowsStoreFactory: createStore,
        );
        expect(await restarted.readApiKey(), isNull);
        expect(storeConstructed, isFalse);
      },
    );

    test(
      'installed mode creates a persistent provider for the store',
      () async {
        final store = _FakeCredentialStore();
        final provider = createChkszCredentialProvider(
          portableBuild: false,
          windowsStoreFactory: () => store,
        );

        expect(provider, isA<PersistentChkszCredentialProvider>());
        await provider.writeApiKey(_fakeApiKey);
        expect(store.value, _fakeApiKey);

        final restarted = createChkszCredentialProvider(
          portableBuild: false,
          windowsStoreFactory: () => store,
        );
        expect(await restarted.readApiKey(), _fakeApiKey);
        expect(restarted.toString(), isNot(contains(_fakeApiKey)));
      },
    );

    test('installed default can be constructed without loading a DLL', () {
      final provider = createChkszCredentialProvider(portableBuild: false);

      expect(provider, isA<PersistentChkszCredentialProvider>());
      expect(provider.toString(), isNot(contains(_fakeApiKey)));
    });

    test('installed store failures remain sanitized', () async {
      final provider = createChkszCredentialProvider(
        portableBuild: false,
        windowsStoreFactory: () => _FakeCredentialStore(
          writeError: StateError('failed for $_fakeApiKey'),
        ),
      );

      await expectLater(
        provider.writeApiKey(_fakeApiKey),
        throwsA(
          isA<ChkszCredentialStorageException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains(_fakeApiKey)),
          ),
        ),
      );
    });
  });
}

final class _FakeCredentialStore implements ChkszCredentialStore {
  _FakeCredentialStore({this.writeError});

  String? value;
  final Object? writeError;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String apiKey) async {
    final error = writeError;
    if (error != null) throw error;
    value = apiKey;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}
