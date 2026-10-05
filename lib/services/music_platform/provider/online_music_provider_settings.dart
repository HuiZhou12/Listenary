import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
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
    required this.requiresCredential,
    required this.parameterName,
    required this.capabilityAuth,
    this.capabilities,
    this.contentPlatform = MusicPlatform.netease,
    this.displayName = '',
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
    requiresCredential: true,
    parameterName: defaultOnlineMusicCredentialParameter,
    capabilityAuth: {},
  );

  final String id;
  final String protocol;
  final String baseUrl;

  /// 展示名；留空时回落到 [id]。它只影响界面文案，不参与任何映射。
  final String displayName;

  /// 界面上展示的名字（displayName 优先）。
  String get label => displayName.trim().isEmpty ? id : displayName.trim();
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;

  /// 凭据槽位名。
  ///
  /// 槽位与「当前是否需要凭据」是两件事：关闭认证时**保留**槽位，
  /// 这样再次打开认证不会改写槽位、也就不会孤立用户已经保存的 Key。
  final String? credentialReference;

  /// 该条目当前是否使用凭据。
  final bool requiresCredential;

  final String parameterName;

  /// 该条目代理的**内容来源**（D1）。
  ///
  /// 身份模型（`PlatformTrackRef.platform`）本轮不泛化，因此自建 Provider 必须声明
  /// 它代理哪一家的内容；非 netease 型来源属于当前模型的边界。
  final MusicPlatform contentPlatform;

  /// 逐能力绑定。
  ///
  /// `null` 表示配置里**没有** `capabilities` 这个 key —— 那是旧条目，按 [protocol] 解释；
  /// 非 null（即使是空 Map）表示条目已进入新模型，此时 [protocol] 被完全忽略。
  /// 这个「key 是否存在」的判别式就是 §5.3 定义的唯一优先级规则。
  final Map<OnlineMusicCapability, OnlineMusicCapabilityBinding>? capabilities;

  /// 该能力最终生效的绑定（含旧条目的兼容解释）。
  OnlineMusicCapabilityBinding bindingFor(OnlineMusicCapability capability) {
    final explicit = capabilities;
    if (explicit != null) {
      return explicit[capability] ??
          const OnlineMusicUnsupportedCapabilityBinding();
    }
    if (protocol == builtinOnlineMusicChkszId) {
      return const OnlineMusicBuiltinCapabilityBinding();
    }
    return const OnlineMusicUnsupportedCapabilityBinding();
  }

  /// 条目级 + 能力级配置校验；空列表表示可用。
  List<String> validationIssues() {
    final issues = <String>[];
    final idError = validateOnlineMusicProviderId(
      id,
      existingIds: const {},
      allowReserved: true,
    );
    if (idError != null) issues.add(idError);
    if (normalizeOnlineMusicBaseUrl(baseUrl) != baseUrl) {
      issues.add('服务地址无效或会被回落为默认值');
    }
    final explicit = capabilities;
    if (explicit != null) {
      for (final entry in explicit.entries) {
        for (final issue in entry.value.validationIssues(entry.key)) {
          issues.add('${entry.key.name}：$issue');
        }
      }
    }
    return issues;
  }

  /// 能力级认证覆盖；未列出的能力使用 Provider 默认要求。
  final Map<OnlineMusicCapability, OnlineMusicProviderAuth> capabilityAuth;

  OnlineMusicProviderAuth authFor(OnlineMusicCapability capability) {
    final override = capabilityAuth[capability];
    if (override != null) return override;
    if (!requiresCredential || credentialReference == null) {
      return const OnlineMusicNoAuth();
    }
    return OnlineMusicApiKeyAuth(parameterName: parameterName);
  }

  /// 界面新增条目：只暴露标识、服务地址与是否需要 Key，其余用默认值。
  ///
  /// 槽位总是先派生好（即使当前不需要 Key），以便之后打开认证时复用。
  factory OnlineMusicProviderDefinition.custom({
    required String id,
    required String baseUrl,
    required bool requiresCredential,
    String? credentialReference,
    String displayName = '',
    MusicPlatform contentPlatform = MusicPlatform.netease,
  }) {
    return OnlineMusicProviderDefinition(
      id: id,
      protocol: defaultOnlineMusicProtocol,
      baseUrl: normalizeOnlineMusicBaseUrl(baseUrl),
      displayName: displayName.trim(),
      contentPlatform: contentPlatform,
      connectTimeout: defaultOnlineMusicConnectTimeout,
      sendTimeout: defaultOnlineMusicSendTimeout,
      receiveTimeout: defaultOnlineMusicReceiveTimeout,
      credentialReference:
          credentialReference ?? deriveOnlineMusicCredentialReference(id),
      requiresCredential: requiresCredential,
      parameterName: defaultOnlineMusicCredentialParameter,
      capabilityAuth: const {},
      // 新条目一律写入 capabilities（即使为空）：这样它永远走新模型，
      // 未配置的能力就是「不支持」，而不是被当成旧条目按 ChkSz 协议执行。
      capabilities: const {},
    );
  }

  /// 界面可编辑的部分：服务地址、认证方式与内容来源；标识、协议与凭据槽位保持不变。
  OnlineMusicProviderDefinition editedBy({
    required String baseUrl,
    required bool requiresCredential,
    MusicPlatform? contentPlatform,
    String? displayName,
  }) {
    return OnlineMusicProviderDefinition(
      id: id,
      protocol: protocol,
      baseUrl: normalizeOnlineMusicBaseUrl(baseUrl),
      displayName: displayName?.trim() ?? this.displayName,
      connectTimeout: connectTimeout,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
      credentialReference:
          credentialReference ?? deriveOnlineMusicCredentialReference(id),
      requiresCredential: requiresCredential,
      parameterName: parameterName,
      capabilityAuth: capabilityAuth,
      capabilities: capabilities,
      contentPlatform: contentPlatform ?? this.contentPlatform,
    );
  }

  /// 替换某个能力的绑定；条目因此进入新模型（`capabilities` 不再是 null）。
  OnlineMusicProviderDefinition withCapabilityBinding(
    OnlineMusicCapability capability,
    OnlineMusicCapabilityBinding binding,
  ) {
    return OnlineMusicProviderDefinition(
      id: id,
      protocol: protocol,
      baseUrl: baseUrl,
      connectTimeout: connectTimeout,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
      credentialReference: credentialReference,
      requiresCredential: requiresCredential,
      parameterName: parameterName,
      capabilityAuth: capabilityAuth,
      capabilities: Map.unmodifiable({
        ...(capabilities ??
            {
              for (final entry in OnlineMusicCapability.values)
                entry: bindingFor(entry),
            }),
        capability: binding,
      }),
      contentPlatform: contentPlatform,
      displayName: displayName,
    );
  }

  /// 一键按 ChkSz 兼容方式填充（D5）：四能力全部走内置实现，兼容 ChkSz mirror。
  OnlineMusicProviderDefinition withChkszCompatibleCapabilities() {
    return OnlineMusicProviderDefinition(
      id: id,
      protocol: protocol,
      baseUrl: baseUrl,
      connectTimeout: connectTimeout,
      sendTimeout: sendTimeout,
      receiveTimeout: receiveTimeout,
      credentialReference: credentialReference,
      requiresCredential: requiresCredential,
      parameterName: parameterName,
      capabilityAuth: capabilityAuth,
      capabilities: const {
        OnlineMusicCapability.search: OnlineMusicBuiltinCapabilityBinding(),
        OnlineMusicCapability.playlist: OnlineMusicBuiltinCapabilityBinding(),
        OnlineMusicCapability.lyric: OnlineMusicBuiltinCapabilityBinding(),
        OnlineMusicCapability.stream: OnlineMusicBuiltinCapabilityBinding(),
      },
      contentPlatform: contentPlatform,
      displayName: displayName,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'protocol': protocol,
    'baseUrl': baseUrl,
    if (displayName.trim().isNotEmpty) 'displayName': displayName,
    'contentPlatform': contentPlatform.name,
    'connectTimeoutMs': connectTimeout.inMilliseconds,
    'sendTimeoutMs': sendTimeout.inMilliseconds,
    'receiveTimeoutMs': receiveTimeout.inMilliseconds,
    'auth': authToJson(),
    if (capabilityAuth.isNotEmpty)
      'capabilityAuth': {
        for (final entry in capabilityAuth.entries)
          entry.key.name: entry.value is OnlineMusicNoAuth ? 'none' : 'apiKey',
      },
    if (capabilities != null)
      'capabilities': {
        for (final entry in capabilities!.entries)
          entry.key.name: entry.value.toJson(),
      },
  };

  Map<String, dynamic> authToJson() {
    final reference = credentialReference;
    return {
      'kind': requiresCredential ? 'apiKey' : 'none',
      'reference': ?reference,
      'parameter': parameterName,
    };
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
      other.requiresCredential == requiresCredential &&
      other.parameterName == parameterName &&
      other.contentPlatform == contentPlatform &&
      other.displayName == displayName &&
      _sameBindings(other.capabilities, capabilities) &&
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
    requiresCredential,
    parameterName,
    contentPlatform,
    displayName,
    // capabilities 为 null 与空 Map 语义不同（旧条目 vs 新条目），必须区分。
    capabilities == null
        ? -1
        : Object.hashAllUnordered(
            capabilities!.entries.map(
              (entry) => Object.hash(entry.key, entry.value),
            ),
          ),
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
      'requiresCredential=$requiresCredential, slot=${credentialReference != null}, '
      'capabilities=${capabilities == null ? 'legacy' : capabilities!.length})';
}

bool _sameBindings(
  Map<OnlineMusicCapability, OnlineMusicCapabilityBinding>? a,
  Map<OnlineMusicCapability, OnlineMusicCapabilityBinding>? b,
) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
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
///
/// [allowReserved] 用于校验**已存在**的条目（默认条目本身就叫 `chksz`）。
String? validateOnlineMusicProviderId(
  String value, {
  required Set<String> existingIds,
  bool allowReserved = false,
}) {
  final normalized = value.trim();
  if (normalized.isEmpty) return '请填写标识';
  if (RegExp(r'\s').hasMatch(normalized)) return '标识不能包含空白';
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    return '标识只能包含字母、数字、下划线或连字符';
  }
  if (!allowReserved && reservedOnlineMusicProviderIds.contains(normalized)) {
    return '该标识已被占用';
  }
  if (existingIds.contains(normalized)) return '该标识已存在';
  return null;
}

