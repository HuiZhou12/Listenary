import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:win32/win32.dart';

const chkszWindowsCredentialTargetName = 'PureMusic/ChKSz/APIKey';
const chkszWindowsCredentialUserName = 'api_key';

final class ChkszCredentialManagerReadResult {
  const ChkszCredentialManagerReadResult.success(this.bytes) : errorCode = null;

  const ChkszCredentialManagerReadResult.failure(this.errorCode) : bytes = null;

  final List<int>? bytes;
  final int? errorCode;
}

abstract interface class ChkszCredentialManagerApi {
  ChkszCredentialManagerReadResult read(String targetName);

  int? write({
    required String targetName,
    required String userName,
    required List<int> bytes,
  });

  int? clear(String targetName);
}

final class WindowsChkszCredentialStore implements ChkszCredentialStore {
  WindowsChkszCredentialStore({ChkszCredentialManagerApi? api})
    : _api = api ?? const _Win32CredentialManagerApi();

  final ChkszCredentialManagerApi _api;

  @override
  Future<String?> read() async {
    try {
      final result = _api.read(chkszWindowsCredentialTargetName);
      final errorCode = result.errorCode;
      if (errorCode == ERROR_NOT_FOUND) return null;
      if (errorCode != null) {
        throw ChkszCredentialStorageException(
          operation: ChkszCredentialStorageOperation.read,
          errorCode: errorCode,
        );
      }
      return utf8.decode(result.bytes ?? const <int>[]);
    } on ChkszCredentialStorageException {
      rethrow;
    } catch (_) {
      throw const ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.read,
      );
    }
  }

  @override
  Future<void> write(String apiKey) async {
    try {
      final errorCode = _api.write(
        targetName: chkszWindowsCredentialTargetName,
        userName: chkszWindowsCredentialUserName,
        bytes: utf8.encode(apiKey),
      );
      if (errorCode != null) {
        throw ChkszCredentialStorageException(
          operation: ChkszCredentialStorageOperation.write,
          errorCode: errorCode,
        );
      }
    } on ChkszCredentialStorageException {
      rethrow;
    } catch (_) {
      throw const ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.write,
      );
    }
  }

  @override
  Future<void> clear() async {
    try {
      final errorCode = _api.clear(chkszWindowsCredentialTargetName);
      if (errorCode == null || errorCode == ERROR_NOT_FOUND) return;
      throw ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.clear,
        errorCode: errorCode,
      );
    } on ChkszCredentialStorageException {
      rethrow;
    } catch (_) {
      throw const ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.clear,
      );
    }
  }

  @override
  String toString() => 'WindowsChkszCredentialStore';
}

final class _Win32CredentialManagerApi implements ChkszCredentialManagerApi {
  const _Win32CredentialManagerApi();

  @override
  ChkszCredentialManagerReadResult read(String targetName) {
    return using((arena) {
      final target = targetName.toNativeUtf16(allocator: arena);
      final output = arena<Pointer<CREDENTIAL>>();
      try {
        if (CredRead(target, CRED_TYPE_GENERIC, 0, output) != TRUE) {
          return ChkszCredentialManagerReadResult.failure(GetLastError());
        }
        if (output.value.address == 0) {
          return const ChkszCredentialManagerReadResult.failure(
            ERROR_INVALID_DATA,
          );
        }
        final credential = output.value.ref;
        final bytes = credential.CredentialBlobSize == 0
            ? const <int>[]
            : List<int>.of(
                credential.CredentialBlob.asTypedList(
                  credential.CredentialBlobSize,
                ),
              );
        return ChkszCredentialManagerReadResult.success(bytes);
      } finally {
        if (output.value.address != 0) CredFree(output.value);
      }
    });
  }

  @override
  int? write({
    required String targetName,
    required String userName,
    required List<int> bytes,
  }) {
    return using((arena) {
      final target = targetName.toNativeUtf16(allocator: arena);
      final user = userName.toNativeUtf16(allocator: arena);
      final blob = arena<Uint8>(bytes.length);
      blob.asTypedList(bytes.length).setAll(0, bytes);
      final credential = arena<CREDENTIAL>()
        ..ref.Type = CRED_TYPE_GENERIC
        ..ref.TargetName = target
        ..ref.Persist = CRED_PERSIST_LOCAL_MACHINE
        ..ref.UserName = user
        ..ref.CredentialBlob = blob
        ..ref.CredentialBlobSize = bytes.length;

      return CredWrite(credential, 0) == TRUE ? null : GetLastError();
    });
  }

  @override
  int? clear(String targetName) {
    return using((arena) {
      final target = targetName.toNativeUtf16(allocator: arena);
      return CredDelete(target, CRED_TYPE_GENERIC, 0) == TRUE
          ? null
          : GetLastError();
    });
  }
}
