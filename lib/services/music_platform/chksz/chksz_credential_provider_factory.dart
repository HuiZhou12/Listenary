import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_windows_credential_store.dart';

typedef ChkszCredentialStoreFactory = ChkszCredentialStore Function();

ChkszCredentialProvider createChkszCredentialProvider({
  required bool portableBuild,
  ChkszCredentialStoreFactory? windowsStoreFactory,
}) {
  if (portableBuild) return InMemoryChkszCredentialProvider();

  final store = (windowsStoreFactory ?? WindowsChkszCredentialStore.new)();
  return PersistentChkszCredentialProvider(store: store);
}
