import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';

const defaultOnlineMusicBaseUrl = 'https://api.chksz.com';
const defaultOnlineMusicConnectTimeout = Duration(seconds: 8);
const defaultOnlineMusicSendTimeout = Duration(seconds: 8);
const defaultOnlineMusicReceiveTimeout = Duration(seconds: 10);

/// 只接受 http/https 且带 host 的绝对地址；其余一律回落默认值。
String normalizeOnlineMusicBaseUrl(Object? value) {
  if (value is! String) return defaultOnlineMusicBaseUrl;
  final normalized = value.trim();
  if (normalized.isEmpty) return defaultOnlineMusicBaseUrl;
  final uri = Uri.tryParse(normalized);
  if (uri == null) return defaultOnlineMusicBaseUrl;
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return defaultOnlineMusicBaseUrl;
  }
  if (uri.host.isEmpty) return defaultOnlineMusicBaseUrl;
  return normalized;
}

/// 非正数或不可解析的值回落默认超时。
Duration normalizeOnlineMusicTimeout(
  Object? value, {
  required Duration defaultValue,
}) {
  final milliseconds = switch (value) {
    int() => value,
    num() => value.isFinite ? value.toInt() : null,
    String() => int.tryParse(value.trim()),
    _ => null,
  };
  if (milliseconds == null || milliseconds <= 0) return defaultValue;
  return Duration(milliseconds: milliseconds);
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

/// 一个 Provider 条目的配置；不包含任何凭据值，只包含凭据槽位名。
final class OnlineMusicProviderDefinition {
  const OnlineMusicProviderDefinition({
    required this.id,
    required this.protocol,
    required this.baseUrl,
    required this.connectTimeout,
    required this.sendTimeout,
    required this.receiveTimeout,
    required this.credentialReference,
    required this.parameterName,
    required this.capabilityAuth,
  });

  static const defaultCredentialReference = 'PureMusic/ChKSz/APIKey';

  /// 默认条目：与既有版本的连接、认证与超时完全一致。
  static const defaults = OnlineMusicProviderDefinition(
    id: defaultOnlineMusicProviderId,
    protocol: defaultOnlineMusicProtocol,
    baseUrl: defaultOnlineMusicBaseUrl,
    connectTimeout: defaultOnlineMusicConnectTimeout,
    sendTimeout: defaultOnlineMusicSendTimeout,
    receiveTimeout: defaultOnlineMusicReceiveTimeout,
    credentialReference: defaultCredentialReference,
    parameterName: defaultOnlineMusicCredentialParameter,
    capabilityAuth: {},
  );

  final String id;
  final String protocol;
  final String baseUrl;
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;

  /// 凭据槽位名；null 表示该 Provider 不需要凭据。
  final String? credentialReference;
  final String parameterName;

  /// 能力级认证覆盖；未列出的能力使用 Provider 默认要求。
  final Map<OnlineMusicCapability, OnlineMusicProviderAuth> capabilityAuth;

  bool get requiresCredential => credentialReference != null;

  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability) {
    final override = capabilityAuth[capability];
    if (override != null) return override;
    final reference = credentialReference;
    if (reference == null) return const OnlineMusicNoAuth();
    return OnlineMusicApiKeyAuth(parameterName: parameterName);
  }
}

const defaultOnlineMusicProviderId = 'chksz';
const defaultOnlineMusicProtocol = 'chksz';

/// 在线音乐 Provider 与能力映射的配置。
final class OnlineMusicSettings {
  const OnlineMusicSettings({
    required this.providers,
    required this.defaultProviderId,
    required this.capabilityProviders,
  });

  static const defaults = OnlineMusicSettings(
    providers: [OnlineMusicProviderDefinition.defaults],
    defaultProviderId: defaultOnlineMusicProviderId,
    capabilityProviders: {},
  );

  final List<OnlineMusicProviderDefinition> providers;
  final String defaultProviderId;

  /// 能力 → Provider id；缺失或指向未注册 id 时回落默认 Provider。
  final Map<OnlineMusicCapability, String> capabilityProviders;

