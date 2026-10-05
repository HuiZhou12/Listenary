import 'package:flutter/foundation.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/services/music_platform/online_music_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// 已保存配置的读写出口。
abstract interface class OnlineMusicSettingsStore {
  OnlineMusicSettings read();

  /// 返回是否成功落盘。
  Future<bool> write(OnlineMusicSettings settings);
}

/// 落地到 `app_preference.json` 的 `onlineMusic` 键。
final class AppPreferenceOnlineMusicSettingsStore
    implements OnlineMusicSettingsStore {
  const AppPreferenceOnlineMusicSettingsStore();

  @override
  OnlineMusicSettings read() => AppPreference.instance.onlineMusicSettings;

  @override
  Future<bool> write(OnlineMusicSettings settings) {
    AppPreference.instance.setOnlineMusicSettings(settings);
    return AppPreference.instance.save();
  }
}

/// 设置页「在线音乐」的数据入口。
///
/// - [settings] 是当前**已保存**的配置，界面在它上面编辑；
/// - [activeSettings] 是当前进程内**正在生效**的配置（启动时组装 Provider 用的那份），
///   两者不同即表示需要重启才会生效；
/// - 凭据按引用读写，所以新增条目无需重启就能先配好 Key。
final class OnlineMusicProviderSettingsController extends ChangeNotifier {
  OnlineMusicProviderSettingsController({
    required OnlineMusicSettings activeSettings,
    required OnlineMusicSettingsStore store,
    required OnlineMusicCredentialAccess fallbackCredentials,
    Map<String, OnlineMusicCredentialController> runningCredentials = const {},
  }) : _activeSettings = activeSettings,
       _store = store,
       _fallbackCredentials = fallbackCredentials,
       _runningCredentials = Map.unmodifiable(runningCredentials),
       _settings = store.read();

  final OnlineMusicSettings _activeSettings;
  final OnlineMusicSettingsStore _store;
  final OnlineMusicCredentialAccess _fallbackCredentials;
  final Map<String, OnlineMusicCredentialController> _runningCredentials;
  OnlineMusicSettings _settings;
  bool _disposed = false;

  OnlineMusicSettings get settings => _settings;

  OnlineMusicSettings get activeSettings => _activeSettings;

  /// 是否有尚未生效（需要重启）的改动。
  bool get hasPendingRestart => _settings != _activeSettings;

  String get credentialDisplayName => _fallbackCredentials.credentialDisplayName;

  String get credentialHint => _fallbackCredentials.inputHint;

  bool isCredentialFormatValid(String value) =>
      _fallbackCredentials.isValidFormat(value);

  Set<String> get providerIds => _settings.providerIds;

  /// 已进入运行时的条目用运行中的凭据入口（保留其取消/配额语义），
  /// 新增条目回落到按引用访问。
  OnlineMusicCredentialController? _runningFor(
    OnlineMusicProviderDefinition definition,
  ) => _runningCredentials[definition.id];

  /// 写入一次配置改动；落盘失败时把界面状态回滚为改动前的值。
  Future<bool> apply(OnlineMusicSettings next) async {
    if (next == _settings) return true;
    final previous = _settings;
    _settings = next;
    _notify();
    final saved = await _store.write(next);
    if (!saved && !_disposed) {
      _settings = previous;
      _notify();
    }
    return saved;
  }

  Future<bool> addProvider(OnlineMusicProviderDefinition provider) =>
      apply(_settings.withAddedProvider(provider));

  Future<bool> updateProvider(OnlineMusicProviderDefinition provider) =>
      apply(_settings.withUpdatedProvider(provider));

  Future<bool> removeProvider(String providerId) =>
      apply(_settings.withoutProvider(providerId));

  Future<bool> assignCapability(
    OnlineMusicCapability capability,
    String providerId,
  ) => apply(_settings.withCapabilityProvider(capability, providerId));

  Future<bool> setDefaultProvider(String providerId) =>
      apply(_settings.withDefaultProvider(providerId));

  Future<bool> isCredentialConfigured(
    OnlineMusicProviderDefinition definition,
  ) async {
    final running = _runningFor(definition);
    if (running != null) return running.isConfigured();
    final reference = definition.credentialReference;
    if (reference == null) return false;
    return _fallbackCredentials.isConfigured(reference);
  }

  Future<void> saveCredential(
    OnlineMusicProviderDefinition definition,
    String value,
  ) async {
    final running = _runningFor(definition);
    if (running != null) return running.saveCredential(value);
    final reference = definition.credentialReference;
    if (reference == null) {
      throw const FormatException('该 Provider 不需要 API Key');
    }
    return _fallbackCredentials.save(reference, value);
  }

  Future<void> clearCredential(OnlineMusicProviderDefinition definition) {
    final running = _runningFor(definition);
    if (running != null) return running.clearCredential();
    final reference = definition.credentialReference;
    if (reference == null) return Future<void>.value();
    return _fallbackCredentials.clear(reference);
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  String toString() =>
      'OnlineMusicProviderSettingsController(providers=${providerIds.length}, '
      'pendingRestart=$hasPendingRestart)';
}
