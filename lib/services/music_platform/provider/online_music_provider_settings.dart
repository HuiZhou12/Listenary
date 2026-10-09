import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';

const defaultOnlineMusicBaseUrl = 'https://api.chksz.com';
const defaultOnlineMusicConnectTimeout = Duration(seconds: 8);
const defaultOnlineMusicSendTimeout = Duration(seconds: 8);
const defaultOnlineMusicReceiveTimeout = Duration(seconds: 10);

/// 用户**显式提供**且非空的 baseUrl；缺失 / 空串 / 非字符串一律 `null`。
///
/// "缺失"与"显式提供了非法值"必须分开（Spec §7.2）：
/// 前者是旧配置没写这一项 ⇒ 允许使用默认值，行为与旧版一致；
/// 后者是用户真的填错了 ⇒ **必须报错**，绝不允许悄悄换成别的主机。
String? explicitOnlineMusicBaseUrl(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// baseUrl 的**非法原因**；`null` 表示可用。
///
/// 空串 = **缺失**（走默认值），因此**不算非法** —— 这正是"不破坏合法旧配置"的那一半。
///
/// **刻意不做任何替换**（P-18）：旧实现的 `normalizeOnlineMusicBaseUrl` 会把
/// `ftp://…` / `/relative/path` / `https://` 一律改写成 `https://api.chksz.com`，
/// 于是用户带着自己的凭据打到了一台他从未指定的主机上。
String? onlineMusicBaseUrlIssue(String baseUrl) {
  final trimmed = baseUrl.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return '服务地址无效';
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return '服务地址必须以 http:// 或 https:// 开头';
  }
  if (uri.host.isEmpty) return '服务地址缺少主机名';
  return null;
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

/// 解析 `capabilities` 时发现的一个**损坏项**（P-32）。
///
/// 只描述"哪里坏了"，**不含配置里的原始值**（[reason] 会进界面文案）。
final class OnlineMusicCapabilityConfigIssue {
  const OnlineMusicCapabilityConfigIssue({
    this.capability,
    required this.reason,
  });

  /// 受影响的单个能力；`null` 表示整块 `capabilities` 都不是对象（影响全部能力）。
  final OnlineMusicCapability? capability;

  /// 原因描述（中文、无原始值）。
  final String reason;

  String get message =>
      capability == null ? reason : '${capability!.name}：$reason';
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
    // P-32：解析期的损坏项，默认空；只有 `fromJson` 会填。
    this.capabilityConfigIssues = const [],
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

  /// 用户**显式提供**的服务地址；空串表示"配置里没这一项"（= 走 [effectiveBaseUrl] 的默认值）。
  ///
  /// 刻意保存**原值**而不是归一化后的值：只有这样才能区分"缺失"与"填错了"，
  /// 也才谈得上"不静默替换"（P-18）。
  final String baseUrl;

  /// 实际生效的服务地址：缺失 ⇒ [defaultOnlineMusicBaseUrl]；显式提供 ⇒ 原样。
  String get effectiveBaseUrl {
    final trimmed = baseUrl.trim();
    return trimmed.isEmpty ? defaultOnlineMusicBaseUrl : trimmed;
  }

  /// 显式提供的地址是否非法（`null` = 可用，含"缺失 ⇒ 用默认值"）。
  String? get baseUrlIssue => onlineMusicBaseUrlIssue(baseUrl);

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

  /// 解析 `capabilities` 时发现的**损坏项**（P-32）。
  ///
  /// 这不是用户配置的一部分，只是**解析期的事实**：
  /// - **不落盘**（`toJson` 不写）、**不参与相等性**（两份只差"哪一项坏了"的配置在
  ///   语义上是同一份配置，且相等性是既向往返/去重逻辑的基础）；
  /// - 由 `fromJson` 在解析时填充，程序化编辑（`_copyWith` 系列）会**清空**它 ——
  ///   用户从编辑器重新保存过这一项之后，它就不再是"损坏的旧数据"了；
  /// - 唯一用途是让 [validationIssues] 如实报出"这一项坏了"，从而把
  ///   **"配置损坏"与"从未配置"**区分开（两者运行期都是"不支持"，但该去哪儿改完全不同）。
  final List<OnlineMusicCapabilityConfigIssue> capabilityConfigIssues;

  /// 该能力最终生效的绑定（含旧条目的兼容解释）。
  ///
  /// 旧条目（配置里没有 `capabilities` 键、`protocol=chksz`）按内置实现解释，
  /// 但**只对它真正实现的那几个能力**（[builtinOnlineMusicCapabilities]）。
  ///
  /// P-19：这里以前对**任意**能力都返回内置实现 ⇒ 平台卡声称 8 个能力、
  /// 运行时只服务 4 个，另外 4 项成了静默的 `unavailable`（界面说能、运行说不能）。
  /// 现在"没实现"就如实是**不支持**：平台卡显示"未配置"，而不是给一个必然失败的候选。
  /// 注意这只改**旧条目的解释**：自定义条目仍按各自 `capabilities` 里的实际绑定判断。
  OnlineMusicCapabilityBinding bindingFor(OnlineMusicCapability capability) {
    final explicit = capabilities;
    if (explicit != null) {
      return explicit[capability] ??
          const OnlineMusicUnsupportedCapabilityBinding();
    }
    if (protocol == builtinOnlineMusicChkszId &&
        builtinOnlineMusicCapabilities.contains(capability)) {
      return const OnlineMusicBuiltinCapabilityBinding();
    }
    return const OnlineMusicUnsupportedCapabilityBinding();
  }

  /// 该条目在 `(platform, capability)` 上**实际**能服务的平台集合。
  ///
  /// 刻意与运行时注册的平台保持一致（`createOnlineMusicComposition` + 各 Provider 的
  /// `platformsFor`），这样设置页的平台卡能如实回答"这个平台下谁能做这件事"：
  /// - 内置实现就是 ChkSz（网易云），**即使**条目把 [contentPlatform] 写成别的平台；
  /// - 声明式实现服务它自己声明的 [contentPlatform]；
  /// - 未配置 / `unsupported` 的能力不服务任何平台。
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) {
    return switch (bindingFor(capability)) {
      OnlineMusicUnsupportedCapabilityBinding() => const {},
      OnlineMusicBuiltinCapabilityBinding() => const {MusicPlatform.netease},
      OnlineMusicDeclarativeCapabilityBinding() => {contentPlatform},
    };
  }

  /// 条目级 + 能力级配置校验；空列表表示可用。
  List<String> validationIssues() {
    // P-32：**解析期**就坏掉的能力项（JSON 写坏、kind 无效、整块不是对象）。
    // 它们以前被静默降级成"不支持"，与"从未配置"在界面上完全同形 ——
    // 用户只会看到"这个能力就是不支持"，无从知道是自己的配置坏了。
    // 注意：运行期语义**没有**放宽（仍然是"不支持"、仍然不发请求）。
    final corrupt = <OnlineMusicCapability>{
      for (final issue in capabilityConfigIssues)
        if (issue.capability != null) issue.capability!,
    };
    final issues = <String>[
      for (final issue in capabilityConfigIssues) issue.message,
    ];
    final idError = validateOnlineMusicProviderId(
      id,
      existingIds: const {},
      allowReserved: true,
    );
    if (idError != null) issues.add(idError);
    final baseUrlIssue = this.baseUrlIssue;
    if (baseUrlIssue != null) {
      // 必须说清"不会被替换"：旧行为会悄悄改成默认主机，这正是 P-18。
      issues.add('$baseUrlIssue（不会回落到默认服务地址）');
    }
    final explicit = capabilities;
    if (explicit != null) {
      for (final entry in explicit.entries) {
        // P-32：解析期坏掉的能力只报"损坏"那一句就够。它的绑定被降级成
        // `unsupported`，会再报一句「尚未配置」—— 而对**配过、但写坏了**的项来说，
        // 那句话恰恰是误导（用户明明配过，只是坏了）。
        if (corrupt.contains(entry.key)) continue;
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
      // 原样保存（不归一化、不替换）：非法值由 validationIssues / 运行时拦下。
      baseUrl: baseUrl.trim(),
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
      baseUrl: baseUrl.trim(),
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

  /// 一键按 ChkSz 兼容方式填充（D5）：**只把 ChkSz 真有实现的四条链路**改成内置实现，
  /// **其余能力（歌单列表 / 分类 / 榜单 / 新歌）原样保留**。
  ///
  /// P-20：旧实现写成 `capabilities: const {四条}` —— 那是**整表替换**，
  /// 用户已经配好的另外四项会被**静默丢弃**（无确认、无撤销）。
  ///
  /// 现在以**该条目现有的 capabilities 为基底**合并：
  /// - 新条目（`capabilities` 为空 Map）⇒ 结果就是"四条内置 + 其余不支持"，
  ///   与旧行为一致（它本来就没东西可丢）；
  /// - 已配好其它能力的条目 ⇒ 那些能力**一个字节都不动**。
  ///
  /// 注意**不**用 `bindingFor` 当基底：对旧条目（`capabilities == null`）它会对
  /// **任意**能力都返回内置实现，拿它当基底会凭空把"不支持"变成"内置"
  /// （那正是 P-19 要修的问题）。
  OnlineMusicProviderDefinition withChkszCompatibleCapabilities() {
    final kept = capabilities ?? const {};
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
        ...kept,
        OnlineMusicCapability.search:
            const OnlineMusicBuiltinCapabilityBinding(),
        OnlineMusicCapability.playlist:
            const OnlineMusicBuiltinCapabilityBinding(),
        OnlineMusicCapability.lyric: const OnlineMusicBuiltinCapabilityBinding(),
        OnlineMusicCapability.stream:
            const OnlineMusicBuiltinCapabilityBinding(),
      }),
      contentPlatform: contentPlatform,
      displayName: displayName,
    );
  }

  /// 一键填充会**覆盖**哪几个能力当前的配置（用于界面确认框逐项说明）。
  ///
  /// 已经是内置实现的四项不算"会被覆盖"（它们本来就是这个值）。
  List<OnlineMusicCapability> chkszFillOverwrites() {
    const chkszCapabilities = {
      OnlineMusicCapability.search,
      OnlineMusicCapability.playlist,
      OnlineMusicCapability.lyric,
      OnlineMusicCapability.stream,
    };
    final explicit = capabilities;
    if (explicit == null) return const [];
    return [
      for (final capability in chkszCapabilities)
        if (explicit[capability] is! OnlineMusicBuiltinCapabilityBinding)
          capability,
    ];
  }

  /// 一键填充**不会动**的、且当前已配置的能力（用于界面确认框说明"哪些保持不变"）。
  List<OnlineMusicCapability> chkszFillKeeps() {
    const chkszCapabilities = {
      OnlineMusicCapability.search,
      OnlineMusicCapability.playlist,
      OnlineMusicCapability.lyric,
      OnlineMusicCapability.stream,
    };
    final explicit = capabilities;
    if (explicit == null) return const [];
    return [
      for (final entry in explicit.entries)
        if (!chkszCapabilities.contains(entry.key) &&
            entry.value is! OnlineMusicUnsupportedCapabilityBinding)
          entry.key,
    ];
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'protocol': protocol,
    // 缺失（空串）时不写该键：旧配置里本来就没有它，写一个 `""` 只是噪声。
    if (baseUrl.trim().isNotEmpty) 'baseUrl': baseUrl,
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

/// 在线音乐 Provider、平台感知路由与旧单值能力映射的配置。
final class OnlineMusicSettings {
  const OnlineMusicSettings({
    required this.providers,
    required this.defaultProviderId,
    required this.capabilityProviders,
    required this.routing,
    this.enabledPlatforms = const {},
  });

  static const defaults = OnlineMusicSettings(
    providers: [OnlineMusicProviderDefinition.defaults],
    defaultProviderId: defaultOnlineMusicProviderId,
    capabilityProviders: {},
    routing: {},
  );

  final List<OnlineMusicProviderDefinition> providers;

  /// 旧配置里的"默认 Provider"。**仅作兼容读取**：自 D14 起不再参与任何路由。
  final String defaultProviderId;

  /// 旧配置的**平台无关**单值能力选择（`capabilities{cap → providerId}`）。
  /// 旧界面仍会读写它；解析候选时作为 [routing] 缺失项的回落（D13:A：不迁移、改写）。
  final Map<OnlineMusicCapability, String> capabilityProviders;

  /// **平台感知**的显式候选：`platform → capability → 有序 providerId`（D4:A）。
  ///
  /// 与 [capabilityProviders] **并存**而非互相派生：`routing` 优先，缺失时回落到旧的
  /// 单值映射（且仅当该 Provider 的 `contentPlatform` 等于查询平台时才生效）。
  final Map<MusicPlatform, Map<OnlineMusicCapability, List<String>>> routing;

  /// 被**停用**的平台（D8:A 平台卡的启用开关）：停用的平台不参与搜索，其
  /// `(platform, capability)` 候选一律按"空"处理（调用时报 `unavailable`）。
  ///
  /// 约定：**空集 = 全部启用**。这样默认配置与旧配置的落盘内容都不需要新键
  /// （D13:A：不改写默认配置），`enabledPlatforms` 只在用户真的停用过某些平台时才写盘。
  ///
  /// 代价：无法用同一个表示表达"全部停用"。因此界面**不允许**停用最后一个启用的平台
  /// （见 `withPlatformEnabled`），以免"全部停用"退化成"全部启用"。
  final Set<MusicPlatform> enabledPlatforms;

  /// 该平台当前是否启用（空集 = 全部启用，因此默认返回 true）。
  bool isPlatformEnabled(MusicPlatform platform) =>
      enabledPlatforms.isEmpty || enabledPlatforms.contains(platform);

  /// 把平台列表归一化：覆盖全部平台时回到"空集 = 全部启用"。
  static Set<MusicPlatform> _normalizeEnabledPlatforms(
    Iterable<MusicPlatform> platforms,
  ) {
    final kept = {
      for (final platform in platforms)
        if (MusicPlatform.values.contains(platform)) platform,
    };
    return kept.length == MusicPlatform.values.length ? const {} : kept;
  }

  /// 开/关一个平台；返回新配置（不落盘，由控制器决定）。
  ///
  /// 不允许把**最后一个**启用的平台关掉（`enabledPlatforms` 用空集表示"全部启用"，
  /// 两者会撞在一起）；此时原样返回，界面也会禁用该开关。
  OnlineMusicSettings withPlatformEnabled(
    MusicPlatform platform, {
    required bool enabled,
  }) {
    final current = enabledPlatforms.isEmpty
        ? {for (final value in MusicPlatform.values) value}
        : {...enabledPlatforms};
    if (enabled) {
      current.add(platform);
    } else {
      if (!current.contains(platform)) return this;
      if (current.length <= 1) return this;
      current.remove(platform);
    }
    return _copyWith(enabledPlatforms: _normalizeEnabledPlatforms(current));
  }

  /// 只替换 [enabledPlatforms]；其余字段原样带过。
  OnlineMusicSettings _copyWith({
    required Set<MusicPlatform> enabledPlatforms,
  }) => OnlineMusicSettings(
    providers: providers,
    defaultProviderId: defaultProviderId,
    capabilityProviders: capabilityProviders,
    routing: routing,
    enabledPlatforms: enabledPlatforms,
  );

  Set<String> get providerIds => {for (final p in providers) p.id};

  OnlineMusicProviderDefinition? providerById(String id) {
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  /// 解析 `(platform, capability)` 的**显式**候选 id（D4:A + D13:A）。
  ///
  /// 顺序：`routing[platform][capability]`（过滤未注册 id）→ 旧单值映射
  /// （仅当该 Provider 的 `contentPlatform` 恰为查询平台时生效）→ 空列表。
  /// 空列表表示"没有显式候选"，由调用方按注册顺序补齐支持的 Provider；
  /// 这里**不做**平台无关的默认回落（D14）。
  List<String> explicitCandidateIdsFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    final configured = routing[platform]?[capability];
    if (configured != null && configured.isNotEmpty) {
      return [
        for (final id in configured)
          if (providerIds.contains(id)) id,
      ];
    }
    final legacy = capabilityProviders[capability];
    if (legacy == null) return const [];
    final provider = providerById(legacy);
    if (provider == null || provider.contentPlatform != platform) {
      return const [];
    }
    return [legacy];
  }

  /// 某个能力实际会用到的 Provider id（缺失/未注册时回落默认）。
  String resolvedProviderIdFor(OnlineMusicCapability capability) {
    final requested = capabilityProviders[capability];
    if (requested != null && providerIds.contains(requested)) return requested;
    return providerIds.contains(defaultProviderId)
        ? defaultProviderId
        : providers.first.id;
  }

  /// 该平台下**能够**服务某能力的条目 id（按条目顺序）—— 平台卡的候选项。
  ///
  /// 与路由层的判定一致（[OnlineMusicProviderDefinition.platformsFor]），因此卡片里
  /// 能选的条目就是运行时真正会被选中的那些。
  List<String> capableProviderIdsFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) => [
    for (final provider in providers)
      if (provider.platformsFor(capability).contains(platform)) provider.id,
  ];

  /// 平台卡当前要显示的选中项：显式候选的第一个；没有显式配置时返回 null（= 自动）。
  ///
  /// 返回 null 表示"按注册顺序自动"，界面据此显示「自动」而不是假装用户选过什么。
  String? selectedProviderIdFor(
    MusicPlatform platform,
    OnlineMusicCapability capability,
  ) {
    final explicit = explicitCandidateIdsFor(platform, capability);
    return explicit.isEmpty ? null : explicit.first;
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
      routing: routing,
      enabledPlatforms: enabledPlatforms,
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
      routing: routing,
      enabledPlatforms: enabledPlatforms,
    );
  }

  /// 删除一个条目：默认 Provider、旧单值映射与平台候选里的它一并清理。
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
      routing: _routingWithoutProvider(routing, providerId),
      enabledPlatforms: enabledPlatforms,
    );
  }

  /// 从所有平台候选中剔除某个 providerId；空掉的层级一并移除。
  static Map<MusicPlatform, Map<OnlineMusicCapability, List<String>>>
  _routingWithoutProvider(
    Map<MusicPlatform, Map<OnlineMusicCapability, List<String>>> routing,
    String providerId,
  ) {
    final result = <MusicPlatform, Map<OnlineMusicCapability, List<String>>>{};
    for (final platform in routing.entries) {
      final capabilities = <OnlineMusicCapability, List<String>>{};
      for (final entry in platform.value.entries) {
        final kept = [
          for (final id in entry.value)
            if (id != providerId) id,
        ];
        if (kept.isNotEmpty) capabilities[entry.key] = List.unmodifiable(kept);
      }
      if (capabilities.isNotEmpty) {
        result[platform.key] = Map.unmodifiable(capabilities);
      }
    }
    return Map.unmodifiable(result);
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
      routing: routing,
      enabledPlatforms: enabledPlatforms,
    );
  }

  /// 设置某个 `(platform, capability)` 的**显式有序候选**（D4:A）。
  /// 传入空列表等价于清除该组合的显式配置（回到按注册顺序推导）。
  OnlineMusicSettings withRoutingCandidates(
    MusicPlatform platform,
    OnlineMusicCapability capability,
    Iterable<String> providerIds,
  ) {
    final kept = [
      for (final id in providerIds)
        if (this.providerIds.contains(id)) id,
    ];
    // 显式写出类型：否则 `...?` 展开 + 条件元素会让字面量退化成 Map<dynamic, dynamic>，
    // 运行时 Map.unmodifiable 的视图无法转回声明类型。
    final Map<OnlineMusicCapability, List<String>> platformRouting = {
      ...?routing[platform],
      if (kept.isNotEmpty) capability: List.unmodifiable(kept),
    };
    if (kept.isEmpty) platformRouting.remove(capability);
    final Map<MusicPlatform, Map<OnlineMusicCapability, List<String>>> next = {
      ...routing,
      if (platformRouting.isNotEmpty)
        platform: Map.unmodifiable(platformRouting),
    };
    // 空列表 = 清除该组合的显式配置：把从 `...routing` 带过来的旧项删掉。
    if (platformRouting.isEmpty) next.remove(platform);
    return OnlineMusicSettings(
      providers: providers,
      defaultProviderId: defaultProviderId,
      capabilityProviders: capabilityProviders,
      routing: Map.unmodifiable(next),
      enabledPlatforms: enabledPlatforms,
    );
  }

  OnlineMusicSettings withDefaultProvider(String providerId) {
    if (!providerIds.contains(providerId)) return this;
    return OnlineMusicSettings(
      providers: providers,
      defaultProviderId: providerId,
      capabilityProviders: capabilityProviders,
      routing: routing,
      enabledPlatforms: enabledPlatforms,
    );
  }

  /// 写回 `app_preference.json` 的结构；键名与 [OnlineMusicSettings.fromJson] 一致。
  ///
  /// `routing` 为空时不写该键 —— 默认配置与旧配置的落盘内容保持不变（D13:A：不迁移）。
  /// `enabledPlatforms` 同理：**全部平台都启用**（= 空集）时不写该键。
  Map<String, dynamic> toJson() => {
    'defaultProvider': defaultProviderId,
    'providers': [for (final provider in providers) provider.toJson()],
    'capabilities': {
      for (final entry in capabilityProviders.entries)
        entry.key.name: entry.value,
    },
    if (routing.isNotEmpty)
      'routing': {
        for (final platform in routing.entries)
          platform.key.name: {
            for (final entry in platform.value.entries)
              entry.key.name: entry.value,
          },
      },
    if (enabledPlatforms.isNotEmpty)
      'enabledPlatforms': [
        for (final platform in MusicPlatform.values)
          if (enabledPlatforms.contains(platform)) platform.name,
      ],
  };

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicSettings &&
      other.defaultProviderId == defaultProviderId &&
      _sameProviders(other.providers, providers) &&
      _sameCapabilityProviders(
        other.capabilityProviders,
        capabilityProviders,
      ) &&
      _sameRouting(other.routing, routing) &&
      _samePlatformSet(other.enabledPlatforms, enabledPlatforms);

  @override
  int get hashCode => Object.hash(
    defaultProviderId,
    Object.hashAll(providers),
    Object.hashAllUnordered(
      capabilityProviders.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
    Object.hashAll(
      routing.entries.map(
        (platform) => Object.hash(
          platform.key,
          Object.hashAll(
            platform.value.entries.map(
              (entry) => Object.hash(entry.key, Object.hashAll(entry.value)),
            ),
          ),
        ),
      ),
    ),
    Object.hashAllUnordered(enabledPlatforms),
  );

  @override
  String toString() =>
      'OnlineMusicSettings(${providers.length} providers, '
      'default=$defaultProviderId, capabilities=${capabilityProviders.length}, '
      'routing=${routing.length} platforms, '
      'disabledPlatforms=${MusicPlatform.values.length - enabledPlatforms.length})';

  /// 解析 `onlineMusic` 配置；任何缺失、非法或未注册的内容逐项回落默认。
  ///
  /// D13:A：**不做一次性迁移** —— 旧 `capabilities{cap→providerId}` 与新的 `routing`
  /// 各按各自语义读入，不互相改写、不回写用户文件。
  factory OnlineMusicSettings.fromJson(Object? value) {
    if (value is! Map) return defaults;
    final providers = _parseProviders(value['providers']);
    final ids = {for (final provider in providers) provider.id};
    final requestedDefault = _nonEmptyString(value['defaultProvider']);
    return OnlineMusicSettings(
      providers: providers,
      defaultProviderId:
          (requestedDefault != null && ids.contains(requestedDefault))
          ? requestedDefault
          : providers.first.id,
      capabilityProviders: _parseCapabilityProviders(
        value['capabilities'],
        ids,
      ),
      routing: _parseRouting(value['routing'], ids),
      enabledPlatforms: _parseEnabledPlatforms(value['enabledPlatforms']),
    );
  }

  /// 解析 `enabledPlatforms`：无法识别的名字直接丢弃；解析结果覆盖全部平台时归一化为
  /// 空集（= 全部启用，与 [toJson] 的"全启用不写键"对称）。
  static Set<MusicPlatform> _parseEnabledPlatforms(Object? value) {
    if (value is! List) return const {};
    final platforms = <MusicPlatform>[];
    for (final raw in value) {
      final platform = _matchPlatform(raw);
      if (platform != null) platforms.add(platform);
    }
    return _normalizeEnabledPlatforms(platforms);
  }

  /// 解析 `routing{platform → capability → [providerId]}`。
  ///
  /// 逐项容错：平台名 / 能力名无法识别就跳过该项；未注册的 providerId 直接丢弃
  /// （不是回落到默认 Provider —— D14）。整体为空时返回空表。
  static Map<MusicPlatform, Map<OnlineMusicCapability, List<String>>>
  _parseRouting(Object? value, Set<String> ids) {
    if (value is! Map) return const {};
    final result = <MusicPlatform, Map<OnlineMusicCapability, List<String>>>{};
    for (final platformEntry in value.entries) {
      final platform = _matchPlatform(platformEntry.key);
      if (platform == null) continue;
      final rawCapabilities = platformEntry.value;
      if (rawCapabilities is! Map) continue;
      final capabilities = <OnlineMusicCapability, List<String>>{};
      for (final capabilityEntry in rawCapabilities.entries) {
        final capability = _matchCapability(capabilityEntry.key);
        if (capability == null) continue;
        final rawIds = capabilityEntry.value;
        if (rawIds is! List) continue;
        final kept = <String>[];
        for (final raw in rawIds) {
          final id = _nonEmptyString(raw);
          if (id == null || !ids.contains(id) || kept.contains(id)) continue;
          kept.add(id);
        }
        if (kept.isNotEmpty) capabilities[capability] = List.unmodifiable(kept);
      }
      if (capabilities.isNotEmpty) {
        result[platform] = Map.unmodifiable(capabilities);
      }
    }
    return Map.unmodifiable(result);
  }

  static MusicPlatform? _matchPlatform(Object? value) {
    final name = _nonEmptyString(value);
    if (name == null) return null;
    for (final platform in MusicPlatform.values) {
      if (platform.name == name) return platform;
    }
    return null;
  }

  static OnlineMusicCapability? _matchCapability(Object? value) {
    final name = _nonEmptyString(value);
    if (name == null) return null;
    for (final capability in OnlineMusicCapability.values) {
      if (capability.name == name) return capability;
    }
    return null;
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
      // P-32：绑定与"解析期损坏项"分开带上（后者不落盘、不参与相等性）。
      capabilityConfigIssues:
          parsedCapabilities?.issues ??
          const <OnlineMusicCapabilityConfigIssue>[],
      capabilities: parsedCapabilities?.bindings,
      // 只保存"显式提供"的原值：缺失（含非字符串 / 空串）一律留空 ⇒ 走默认地址。
      // **绝不替换非法值**（P-18），是否可用交给 baseUrlIssue 判定。
      baseUrl: explicitOnlineMusicBaseUrl(value['baseUrl']) ?? '',
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
  ///
  /// P-32：返回值里多带一份 **issues** —— "坏了"必须能被报出来，
  /// 否则它和"从未配置"在界面上完全同形。
  static ({
    Map<OnlineMusicCapability, OnlineMusicCapabilityBinding> bindings,
    List<OnlineMusicCapabilityConfigIssue> issues,
  })
  _parseCapabilities(Object? value) {
    if (value is! Map) {
      // 第二处静默降级（P-32）：整块 `capabilities` 不是对象时，旧实现直接返回空表
      // ⇒ 该条目变成"全部能力都不支持"，同样不报错。
      return (
        bindings:
            const <OnlineMusicCapability, OnlineMusicCapabilityBinding>{},
        issues: const [
          OnlineMusicCapabilityConfigIssue(
            reason: '能力配置不是一个对象 ⇒ 该条目的全部能力都按「不支持」处理，请重新配置',
          ),
        ],
      );
    }
    final result = <OnlineMusicCapability, OnlineMusicCapabilityBinding>{};
    final issues = <OnlineMusicCapabilityConfigIssue>[];
    for (final capability in OnlineMusicCapability.values) {
      final raw = value[capability.name];
      if (raw == null) continue;
      try {
        result[capability] = OnlineMusicCapabilityBinding.fromJson(raw);
      } on FormatException {
        result[capability] = const OnlineMusicUnsupportedCapabilityBinding();
        // **不回显异常文案**：`FormatException` 里可能带着配置里的原始值
        // （例如「能力绑定类型无效：<原值>」），而这些文案会进界面 / 日志。
        // 只说清"哪一项坏了 + 怎么修"，需要看原值时去 JSON 视图。
        issues.add(
          OnlineMusicCapabilityConfigIssue(
            capability: capability,
            reason: '能力配置已损坏（无法解析）⇒ 该能力按「不支持」处理，请重新配置',
          ),
        );
      }
    }
    return (
      bindings: Map.unmodifiable(result),
      issues: List.unmodifiable(issues),
    );
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

bool _samePlatformSet(Set<MusicPlatform> a, Set<MusicPlatform> b) =>
    a.length == b.length && a.containsAll(b);

bool _sameRouting(
  Map<MusicPlatform, Map<OnlineMusicCapability, List<String>>> a,
  Map<MusicPlatform, Map<OnlineMusicCapability, List<String>>> b,
) {
  if (a.length != b.length) return false;
  for (final platform in a.entries) {
    final other = b[platform.key];
    if (other == null || other.length != platform.value.length) return false;
    for (final entry in platform.value.entries) {
      final otherIds = other[entry.key];
      if (otherIds == null || otherIds.length != entry.value.length) {
        return false;
      }
      for (var index = 0; index < entry.value.length; index++) {
        if (otherIds[index] != entry.value[index]) return false;
      }
    }
  }
  return true;
}
