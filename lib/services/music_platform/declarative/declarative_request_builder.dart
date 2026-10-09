/// 把 [OnlineMusicRequestSpec] + 业务输入解析成一次具体的 HTTP 请求。
///
/// 纯函数：不碰网络、不碰凭据存储；凭据值以参数形式传入。
library;

import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// 一次能力调用可用的业务输入（闭集，与 [OnlineMusicInputSource] 一一对应）。
final class DeclarativeInputs {
  const DeclarativeInputs({
    this.keyword,
    this.limit,
    this.offset,
    this.page,
    this.cursor,
    this.trackId,
    this.playlistId,
    this.categoryId,
    this.quality,
  });

  final String? keyword;
  final int? limit;
  final int? offset;
  final int? page;
  final String? cursor;
  final String? trackId;
  final String? playlistId;
  final String? categoryId;
  final String? quality;

  Object? valueOf(OnlineMusicInputSource source) => switch (source) {
    OnlineMusicInputSource.keyword => keyword,
    OnlineMusicInputSource.limit => limit,
    OnlineMusicInputSource.offset => offset,
    OnlineMusicInputSource.page => page,
    OnlineMusicInputSource.cursor => cursor,
    OnlineMusicInputSource.trackId => trackId,
    OnlineMusicInputSource.playlistId => playlistId,
    OnlineMusicInputSource.categoryId => categoryId,
    OnlineMusicInputSource.quality => quality,
  };

  Map<String, Object?> toJson() => {
    'keyword': ?keyword,
    'limit': ?limit,
    'offset': ?offset,
    'page': ?page,
    'cursor': ?cursor,
    'trackId': ?trackId,
    'playlistId': ?playlistId,
    'categoryId': ?categoryId,
    'quality': ?quality,
  };
}

/// 已解析完成、可以直接交给传输层的请求。
final class BuiltDeclarativeRequest {
  const BuiltDeclarativeRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.headers,
    this.body,
    this.isForm = false,
    this.credentialHeaderNames = const {},
    this.credentialQueryNames = const {},
    this.credentialBodyNames = const {},
  });

  /// `GET` / `POST`。
  final String method;

  /// 已替换占位符的相对路径。
  final String path;

  final Map<String, String> query;
  final Map<String, String> headers;

  /// JSON 用 `Map<String, Object?>`，form 用 `Map<String, String>`。
  final Object? body;
  final bool isForm;

  /// 值**来自安全凭据槽位**的请求头名（F0）。
  ///
  /// 诊断/试跑摘要据此遮蔽 —— 判据是**值来源**而不是名字白名单（P-35）：
  /// 凭据值永远不进界面，哪怕它的 header 名不在任何"敏感名单"里。
  final Set<String> credentialHeaderNames;

  /// 值**来自凭据**的查询参数名（认证放在 query 时）。
  ///
  /// 同 [credentialHeaderNames]：参数名由用户自己起（可能叫 `sig`、`k`），
  /// 名字白名单一定漏，只有"值来源"是可靠判据。
  final Set<String> credentialQueryNames;

  /// 值**来自凭据**的**请求体字段**名（认证放在 body 时，P-34）。
  ///
  /// 以前只登记 header/query 两处 ⇒ 请求体只能**整体省略**（"可能含凭据"），
  /// 于是 POST 类能力的核心排查动作（"我配的字段名服务端到底认不认"）在界面上做不了。
  /// 有了这份集合，摘要就能**逐字段**输出：凭据字段 `[redacted]`，其余照实显示。
  final Set<String> credentialBodyNames;

  @override
  String toString() =>
      'BuiltDeclarativeRequest($method $path, query=${query.length}, '
      'headers=${headers.length}, body=${body == null ? 'none' : 'yes'})';
}

/// 装配层把凭据槽位交给声明式 Provider 的**唯一**条件（P-54）。
///
/// 运行期（`online_music_composition`）与试跑（设置控制器）都必须用这一条，
/// 否则会出现"试跑读得到凭据、运行期读不到"那种两份说法。
bool declarativeCredentialAvailable({
  required bool requiresCredential,
  required String? credentialReference,
}) => requiresCredential && credentialReference != null;

