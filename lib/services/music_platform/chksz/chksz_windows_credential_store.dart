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
  WindowsChkszCredentialStore({
    ChkszCredentialManagerApi? api,
    this.targetName = chkszWindowsCredentialTargetName,
  }) : _api = api ?? const _Win32CredentialManagerApi();

  final ChkszCredentialManagerApi _api;

  /// 凭据槽位名；不同 Provider 可以用不同的槽位得到各自的 Key。
  final String targetName;

  @override
  Future<String?> read() async {
    try {
      final result = _api.read(targetName);
      final errorCode = result.errorCode;
      // ⚠️ **真机实测（F0 验证）**：进程内**第一个**凭据调用可能是
      // "返回 FALSE 但 `GetLastError()` 是 0（ERROR_SUCCESS）"；从第二次调用起，
      // 同一个调用会正确返回 ERROR_NOT_FOUND(1168)。
      //
      // 这个组合自相矛盾：FALSE 说明调用**没有成功**，而 0 不是 CredRead 的合法失败码
      // ⇒ 唯一自洽的读法是"目标不存在"。
      // 不处理它就会把"槽位不存在"误判成"读取失败"：界面里的凭据状态读不出来，
      // 而 F0 的迁移会把"不存在"判成"无法可靠确认"从而**拒绝迁移**。
      if (errorCode == ERROR_NOT_FOUND || errorCode == ERROR_SUCCESS) return null;
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
        targetName: targetName,
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
      final errorCode = _api.clear(targetName);
      // 同 `read()` 的实测说明：FALSE + ERROR_SUCCESS 只能读作"本来就不存在"
      //（清除是幂等的：目标不在就等于已经清干净）。
      if (errorCode == null ||
          errorCode == ERROR_NOT_FOUND ||
          errorCode == ERROR_SUCCESS) {
        return;
      }
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