  /// 解析 `onlineMusic` 配置；任何缺失、非法或未注册的内容逐项回落默认。
  factory OnlineMusicSettings.fromJson(Object? value) {
    if (value is! Map) return defaults;
    final providers = _parseProviders(value['providers']);
    final ids = {for (final provider in providers) provider.id};
    final requestedDefault = _nonEmptyString(value['defaultProvider']);
    return OnlineMusicSettings(
      providers: providers,
      defaultProviderId: (requestedDefault != null && ids.contains(requestedDefault))
          ? requestedDefault
          : providers.first.id,
      capabilityProviders: _parseCapabilityProviders(
        value['capabilities'],
        ids,
      ),
    );
  }

  static List<OnlineMusicProviderDefinition> _parseProviders(Object? value) {
    if (value is! List) return defaults.providers;
    final result = <OnlineMusicProviderDefinition>[];
    final seen = <String>{};
    for (final entry in value) {
      final provider = _parseProvider(entry);
      if (provider == null) continue;
      if (!seen.add(provider.id)) continue;
      result.add(provider);
    }
    return result.isEmpty ? defaults.providers : List.unmodifiable(result);
  }

  static OnlineMusicProviderDefinition? _parseProvider(Object? value) {
    if (value is! Map) return null;
    final id = _nonEmptyString(value['id']);
    if (id == null) return null;
    final protocol =
        _nonEmptyString(value['protocol']) ?? defaultOnlineMusicProtocol;
    if (protocol != defaultOnlineMusicProtocol) return null;

    final auth = value['auth'];
    final authMap = auth is Map ? auth : const <Object?, Object?>{};
    // 只识别 `none` 与 `apiKey`；缺失或无法识别的 kind 一律按默认的 `apiKey`
    // 处理（与「未知 protocol 忽略整个条目」不同：认证缺失必须落到安全的默认要求，
    // 不能让一个条目因为拼错 kind 而变成无凭据可用的 Provider）。
    final kind = _nonEmptyString(authMap['kind']) ?? 'apiKey';
    final reference = kind == 'none'
        ? null
        : (_nonEmptyString(authMap['reference']) ??
              OnlineMusicProviderDefinition.defaultCredentialReference);
    final parameterName =
        _nonEmptyString(authMap['parameter']) ??
        defaultOnlineMusicCredentialParameter;

    return OnlineMusicProviderDefinition(
      id: id,
      protocol: protocol,
      baseUrl: normalizeOnlineMusicBaseUrl(value['baseUrl']),
      connectTimeout: normalizeOnlineMusicTimeout(
        value['connectTimeoutMs'],
        defaultValue: defaultOnlineMusicConnectTimeout,
      ),
      sendTimeout: normalizeOnlineMusicTimeout(
        value['sendTimeoutMs'],
        defaultValue: defaultOnlineMusicSendTimeout,
      ),
      receiveTimeout: normalizeOnlineMusicTimeout(
        value['receiveTimeoutMs'],
        defaultValue: defaultOnlineMusicReceiveTimeout,
      ),
      credentialReference: reference,
      parameterName: parameterName,
      capabilityAuth: _parseCapabilityAuth(
        value['capabilityAuth'],
        reference: reference,
        parameterName: parameterName,
      ),
    );
  }

  static Map<OnlineMusicCapability, OnlineMusicProviderAuth>
  _parseCapabilityAuth(
    Object? value, {
    required String? reference,
    required String parameterName,
  }) {
    if (value is! Map) return const {};
    final result = <OnlineMusicCapability, OnlineMusicProviderAuth>{};
    for (final capability in OnlineMusicCapability.values) {
      final kind = _nonEmptyString(value[capability.name]);
      if (kind == null) continue;
      switch (kind) {
        case 'none':
          result[capability] = const OnlineMusicNoAuth();
        case 'apiKey':
          if (reference != null) {
            result[capability] = OnlineMusicApiKeyAuth(
              parameterName: parameterName,
            );
          }
      }
    }
    return Map.unmodifiable(result);
  }

  static Map<OnlineMusicCapability, String> _parseCapabilityProviders(
    Object? value,
    Set<String> ids,
  ) {
    if (value is! Map) return const {};
    final result = <OnlineMusicCapability, String>{};
    for (final capability in OnlineMusicCapability.values) {
      final id = _nonEmptyString(value[capability.name]);
      if (id == null || !ids.contains(id)) continue;
      result[capability] = id;
    }
    return Map.unmodifiable(result);
  }
}
