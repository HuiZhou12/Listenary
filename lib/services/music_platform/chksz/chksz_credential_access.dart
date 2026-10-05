import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider_factory.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';

/// ChkSz 的按引用凭据入口。
///
/// 同一引用在进程内复用同一个出口，因此 portable 模式（内存凭据）下
/// 界面写入的 Key 与运行中的 Provider 读到的是同一份。
final class ChkszCredentialAccess
    implements OnlineMusicCredentialAccess, OnlineMusicCredentialReader {
  ChkszCredentialAccess({required bool portableBuild})
    : _portableBuild = portableBuild;

  final bool _portableBuild;
  final Map<String, ChkszCredentialProvider> _providers = {};

  /// 同一引用在进程内复用同一个出口；内置实现与声明式执行者共用它，
  /// 因此 portable 模式（内存凭据）下界面写入的 Key 与发起请求时读到的是同一份。
  ChkszCredentialProvider providerFor(String reference) =>
      _provider(reference);

  @override
  Future<String?> readCredential(String reference) =>
      _provider(reference).readApiKey();

  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'API Key';

  /// 通用凭据槽位不做格式限制：凭据形态由各自协议决定（ChkSz 的 `chksz_` 前缀只适用于 ChkSz，
  /// 自建 Provider 的 Key 完全是另一种形状）。ChkSz 自身仍会在发请求前校验并给出明确原因。
  @override
  bool isValidFormat(String value) => value.trim().isNotEmpty;

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
          validateFormat: (value) => value.trim().isNotEmpty,
        ),
      );

  @override
  String toString() =>
      'ChkszCredentialAccess(portable=$_portableBuild, slots=${_providers.length})';
}
