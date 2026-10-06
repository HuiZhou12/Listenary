import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_windows_credential_store.dart';

typedef ChkszCredentialStoreFactory = ChkszCredentialStore Function();

/// 为一个凭据引用建立 Windows 凭据槽位。
ChkszCredentialStore createChkszWindowsCredentialStore(
  String credentialReference,
) => WindowsChkszCredentialStore(targetName: credentialReference);

/// 为一个 Provider 凭据引用建立凭据出口。
///
/// 引用是槽位名而不是凭据值；不同 Provider 使用不同引用即可持有各自的 Key，
/// 默认引用与既有版本一致，因此已保存的 Key 继续可用。
ChkszCredentialProvider createChkszCredentialProvider({
  required bool portableBuild,
  String credentialReference = chkszWindowsCredentialTargetName,
  ChkszCredentialStoreFactory? windowsStoreFactory,
  bool Function(String)? validateFormat,
}) {
  if (portableBuild) {
    return InMemoryChkszCredentialProvider(validateFormat: validateFormat);
  }

  final store = windowsStoreFactory != null
      ? windowsStoreFactory()
      : createChkszWindowsCredentialStore(credentialReference);
  return PersistentChkszCredentialProvider(
    store: store,
    validateFormat: validateFormat,
  );
}
