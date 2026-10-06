/// 把 JSON 响应按 [OnlineMusicResponseSpec] 映射成 Domain Model。
///
/// 纯函数：输入响应体、输出领域对象；没有网络、没有状态。
/// 映射失败一律抛 [DeclarativeMappingException]，绝不"猜一半"。
library;

import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// 成功判定：状态码 + 一组 AND 谓词。
bool declarativeResponseIsSuccess({
  required OnlineMusicSuccessSpec spec,
  required int statusCode,
  required Object? body,
}) {
  if (!spec.acceptsStatus(statusCode)) return false;
  for (final predicate in spec.allOf) {
    if (!_matches(predicate, body)) return false;
  }
  return true;
}

bool _matches(OnlineMusicSuccessPredicate predicate, Object? body) {
  final actual = predicate.path.read(body);
  switch (predicate.op) {
    case OnlineMusicPredicateOp.exists:
      return actual != null;
    case OnlineMusicPredicateOp.eq:
      return _looseEquals(actual, predicate.value);
    case OnlineMusicPredicateOp.inList:
      final expected = predicate.value;
      if (expected is! List) return false;
      return expected.any((candidate) => _looseEquals(actual, candidate));
  }
}

/// `200` 与 `"200"` 视为相等：第三方 API 这两种写法都很常见。
bool _looseEquals(Object? actual, Object? expected) {
  if (actual == expected) return true;
  if (actual == null || expected == null) return false;
  return actual.toString() == expected.toString();
}

/// 映射搜索响应。
MusicSearchPage mapDeclarativeSearchResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required MusicPlatform platform,
  required int limit,
  required int offset,
}) {
  final listPath = spec.listPath;
  if (listPath == null) {
    throw const DeclarativeMappingException('未配置列表路径');
  }
  final rawList = listPath.read(body);
  if (rawList is! List) {
    throw const DeclarativeMappingException('列表路径没有取到数组');
  }

  final items = <MusicTrack>[];
  for (final element in rawList) {
    items.add(_mapTrack(spec, element, platform));
  }

  return MusicSearchPage(
    platform: platform,
    items: items,
    offset: offset,
    limit: limit,
    total: _readIntAtPath(spec.totalPath, body),
    nextCursor: _readStringAtPath(spec.nextCursorPath, body),
  );
}

String? _readStringAtPath(JsonPath? path, Object? body) {
  if (path == null) return null;
  final value = path.read(body);
  return value is String && value.isNotEmpty ? value : null;
}

MusicTrack _mapTrack(
  OnlineMusicResponseSpec spec,
  Object? element,
  MusicPlatform platform,
) {
  final trackId = _readRequired(spec, OnlineMusicDomainField.trackId, element);
  final title = _readRequired(spec, OnlineMusicDomainField.title, element);
  return MusicTrack(
    ref: PlatformTrackRef(platform: platform, trackId: '$trackId'),
    title: '$title',
    artists:
        _readStringList(spec, OnlineMusicDomainField.artists, element) ??
        const [],
    album: _readString(spec, OnlineMusicDomainField.album, element) ?? '',
    coverUri: _readUri(spec, OnlineMusicDomainField.coverUri, element),
    duration:
        _readDuration(spec, OnlineMusicDomainField.duration, element) ??
        Duration.zero,
  );
}

/// 映射播放解析响应。
ResolvedStream mapDeclarativeResolveResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required PlatformTrackRef expectedRef,
  required String requestedQuality,
  required DateTime resolvedAt,
}) {
  final root = spec.fieldsRootPath?.read(body) ?? body;
  final uri = _readUri(spec, OnlineMusicDomainField.streamUrl, root);
  if (uri == null) {
    throw const DeclarativeMappingException('没有取到可用的播放地址');
  }

  // 如果配置了 trackId 映射，就校验返回的就是请求的那首（与既有 ChkSz 行为一致）。
  final returnedId = _readOptional(spec, OnlineMusicDomainField.trackId, root);
  if (returnedId != null && '$returnedId' != expectedRef.trackId) {
    throw const DeclarativeMappingException('返回的曲目与请求的不一致');
  }

  final expiresAt = _readEpochSeconds(
    spec,
    OnlineMusicDomainField.streamExpiresAt,
    root,
  );

  return ResolvedStream(
    ref: expectedRef,
    uri: uri,
    requestedQuality: requestedQuality,
    coverUri: _readUri(spec, OnlineMusicDomainField.coverUri, root),
    actualQuality: _readString(spec, OnlineMusicDomainField.streamQuality, root),
    bitrate: _readIntField(spec, OnlineMusicDomainField.streamBitrate, root),
    resolvedAt: resolvedAt,
    expiresAt: expiresAt,
  );
}

