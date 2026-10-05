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

  /// 界面新增条目：只暴露标识、服务地址与是否需要 Key，其余用默认值。
  factory OnlineMusicProviderDefinition.custom({
    required String id,
    required String baseUrl,
    required bool requiresCredential,
    String? credentialReference,
  }) {
    return OnlineMusicProviderDefinition(
      id: id,
      protocol: defaultOnlineMusicProtocol,
      baseUrl: normalizeOnlineMusicBaseUrl(baseUrl),
      connectTimeout: defaultOnlineMusicConnectTimeout,
      sendTimeout: defaultOnlineMusicSendTimeout,
      receiveTimeout: defaultOnlineMusicReceiveTimeout,
      credentialReference: requiresCredential
          ? (credentialReference ?? deriveOnlineMusicCredentialReference(id))
          : null,
      parameterName: defaultOnlineMusicCredentialParameter,
      capabilityAuth: const {},
    );
  }

  /// 界面可编辑的部分：服务地址与认证方式；标识与协议保持不变。
  OnlineMusicProviderDefinition editedBy({
    required String baseUrl,
    required bool requiresCredential,
  }) {
    final reference = requiresCredential
        ? (credentialReference ?? deriveOnlineMusicCredentialReference(id))
        : null;
    return OnlineMusicProviderDefinition(
      id: id,
      protocol: protocol,
      baseUrl: normalizeOnlineMusicBaseUrl(baseUrl),
      connectTimeout: connectTimeout,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
      credentialReference: reference,
      parameterName: parameterName,
      capabilityAuth: capabilityAuth,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'protocol': protocol,
    'baseUrl': baseUrl,
    'connectTimeoutMs': connectTimeout.inMilliseconds,
    'sendTimeoutMs': sendTimeout.inMilliseconds,
    'receiveTimeoutMs': receiveTimeout.inMilliseconds,
    'auth': authToJson(),
    if (capabilityAuth.isNotEmpty)
      'capabilityAuth': {
        for (final entry in capabilityAuth.entries)
          entry.key.name: entry.value is OnlineMusicNoAuth ? 'none' : 'apiKey',
      },
  };

  Map<String, dynamic> authToJson() {
    final reference = credentialReference;
    if (reference == null) return const {'kind': 'none'};
    return {'kind': 'apiKey', 'reference': reference, 'parameter': parameterName};
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicProviderDefinition &&
      other.id == id &&
      other.protocol == protocol &&
      other.baseUrl == baseUrl &&
      other.connectTimeout == connectTimeout &&
      other.sendTimeout == sendTimeout &&
      other.receiveTimeout == receiveTimeout &&
      other.credentialReference == credentialReference &&
      other.parameterName == parameterName &&
      _sameCapabilityAuth(other.capabilityAuth, capabilityAuth);

  @override
  int get hashCode => Object.hash(
    id,
    protocol,
    baseUrl,
    connectTimeout,
    sendTimeout,
    receiveTimeout,
    credentialReference,
    parameterName,
    Object.hashAllUnordered(
      capabilityAuth.entries.map((entry) {
        final auth = entry.value;
        return Object.hash(
          entry.key,
          auth is OnlineMusicNoAuth,
          auth is OnlineMusicApiKeyAuth ? auth.parameterName : null,
        );
      }),
    ),
  );

  @override
  String toString() =>
      'OnlineMusicProviderDefinition($id, $baseUrl, '
      'credential=${credentialReference != null})';
}

bool _sameCapabilityAuth(
  Map<OnlineMusicCapability, OnlineMusicProviderAuth> a,
  Map<OnlineMusicCapability, OnlineMusicProviderAuth> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final mine = entry.value;
    final other = b[entry.key];
    if (other == null || other.runtimeType != mine.runtimeType) {
      return false;
    }
    if (mine is OnlineMusicApiKeyAuth &&
        other is OnlineMusicApiKeyAuth &&
        other.parameterName != mine.parameterName) {
      return false;
    }
  }
  return true;
}

const defaultOnlineMusicProviderId = 'chksz';
const defaultOnlineMusicProtocol = 'chksz';

/// 界面上新增条目时不允许使用的标识（与既有默认条目冲突）。
const reservedOnlineMusicProviderIds = {defaultOnlineMusicProviderId};

/// 界面新增条目时的轻量校验：非空、无空白、未保留、不重复。
String? validateOnlineMusicProviderId(
  String value, {
  required Set<String> existingIds,
}) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '请填写标识';
  if (RegExp(r'\s').hasMatch(normalized)) return '标识不能包含空白';
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    return '标识只能包含字母、数字、下划线或连字符';
  }
  if (reservedOnlineMusicProviderIds.contains(normalized)) return '该标识已被占用';
  if (existingIds.contains(normalized)) return '该标识已存在';
  return null;
}