/// P-54：条目级「是否需要 Key」与能力级「认证方式」的**矛盾**（配置错误）。
///
/// 为什么会矛盾：条目级 `requiresCredential` 决定装配时**把凭据槽位传不传下去**，
/// 能力级 `binding.request.auth` 决定**要不要注入**。两者叠加就能造出
/// "要注入、但根本读不到凭据"的配置。
///
/// 与"凭据还没配"必须区分（否则会被回退白名单静默掩盖）：
/// - 「需要 Key 但还没配」⇒ `notConfigured`：换个 Provider 是**合理出路**；
/// - 本条（**不需要** Key 却声明认证）⇒ 换谁都没用，是**配置错误** ⇒ `badRequest`（禁止回退）。
///
/// 返回 null 表示没有矛盾。**文案只有这一份**：试跑与运行期必须给出同一个结论。
String? declarativeAuthConfigIssue({
  required OnlineMusicAuthPlacement auth,
  required bool hasCredentialReference,
}) {
  if (auth is OnlineMusicNoAuthPlacement) return null;
  if (hasCredentialReference) return null;
  return '该能力声明了认证，但条目被设为「不需要 Key」（或没有可用的凭据槽位）'
      '⇒ 运行期会因缺少凭据失败：请先把条目的 Key 打开，或把该能力的认证改回「无」';
}