// ---------------------------------------------------------------------------
// 字段读取
// ---------------------------------------------------------------------------

Object? _readOptional(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final fieldSpec = spec.fields[field];
  if (fieldSpec == null) return null;
  for (final candidate in fieldSpec.candidates) {
    final raw = candidate.read(node);
    if (raw == null) continue;
    final transformed = _applyTransform(fieldSpec, raw);
    if (transformed != null) return transformed;
  }
  return fieldSpec.defaultValue;
}

Object? _readRequired(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final value = _readOptional(spec, field, node);
  if (value == null) {
    throw DeclarativeMappingException('缺少必填字段 ${field.name}');
  }
  return value;
}

String? _readString(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final value = _readOptional(spec, field, node);
  return value is String && value.isNotEmpty ? value : null;
}

int? _readIntField(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final value = _readOptional(spec, field, node);
  return value is int ? value : null;
}

List<String>? _readStringList(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final value = _readOptional(spec, field, node);
  if (value is! List) return null;
  return [
    for (final entry in value)
      if (entry is String && entry.trim().isNotEmpty) entry,
  ];
}

Uri? _readUri(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final value = _readOptional(spec, field, node);
  return value is Uri ? value : null;
}

Duration? _readDuration(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final value = _readOptional(spec, field, node);
  return value is Duration ? value : null;
}

DateTime? _readEpochSeconds(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final value = _readIntField(spec, field, node);
  if (value == null || value <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
}

int? _readIntAtPath(JsonPath? path, Object? body) {
  if (path == null) return null;
  final value = path.read(body);
  if (value is int) return value;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

// ---------------------------------------------------------------------------
// 类型转换（闭集）
// ---------------------------------------------------------------------------

/// 转换失败或值不可用时返回 null（是否算错误由字段的 `required` 决定）。
Object? _applyTransform(OnlineMusicFieldSpec spec, Object? raw) {
  switch (spec.transform) {
    case OnlineMusicFieldTransform.asString:
      if (raw is String) return raw;
      if (raw is num || raw is bool) return '$raw';
      return null;
    case OnlineMusicFieldTransform.asInt:
      if (raw is int) return raw;
      if (raw is num && raw == raw.truncateToDouble()) return raw.toInt();
      if (raw is String) return int.tryParse(raw.trim());
      return null;
    case OnlineMusicFieldTransform.asBool:
      if (raw is bool) return raw;
      if (raw is String) {
        final normalized = raw.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1') return true;
        if (normalized == 'false' || normalized == '0') return false;
      }
      return null;
    case OnlineMusicFieldTransform.asUri:
      return _httpUri(raw);
    case OnlineMusicFieldTransform.asHttpsUri:
      final uri = _httpUri(raw);
      if (uri == null) return null;
      return uri.scheme == 'https' ? uri : uri.replace(scheme: 'https');
    case OnlineMusicFieldTransform.asDurationMs:
      final milliseconds = _asIntValue(raw);
      return milliseconds == null ? null : Duration(milliseconds: milliseconds);
    case OnlineMusicFieldTransform.asDurationSeconds:
      final seconds = _asIntValue(raw);
      return seconds == null ? null : Duration(seconds: seconds);
    case OnlineMusicFieldTransform.asSingleStringList:
      final value = _applyTransform(
        OnlineMusicFieldSpec(
          candidates: spec.candidates,
          transform: OnlineMusicFieldTransform.asString,
        ),
        raw,
      );
      return value is String && value.trim().isNotEmpty ? [value] : null;
    case OnlineMusicFieldTransform.asStringList:
      if (raw is! List) return null;
      final result = [
        for (final entry in raw)
          if (entry is String && entry.trim().isNotEmpty) entry,
      ];
      return result.isEmpty ? null : result;
  }
}

int? _asIntValue(Object? raw) {
  if (raw is int) return raw;
  if (raw is num && raw == raw.truncateToDouble()) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim());
  return null;
}

Uri? _httpUri(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri;
}
