import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_windows_credential_store.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';
const _notFoundError = 1168;

void main() {
  group('WindowsChkszCredentialStore', () {
    test('can be constructed on non-Windows without loading a DLL', () {
      final store = WindowsChkszCredentialStore();

      expect(store.toString(), 'WindowsChkszCredentialStore');
    });

    test('uses the fixed target, username, and UTF-8 blob', () async {
      final api = _FakeCredentialManagerApi();
      final store = WindowsChkszCredentialStore(api: api);
      const unicodeApiKey = 'chksz_测试';

      await store.write(unicodeApiKey);

      expect(api.targetNames, [chkszWindowsCredentialTargetName]);
      expect(api.userNames, [chkszWindowsCredentialUserName]);
      expect(api.writtenBytes.single, utf8.encode(unicodeApiKey));
    });

    test('decodes a successful read as strict UTF-8', () async {
      final api = _FakeCredentialManagerApi(
        readResult: ChkszCredentialManagerReadResult.success(
          utf8.encode(_fakeApiKey),
        ),
      );
      final store = WindowsChkszCredentialStore(api: api);

      expect(await store.read(), _fakeApiKey);
      expect(api.targetNames, [chkszWindowsCredentialTargetName]);
    });

    test(
      'treats not found as missing for read and success for clear',
      () async {
        final api = _FakeCredentialManagerApi(
          readResult: const ChkszCredentialManagerReadResult.failure(
            _notFoundError,
          ),
          clearErrorCode: _notFoundError,
        );
        final store = WindowsChkszCredentialStore(api: api);

        expect(await store.read(), isNull);
        await store.clear();

        expect(api.targetNames, [
          chkszWindowsCredentialTargetName,
          chkszWindowsCredentialTargetName,
        ]);
      },
    );

    test('maps operation failures to safe errors with numeric codes', () async {
      final api = _FakeCredentialManagerApi(
        readResult: const ChkszCredentialManagerReadResult.failure(5),
        writeErrorCode: 6,
        clearErrorCode: 7,
      );
      final store = WindowsChkszCredentialStore(api: api);

      final readError = await _captureStorageException(store.read());
      final writeError = await _captureStorageException(
        store.write(_fakeApiKey),
      );
      final clearError = await _captureStorageException(store.clear());

      expect(readError.operation, ChkszCredentialStorageOperation.read);
      expect(readError.errorCode, 5);
      expect(writeError.operation, ChkszCredentialStorageOperation.write);
      expect(writeError.errorCode, 6);
      expect(clearError.operation, ChkszCredentialStorageOperation.clear);
      expect(clearError.errorCode, 7);
    });

    test('does not leak malformed blobs or thrown native errors', () async {
      final malformed = WindowsChkszCredentialStore(
        api: _FakeCredentialManagerApi(
          readResult: const ChkszCredentialManagerReadResult.success([0xff]),
        ),
      );
      final throwingApi = _FakeCredentialManagerApi(
        thrownError: StateError('native failure for $_fakeApiKey'),
      );
      final throwing = WindowsChkszCredentialStore(api: throwingApi);

      final malformedError = await _captureStorageException(malformed.read());
      final readError = await _captureStorageException(throwing.read());
      final writeError = await _captureStorageException(
        throwing.write(_fakeApiKey),
      );
      final clearError = await _captureStorageException(throwing.clear());

      for (final error in [malformedError, readError, writeError, clearError]) {
        expect(error.toString(), isNot(contains(_fakeApiKey)));
        expect(error.errorCode, isNull);
      }
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

final class _FakeCredentialManagerApi implements ChkszCredentialManagerApi {
  _FakeCredentialManagerApi({
    this.readResult = const ChkszCredentialManagerReadResult.success(null),
    this.writeErrorCode,
    this.clearErrorCode,
    this.thrownError,
  });

  final ChkszCredentialManagerReadResult readResult;
  final int? writeErrorCode;
  final int? clearErrorCode;
  final Object? thrownError;
  final List<String> targetNames = [];
  final List<String> userNames = [];
  final List<List<int>> writtenBytes = [];

  @override
  ChkszCredentialManagerReadResult read(String targetName) {
    targetNames.add(targetName);
    _throwIfNeeded();
    return readResult;
  }

  @override
  int? write({
    required String targetName,
    required String userName,
    required List<int> bytes,
  }) {
    targetNames.add(targetName);
    userNames.add(userName);
    writtenBytes.add(List<int>.of(bytes));
    _throwIfNeeded();
    return writeErrorCode;
  }

  @override
  int? clear(String targetName) {
    targetNames.add(targetName);
    _throwIfNeeded();
    return clearErrorCode;
  }

  void _throwIfNeeded() {
    final error = thrownError;
    if (error != null) throw error;
  }
}