/// 界面新增条目时派生凭据槽位名；引用只是槽位，不含凭据值。
String deriveOnlineMusicCredentialReference(String providerId) =>
    'PureMusic/$providerId/APIKey';

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

  Set<String> get providerIds => {for (final p in providers) p.id};

  OnlineMusicProviderDefinition? providerById(String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// 某个能力实际会用到的 Provider id（缺失/未注册时回落默认）。
  String resolvedProviderIdFor(OnlineMusicCapability capability) {
    final requested = capabilityProviders[capability];
    if (requested != null && providerIds.contains(requested)) return requested;
    return providerIds.contains(defaultProviderId)
        ? defaultProviderId
        : providers.first.id;
  }

  /// 新增一个条目；标识重复时返回原值（界面已先行校验）。
  OnlineMusicSettings withAddedProvider(
    OnlineMusicProviderDefinition provider,
  ) {
    if (providerIds.contains(provider.id)) return this;
    return OnlineMusicSettings(
      providers: List.unmodifiable([...providers, provider]),
      defaultProviderId: defaultProviderId,
      capabilityProviders: capabilityProviders,
    );
  }

  /// 替换一个条目的可编辑字段；找不到时返回原值。
  OnlineMusicSettings withUpdatedProvider(
    OnlineMusicProviderDefinition provider,
  ) {
    if (!providerIds.contains(provider.id)) return this;
    return OnlineMusicSettings(
      providers: List.unmodifiable([
        for (final existing in providers)
          if (existing.id == provider.id) provider else existing,
      ]),
      defaultProviderId: defaultProviderId,
      capabilityProviders: capabilityProviders,
    );
  }

  /// 删除一个条目：默认 Provider 与指向它的能力分配一并回落到新的首项。
  /// 列表只允许删到剩一个条目。
  OnlineMusicSettings withoutProvider(String providerId) {
    if (providers.length <= 1 || !providerIds.contains(providerId)) return this;
    final remaining = [
      for (final provider in providers)
        if (provider.id != providerId) provider,
    ];
    final nextDefault = remaining.first.id;
    return OnlineMusicSettings(
      providers: List.unmodifiable(remaining),
      defaultProviderId: defaultProviderId == providerId
          ? nextDefault
          : defaultProviderId,
      capabilityProviders: Map.unmodifiable({
        for (final entry in capabilityProviders.entries)
          if (entry.value != providerId) entry.key: entry.value,
      }),
    );
  }

  OnlineMusicSettings withCapabilityProvider(
    OnlineMusicCapability capability,
    String providerId,
  ) {
    if (!providerIds.contains(providerId)) return this;
    return OnlineMusicSettings(
      providers: providers,
      defaultProviderId: defaultProviderId,
      capabilityProviders: Map.unmodifiable({
        ...capabilityProviders,
        capability: providerId,
      }),
    );
  }

  OnlineMusicSettings withDefaultProvider(String providerId) {
    if (!providerIds.contains(providerId)) return this;
    return OnlineMusicSettings(
      providers: providers,
      defaultProviderId: providerId,
      capabilityProviders: capabilityProviders,
    );
  }

  /// 写回 `app_preference.json` 的结构；键名与 [OnlineMusicSettings.fromJson] 一致。
  Map<String, dynamic> toJson() => {
    'defaultProvider': defaultProviderId,
    'providers': [for (final provider in providers) provider.toJson()],
    'capabilities': {
      for (final entry in capabilityProviders.entries)
        entry.key.name: entry.value,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicSettings &&
      other.defaultProviderId == defaultProviderId &&
      _sameProviders(other.providers, providers) &&
      _sameCapabilityProviders(other.capabilityProviders, capabilityProviders);

  @override
  int get hashCode => Object.hash(
    defaultProviderId,
    Object.hashAll(providers),
    Object.hashAllUnordered(capabilityProviders.entries.map(
      (entry) => Object.hash(entry.key, entry.value),
    )),
  );

  @override
  String toString() =>
      'OnlineMusicSettings(${providers.length} providers, '
      'default=$defaultProviderId, capabilities=${capabilityProviders.length})';

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

bool _sameProviders(
  List<OnlineMusicProviderDefinition> a,
  List<OnlineMusicProviderDefinition> b,
) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _sameCapabilityProviders(
  Map<OnlineMusicCapability, String> a,
  Map<OnlineMusicCapability, String> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
