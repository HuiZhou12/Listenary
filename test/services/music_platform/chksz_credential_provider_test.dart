import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

const _firstApiKey = 'chksz_FIRST_TEST_ONLY';
const _secondApiKey = 'chksz_SECOND_TEST_ONLY';

void main() {
  group('InMemoryChkszCredentialProvider', () {
    test('writes, overwrites, reads, and clears a valid key', () async {
      final provider = InMemoryChkszCredentialProvider();

      expect(await provider.readApiKey(), isNull);
      await provider.writeApiKey(_firstApiKey);
      expect(await provider.readApiKey(), _firstApiKey);
      await provider.writeApiKey(_secondApiKey);
      expect(await provider.readApiKey(), _secondApiKey);
      await provider.clearApiKey();
      expect(await provider.readApiKey(), isNull);
    });

    test('rejects an invalid key without replacing the current key', () async {
      final provider = InMemoryChkszCredentialProvider(
        initialApiKey: _firstApiKey,
      );
      const invalidApiKey = 'chksz_INVALID TEST ONLY';

      await expectLater(
        provider.writeApiKey(invalidApiKey),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains(invalidApiKey)),
          ),
        ),
      );

      expect(await provider.readApiKey(), _firstApiKey);
    });

    test('does not expose the key in its string representation', () {
      final provider = InMemoryChkszCredentialProvider(
        initialApiKey: _firstApiKey,
      );

      expect(provider.toString(), contains('configured=true'));
      expect(provider.toString(), isNot(contains(_firstApiKey)));
    });
  });

  group('PersistentChkszCredentialProvider', () {
    test('loads from the store once and caches missing values', () async {
      final store = _FakeCredentialStore();
      final provider = PersistentChkszCredentialProvider(store: store);

      expect(await provider.readApiKey(), isNull);
      expect(await provider.readApiKey(), isNull);
      expect(store.operations, ['read']);
    });

    test('writes to the store before updating the cache', () async {
      final store = _FakeCredentialStore(value: _firstApiKey);
      final provider = PersistentChkszCredentialProvider(store: store);

      expect(await provider.readApiKey(), _firstApiKey);
      await provider.writeApiKey(_secondApiKey);

      expect(store.value, _secondApiKey);
      expect(await provider.readApiKey(), _secondApiKey);
      expect(store.operations, ['read', 'write']);
    });

    test('rejects invalid writes without calling the store', () async {
      final store = _FakeCredentialStore(value: _firstApiKey);
      final provider = PersistentChkszCredentialProvider(store: store);
      await provider.readApiKey();

      await expectLater(
        provider.writeApiKey('chksz_INVALID TEST ONLY'),
        throwsFormatException,
      );

      expect(await provider.readApiKey(), _firstApiKey);
      expect(store.operations, ['read']);
    });

    test('clears the store and keeps the missing value cached', () async {
      final store = _FakeCredentialStore(value: _firstApiKey);
      final provider = PersistentChkszCredentialProvider(store: store);
      await provider.readApiKey();

      await provider.clearApiKey();

      expect(store.value, isNull);
      expect(await provider.readApiKey(), isNull);
      expect(store.operations, ['read', 'clear']);
    });

    test('does not expose store failures or the previous key', () async {
      final store = _FakeCredentialStore(value: _firstApiKey);
      final provider = PersistentChkszCredentialProvider(store: store);
      await provider.readApiKey();
      store.writeError = StateError('failed for $_secondApiKey');

      final exception = await _captureStorageException(
        provider.writeApiKey(_secondApiKey),
      );

      expect(exception.operation, ChkszCredentialStorageOperation.write);
      expect(exception.toString(), isNot(contains(_firstApiKey)));
      expect(exception.toString(), isNot(contains(_secondApiKey)));
      expect(await provider.readApiKey(), _firstApiKey);
    });

    test('keeps memory cleared when persistent deletion fails', () async {
      final store = _FakeCredentialStore(value: _firstApiKey);
      final provider = PersistentChkszCredentialProvider(store: store);
      await provider.readApiKey();
      store.clearError = StateError('failed for $_firstApiKey');

      final exception = await _captureStorageException(provider.clearApiKey());

      expect(exception.operation, ChkszCredentialStorageOperation.clear);
      expect(exception.toString(), isNot(contains(_firstApiKey)));
      expect(await provider.readApiKey(), isNull);
      expect(store.value, _firstApiKey);
    });

    test('rejects a malformed stored key without exposing it', () async {
      const malformedKey = 'chksz_MALFORMED TEST ONLY';
      final provider = PersistentChkszCredentialProvider(
        store: _FakeCredentialStore(value: malformedKey),
      );

      final exception = await _captureStorageException(provider.readApiKey());

      expect(exception.operation, ChkszCredentialStorageOperation.read);
      expect(exception.toString(), isNot(contains(malformedKey)));
    });

    test('serializes concurrent reads, writes, and clears', () async {
      final store = _FakeCredentialStore(value: _firstApiKey);
      final provider = PersistentChkszCredentialProvider(store: store);

      final read = provider.readApiKey();
      final write = provider.writeApiKey(_secondApiKey);
      final clear = provider.clearApiKey();

      expect(await read, _firstApiKey);
      await write;
      await clear;
      expect(store.operations, ['read', 'write', 'clear']);
      expect(await provider.readApiKey(), isNull);
    });

    test('does not expose cached credentials in its string form', () async {
      final provider = PersistentChkszCredentialProvider(
        store: _FakeCredentialStore(value: _firstApiKey),
      );
      await provider.readApiKey();

      expect(provider.toString(), contains('configured=true'));
      expect(provider.toString(), isNot(contains(_firstApiKey)));
    });
  });
}

Future<ChkszCredentialStorageException> _captureStorageException(
  Future<Object?> future,
) async {
  try {
    await future;
  } on ChkszCredentialStorageException catch (error) {
    return error;
  }
  throw StateError('Expected ChkszCredentialStorageException');
}

final class _FakeCredentialStore implements ChkszCredentialStore {
  _FakeCredentialStore({this.value});

  String? value;
  Object? readError;
  Object? writeError;
  Object? clearError;
  final List<String> operations = [];

  @override
  Future<String?> read() async {
    operations.add('read');
    final error = readError;
    if (error != null) throw error;
    return value;
  }

  @override
  Future<void> write(String apiKey) async {
    operations.add('write');
    final error = writeError;
    if (error != null) throw error;
    value = apiKey;
  }

  @override
  Future<void> clear() async {
    operations.add('clear');
    final error = clearError;
    if (error != null) throw error;
    value = null;
  }
}
