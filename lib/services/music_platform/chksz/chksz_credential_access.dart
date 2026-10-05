import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider_factory.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';

/// ChkSz 的按引用凭据入口。
///
/// 同一引用在进程内复用同一个出口，因此 portable 模式（内存凭据）下
/// 界面写入的 Key 与运行中的 Provider 读到的是同一份。
final class ChkszCredentialAccess implements OnlineMusicCredentialAccess {
  ChkszCredentialAccess({required bool portableBuild})
    : _portableBuild = portableBuild;

  final bool _portableBuild;
  final Map<String, ChkszCredentialProvider> _providers = {};

  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'chksz_...';

  @override
  bool isValidFormat(String value) => isValidChkszApiKeyFormat(value);

  @override
  Future<bool> isConfigured(String reference) async =>
      await _provider(reference).readApiKey() != null;

  @override
  Future<void> save(String reference, String value) =>
      _provider(reference).writeApiKey(value);

  @override
  Future<void> clear(String reference) => _provider(reference).clearApiKey();

  ChkszCredentialProvider _provider(String reference) =>
      _providers.putIfAbsent(
        reference,
        () => createChkszCredentialProvider(
          portableBuild: _portableBuild,
          credentialReference: reference,
        ),
      );

  @override
  String toString() =>
      'ChkszCredentialAccess(portable=$_portableBuild, slots=${_providers.length})';
}