/// 构造请求。
///
/// [credential] 为该条目**认证放置**（auth placement）所用凭据槽位的当前值；
/// 请求声明了认证却没有凭据时抛 [DeclarativeRequestErrorKind.missingCredential]，
/// 由上层映射成"未配置"。
///
/// [headerCredentials] 是**逐请求头**的凭据值，键为 [OnlineMusicHeaderSpec.credentialReference]。
/// 敏感请求头只允许从这里取值：缺值即明确失败，**绝不退回明文或空值**（F0 / §11.2）。
BuiltDeclarativeRequest buildDeclarativeRequest({
  required OnlineMusicRequestSpec spec,
  required DeclarativeInputs inputs,
  String? credential,
  Map<String, String> headerCredentials = const {},
}) {
  final auth = spec.auth;
  final needsCredential = auth is! OnlineMusicNoAuthPlacement;
  if (needsCredential && (credential == null || credential.isEmpty)) {
    throw const DeclarativeRequestException(
      DeclarativeRequestErrorKind.missingCredential,
      '该能力需要凭据，但当前 Provider 没有可用的凭据',
    );
  }

  final path = _substitutePlaceholders(spec.path, inputs);

  final query = <String, String>{};
  for (final binding in spec.query) {
    final value = _resolve(binding, inputs);
    if (value == null) continue;
    query[binding.name] = _stringify(value);
  }

  final headers = <String, String>{};
  final credentialHeaderNames = <String>{};
  final credentialQueryNames = <String>{};
  final credentialBodyNames = <String>{};
  for (final header in spec.headers) {
    final reference = header.credentialReference;
    if (reference != null) {
      // 有引用 ⇒ 值只能来自安全凭据槽位。
      final secret = headerCredentials[reference];
      if (secret == null || secret.isEmpty) {
        throw DeclarativeRequestException(
          DeclarativeRequestErrorKind.sensitiveHeaderCredentialMissing,
          '请求头 ${header.name} 使用安全凭据引用，但该槽位没有可用凭据：'
          '请先在设置页填写该凭据',
        );
      }
      headers[header.name] = secret;
      credentialHeaderNames.add(header.name);
      continue;
    }
    if (header.sensitive) {
      // 已标记敏感但没有引用：
      // - 带明文值 ⇒ 未迁移（保存时本该被拒，此处是防御性再校验）；
      // - 空值 ⇒ "待填凭据"的中间态。
      // 两种都**不发送**，且错误必须与"没配凭据"可区分。
      throw DeclarativeRequestException(
        header.value.trim().isEmpty
            ? DeclarativeRequestErrorKind.sensitiveHeaderCredentialMissing
            : DeclarativeRequestErrorKind.sensitiveHeaderPlaintext,
        header.value.trim().isEmpty
            ? '请求头 ${header.name} 已标记为敏感，但没有可用的安全凭据引用：'
                  '请先在设置页填写该凭据'
            : '请求头 ${header.name} 已标记为敏感，但仍以明文保存：'
                  '请改用安全凭据引用（本次不会发送任何请求）',
      );
    }
    headers[header.name] = header.value;
  }

  Map<String, Object?>? jsonBody;
  Map<String, String>? formBody;
  if (spec.body != null) {
    for (final field in spec.body!.fields) {
      final value = _resolve(field, inputs);
      if (value == null) continue;
      if (spec.body!.isForm) {
        (formBody ??= <String, String>{})[field.name] = _stringify(value);
      } else {
        (jsonBody ??= <String, Object?>{})[field.name] = value;
      }
    }
  }

  switch (auth) {
    case OnlineMusicNoAuthPlacement():
      break;
    case OnlineMusicQueryAuthPlacement(:final parameterName):
      query[parameterName] = credential!;
      credentialQueryNames.add(parameterName);
    case OnlineMusicHeaderAuthPlacement(:final headerName, :final prefix):
      headers[headerName] = '${prefix ?? ''}$credential';
      credentialHeaderNames.add(headerName);
    case OnlineMusicBodyAuthPlacement(:final fieldName):
      if (spec.body != null && spec.body!.isForm) {
        (formBody ??= <String, String>{})[fieldName] = credential!;
      } else {
        (jsonBody ??= <String, Object?>{})[fieldName] = credential;
      }
      // P-34：登记"这个字段的值来自凭据"，摘要据此**逐字段**遮蔽。
      credentialBodyNames.add(fieldName);
  }

  return BuiltDeclarativeRequest(
    method: spec.verb.name.toUpperCase(),
    path: path,
    query: Map.unmodifiable(query),
    headers: Map.unmodifiable(headers),
    body: spec.body == null
        ? null
        : (spec.body!.isForm ? formBody : jsonBody) ?? const {},
    isForm: spec.body?.isForm ?? false,
    credentialHeaderNames: Set.unmodifiable(credentialHeaderNames),
    credentialQueryNames: Set.unmodifiable(credentialQueryNames),
    credentialBodyNames: Set.unmodifiable(credentialBodyNames),
  );
}

Object? _resolve(OnlineMusicParamBinding binding, DeclarativeInputs inputs) {
  final value = inputs.valueOf(binding.source);
  if (value != null) return value;
  if (binding.defaultValue != null) return binding.defaultValue;
  if (binding.required) {
    throw DeclarativeRequestException(
      DeclarativeRequestErrorKind.missingRequiredInput,
      '缺少必填输入 ${binding.source.name}',
    );
  }
  return null;
}

String _stringify(Object? value) => switch (value) {
  String() => value,
  bool() => value ? 'true' : 'false',
  num() => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toString(),
  _ => '$value',
};

String _substitutePlaceholders(String path, DeclarativeInputs inputs) {
  return path.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (match) {
    final name = match.group(1)!;
    OnlineMusicInputSource? source;
    for (final candidate in OnlineMusicInputSource.values) {
      if (candidate.name == name) source = candidate;
    }
    if (source == null) {
      throw DeclarativeRequestException(
        DeclarativeRequestErrorKind.missingRequiredInput,
        '路径占位 {$name} 不是受支持的输入来源',
      );
    }
    final value = inputs.valueOf(source);
    if (value == null) {
      throw DeclarativeRequestException(
        DeclarativeRequestErrorKind.missingRequiredInput,
        '缺少路径占位 {$name} 对应的输入',
      );
    }
    return Uri.encodeComponent(_stringify(value));
  });
}