/// 界面新增条目时派生凭据槽位名；引用只是槽位，不含凭据值。
///
/// 默认条目复用既有槽位，避免派生出一个与历史 Key 不同的新槽位。
String deriveOnlineMusicCredentialReference(String providerId) =>
    providerId == defaultOnlineMusicProviderId
    ? OnlineMusicProviderDefinition.defaultCredentialReference
    : 'PureMusic/$providerId/APIKey';

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

    // §5.3 的判别式：`capabilities` 这个 key 是否存在。
    // 存在（即使为空对象）⇒ 新模型，protocol 被完全忽略；
    // 不存在 ⇒ 旧条目兼容路径，由 protocol 决定，未知 protocol 沿用既有「忽略该条目」语义。
    final hasCapabilities = value.containsKey('capabilities');
    if (!hasCapabilities && protocol != defaultOnlineMusicProtocol) return null;

    final parsedCapabilities = hasCapabilities
        ? _parseCapabilities(value['capabilities'])
        : null;

    final auth = value['auth'];
    final authMap = auth is Map ? auth : const <Object?, Object?>{};
    // 只识别 `none` 与 `apiKey`；缺失或无法识别的 kind 一律按默认的 `apiKey`
    // 处理（与「未知 protocol 忽略整个条目」不同：认证缺失必须落到安全的默认要求，
    // 不能让一个条目因为拼错 kind 而变成无凭据可用的 Provider）。
    final kind = _nonEmptyString(authMap['kind']) ?? 'apiKey';
    final requiresCredential = kind != 'none';
    // `kind` 与槽位解耦：`kind: none` 也会保留写明的槽位，这样界面关掉再打开认证
    // 不会改写槽位、也不会孤立用户已经保存的 Key。
    final providedReference = _nonEmptyString(authMap['reference']);
    final reference =
        providedReference ??
        (requiresCredential
            ? OnlineMusicProviderDefinition.defaultCredentialReference
            : null);
    final parameterName =
        _nonEmptyString(authMap['parameter']) ??
        defaultOnlineMusicCredentialParameter;

    return OnlineMusicProviderDefinition(
      id: id,
      protocol: protocol,
      contentPlatform: _parseContentPlatform(value['contentPlatform']),
      displayName: _nonEmptyString(value['displayName']) ?? '',
      capabilities: parsedCapabilities,
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
      requiresCredential: requiresCredential,
      parameterName: parameterName,
      capabilityAuth: _parseCapabilityAuth(
        value['capabilityAuth'],
        reference: reference,
        requiresCredential: requiresCredential,
        parameterName: parameterName,
      ),
    );
  }

  static Map<OnlineMusicCapability, OnlineMusicProviderAuth>
  _parseCapabilityAuth(
    Object? value, {
    required String? reference,
    required bool requiresCredential,
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
          } else if (!requiresCredential) {
            // 整个条目都没有槽位时，能力级 apiKey 覆盖无法生效，忽略即可。
            continue;
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

  /// 解析能力绑定。
  ///
  /// 单个能力解析失败只影响该能力（标记为不支持），不影响同一条目的其它能力；
  /// 未写出的能力同样视为「不支持」，不回落 `protocol`。
  static Map<OnlineMusicCapability, OnlineMusicCapabilityBinding>
  _parseCapabilities(Object? value) {
    if (value is! Map) return const {};
    final result = <OnlineMusicCapability, OnlineMusicCapabilityBinding>{};
    for (final capability in OnlineMusicCapability.values) {
      final raw = value[capability.name];
      if (raw == null) continue;
      try {
        result[capability] = OnlineMusicCapabilityBinding.fromJson(raw);
      } on FormatException {
        result[capability] = const OnlineMusicUnsupportedCapabilityBinding();
      }
    }
    return Map.unmodifiable(result);
  }

  /// D1：内容来源只支持既有闭集；无法识别的值回落 netease（默认内容来源）。
  static MusicPlatform _parseContentPlatform(Object? value) {
    final name = _nonEmptyString(value);
    if (name == null) return MusicPlatform.netease;
    for (final platform in MusicPlatform.values) {
      if (platform.name == name) return platform;
    }
    return MusicPlatform.netease;
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
