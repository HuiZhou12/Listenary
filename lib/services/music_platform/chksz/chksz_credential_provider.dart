import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';

abstract interface class ChkszCredentialProvider {
  Future<String?> readApiKey();

  Future<void> writeApiKey(String apiKey);

  Future<void> clearApiKey();
}

abstract interface class ChkszCredentialStore {
  Future<String?> read();

  Future<void> write(String apiKey);

  Future<void> clear();
}

enum ChkszCredentialStorageOperation { read, write, clear }

final class ChkszCredentialStorageException implements Exception {
  const ChkszCredentialStorageException({
    required this.operation,
    this.errorCode,
  });

  final ChkszCredentialStorageOperation operation;
  final int? errorCode;

  String get safeMessage => switch (operation) {
    ChkszCredentialStorageOperation.read => '无法安全读取 ChKSz API Key',
    ChkszCredentialStorageOperation.write => '无法安全保存 ChKSz API Key',
    ChkszCredentialStorageOperation.clear => '无法完全清除 ChKSz API Key',
  };

  @override
  String toString() {
    final code = errorCode;
    return code == null
        ? 'ChkszCredentialStorageException: $safeMessage'
        : 'ChkszCredentialStorageException: $safeMessage (code=$code)';
  }
}

final class InMemoryChkszCredentialProvider implements ChkszCredentialProvider {
  InMemoryChkszCredentialProvider({String? initialApiKey}) {
    if (initialApiKey != null) {
      _validateChkszApiKey(initialApiKey);
      _apiKey = initialApiKey;
    }
  }

  String? _apiKey;

  @override
  Future<String?> readApiKey() async => _apiKey;

  @override
  Future<void> writeApiKey(String apiKey) async {
    _validateChkszApiKey(apiKey);
    _apiKey = apiKey;
  }

  @override
  Future<void> clearApiKey() async {
    _apiKey = null;
  }

  @override
  String toString() =>
      'InMemoryChkszCredentialProvider(configured=${_apiKey != null})';
}

final class PersistentChkszCredentialProvider
    implements ChkszCredentialProvider {
  PersistentChkszCredentialProvider({required ChkszCredentialStore store})
    : _store = store;

  final ChkszCredentialStore _store;
  Future<void> _pendingOperation = Future<void>.value();
  bool _loaded = false;
  String? _apiKey;

  @override
  Future<String?> readApiKey() => _serialize(() async {
    if (_loaded) return _apiKey;
    final stored = await _runStoreOperation(
      ChkszCredentialStorageOperation.read,
      _store.read,
    );
    if (stored != null && !isValidChkszApiKeyFormat(stored)) {
      throw const ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.read,
      );
    }
    _apiKey = stored;
    _loaded = true;
    return stored;
  });

  @override
  Future<void> writeApiKey(String apiKey) {
    try {
      _validateChkszApiKey(apiKey);
    } catch (error, stackTrace) {
      return Future<void>.error(error, stackTrace);
    }
    return _serialize(() async {
      await _runStoreOperation(
        ChkszCredentialStorageOperation.write,
        () => _store.write(apiKey),
      );
      _apiKey = apiKey;
      _loaded = true;
    });
  }

  @override
  Future<void> clearApiKey() => _serialize(() async {
    _apiKey = null;
    _loaded = true;
    await _runStoreOperation(
      ChkszCredentialStorageOperation.clear,
      _store.clear,
    );
  });

  @override
  String toString() =>
      'PersistentChkszCredentialProvider('
      'loaded=$_loaded, configured=${_apiKey != null})';

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _pendingOperation.then((_) => operation());
    _pendingOperation = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<T> _runStoreOperation<T>(
    ChkszCredentialStorageOperation operation,
    Future<T> Function() callback,
  ) async {
    try {
      return await callback();
    } on ChkszCredentialStorageException {
      rethrow;
    } catch (_) {
      throw ChkszCredentialStorageException(operation: operation);
    }
  }
}

void _validateChkszApiKey(String apiKey) {
  if (!isValidChkszApiKeyFormat(apiKey)) {
    throw const FormatException('Invalid ChKSz API Key format');
  }
}
