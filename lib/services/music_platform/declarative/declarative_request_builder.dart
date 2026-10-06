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
    this.quality,
  });

  final String? keyword;
  final int? limit;
  final int? offset;
  final int? page;
  final String? cursor;
  final String? trackId;
  final String? playlistId;
  final String? quality;

  Object? valueOf(OnlineMusicInputSource source) => switch (source) {
    OnlineMusicInputSource.keyword => keyword,
    OnlineMusicInputSource.limit => limit,
    OnlineMusicInputSource.offset => offset,
    OnlineMusicInputSource.page => page,
    OnlineMusicInputSource.cursor => cursor,
    OnlineMusicInputSource.trackId => trackId,
    OnlineMusicInputSource.playlistId => playlistId,
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

  @override
  String toString() =>
      'BuiltDeclarativeRequest($method $path, query=${query.length}, '
      'headers=${headers.length}, body=${body == null ? 'none' : 'yes'})';
}

/// 构造请求。
///
/// [credential] 为该条目凭据槽位的当前值；请求声明了认证却没有凭据时抛
/// [DeclarativeRequestExceptionKind.missingCredential]，由上层映射成"未配置"。
BuiltDeclarativeRequest buildDeclarativeRequest({
  required OnlineMusicRequestSpec spec,
  required DeclarativeInputs inputs,
  String? credential,
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

  final headers = <String, String>{
    for (final header in spec.headers) header.name: header.value,
  };

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
    case OnlineMusicHeaderAuthPlacement(:final headerName, :final prefix):
      headers[headerName] = '${prefix ?? ''}$credential';
    case OnlineMusicBodyAuthPlacement(:final fieldName):
      if (spec.body != null && spec.body!.isForm) {
        (formBody ??= <String, String>{})[fieldName] = credential!;
      } else {
        (jsonBody ??= <String, Object?>{})[fieldName] = credential;
      }
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
