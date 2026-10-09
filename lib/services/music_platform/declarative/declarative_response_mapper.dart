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
    actualQuality: _readString(
      spec,
      OnlineMusicDomainField.streamQuality,
      root,
    ),
    bitrate: _readIntField(spec, OnlineMusicDomainField.streamBitrate, root),
    resolvedAt: resolvedAt,
    expiresAt: expiresAt,
  );
}

// ---------------------------------------------------------------------------
// 字段读取
// ---------------------------------------------------------------------------

/// 映射歌单响应（S7a）。
///
/// 约定与搜索/播放解析一致：
/// - `fieldsRootPath` 指向**歌单元数据**所在对象（未配置时用整个响应体）；
/// - `listPath` 指向**歌单内曲目数组**（未配置则不带曲目，保持结构可用）；
/// - 歌单 id 读不到时**回落到请求里的 id**（调用方本来就知道它，不算映射失败）。
RemotePlaylist mapDeclarativePlaylistResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required MusicPlatform platform,
  required String requestedPlaylistId,
}) {
  final root = spec.fieldsRootPath?.read(body) ?? body;
  final id =
      _readOptional(
        spec,
        OnlineMusicDomainField.playlistId,
        root,
      )?.toString() ??
      requestedPlaylistId;

  final tracks = <MusicTrack>[];
  final listPath = spec.listPath;
  if (listPath != null) {
    final rawList = listPath.read(body);
    if (rawList is! List) {
      throw const DeclarativeMappingException('列表路径没有取到数组');
    }
    for (final element in rawList) {
      tracks.add(_mapTrack(spec, element, platform));
    }
  }

  return RemotePlaylist(
    platform: platform,
    id: id,
    name: _readString(spec, OnlineMusicDomainField.playlistName, root) ?? id,
    coverUri: _readUri(spec, OnlineMusicDomainField.playlistCoverUri, root),
    creator: _readString(spec, OnlineMusicDomainField.playlistCreator, root),
    trackCount: _readIntField(
      spec,
      OnlineMusicDomainField.playlistTrackCount,
      root,
    ),
    tracks: tracks,
  );
}

/// 映射**歌单集合**响应（W3 / Spec §19.2）。
///
/// 与 [mapDeclarativePlaylistResponse] 的区别：这里每个元素都是**一个歌单的元数据**，
/// 没有曲目字段（[OnlineMusicDomainFields] 的 playlist 字段集里不含 track*）。
/// - `listPath` 指向歌单数组（必填，配置校验会拦住缺失）；
/// - 元素内部的歌单字段由 `fields` 映射给出；
/// - 没有字段根路径：一个数组元素就是一个歌单摘要。
///
/// **歌单列表（playlistCollection）与榜单索引（chartList）共用这一个映射**：两者都是
/// "一组集合的元数据"，真实响应形状同构（网易云 `/top/playlist` 与 `/toplist` 都是
/// `{code, <array>}`，元素含 id/name/cover/数量/更新节奏）。共用一个映射是有意的 ——
/// 复制一份只会在两处各自走偏。
///
/// 单个元素映射失败（缺必填字段）与搜索一致：抛 [DeclarativeMappingException]，
/// 绝不"猜一半"——半个歌单列表比明确报错更难排查。
List<RemotePlaylistSummary> mapDeclarativePlaylistCollectionResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required MusicPlatform platform,
}) {
  final listPath = spec.listPath;
  if (listPath == null) {
    throw const DeclarativeMappingException('未配置列表路径');
  }
  final rawList = listPath.read(body);
  if (rawList is! List) {
    throw const DeclarativeMappingException('列表路径没有取到数组');
  }

  return [
    for (final element in rawList)
      RemotePlaylistSummary(
        platform: platform,
        id: '${_readRequired(spec, OnlineMusicDomainField.playlistId, element)}',
        name:
            '${_readRequired(spec, OnlineMusicDomainField.playlistName, element)}',
        coverUri: _readUri(
          spec,
          OnlineMusicDomainField.playlistCoverUri,
          element,
        ),
        creator: _readString(
          spec,
          OnlineMusicDomainField.playlistCreator,
          element,
        ),
        trackCount: _readIntField(
          spec,
          OnlineMusicDomainField.playlistTrackCount,
          element,
        ),
        updateFrequency: _readString(
          spec,
          OnlineMusicDomainField.playlistUpdateFrequency,
          element,
        ),
      ),
  ];
}

/// 映射**歌单分类**响应。
///
/// 与歌单列表同构（一个数组，每个元素是一个分类），因此只是字段集不同。
/// 单个元素缺必填字段时同样抛 [DeclarativeMappingException]：半个分类索引会让
/// chip 墙上出现点不动的空 chip，比明确报错更难排查。
List<RemotePlaylistCategory> mapDeclarativePlaylistCategoriesResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required MusicPlatform platform,
}) {
  final listPath = spec.listPath;
  if (listPath == null) {
    throw const DeclarativeMappingException('未配置列表路径');
  }
  final rawList = listPath.read(body);
  if (rawList is! List) {
    throw const DeclarativeMappingException('列表路径没有取到数组');
  }

  return [
    for (final element in rawList)
      RemotePlaylistCategory(
        platform: platform,
        id: '${_readRequired(spec, OnlineMusicDomainField.categoryId, element)}',
        name:
            '${_readRequired(spec, OnlineMusicDomainField.categoryName, element)}',
        count: _readIntField(
          spec,
          OnlineMusicDomainField.categoryCount,
          element,
        ),
      ),
  ];
}

/// 映射歌词响应（S7a）。
///
/// 与歌单/搜索不同，这里**不因为"取不到歌词"就报映射失败**：间奏曲、纯音乐本来
/// 就可能没有歌词，那是正常的空结果（上层会显示"暂无歌词"）。
/// 只有当用户**一个歌词字段都没配置**时才判定为配置错误 —— 那种情况下永远取不到
/// 歌词，属于"接口定义无法匹配响应"，必须让用户知道。
MusicLyrics mapDeclarativeLyricsResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required PlatformTrackRef ref,
}) {
  const lyricFields = [
    OnlineMusicDomainField.lyricOriginal,
    OnlineMusicDomainField.lyricTranslation,
    OnlineMusicDomainField.lyricRomanization,
  ];
  if (!lyricFields.any(spec.fields.containsKey)) {
    throw const DeclarativeMappingException('未配置任何歌词字段');
  }

  final root = spec.fieldsRootPath?.read(body) ?? body;
  return MusicLyrics(
    original: _readString(spec, OnlineMusicDomainField.lyricOriginal, root),
    translation: _readString(
      spec,
      OnlineMusicDomainField.lyricTranslation,
      root,
    ),
    romanization: _readString(
      spec,
      OnlineMusicDomainField.lyricRomanization,
      root,
    ),
    ref: ref,
  );
}

Object? _readOptional(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) => _readWithDiagnosis(spec, field, node).value;

/// 一次取值的完整结果：值 + **"路径命中但转换失败"的诊断**（P-31）。
///
/// 为什么要带上诊断：[`_readOptional`] 的候选循环里，`raw != null` 但
/// `_applyTransform` 返回 null 时，旧实现把它当成"这条路没有值"继续下一个候选，
/// 循环落空后调用方只能看到 null ⇒ 一律报「缺少必填字段 X」。
/// 用户于是去补字段/改路径，而真正的问题是**转换选错了**（例如 id 配成整数、
/// 响应里却是字符串）—— 排查方向被带偏。
final class _FieldRead {
  const _FieldRead(this.value, {this.mismatch});

  final Object? value;
  final _TransformMismatch? mismatch;
}

/// 首次"命中但转换失败"的现场：路径（配置里的，不是数据）+ 转换 + 该位置的值类型。
///
/// **只带类型名、不带值**：错误文案会进界面，不得把响应内容（可能含敏感信息）带出去。
final class _TransformMismatch {
  const _TransformMismatch({
    required this.path,
    required this.transform,
    required this.rawType,
  });

  final JsonPath path;
  final OnlineMusicFieldTransform transform;
  final String rawType;
}

_FieldRead _readWithDiagnosis(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final fieldSpec = spec.fields[field];
  if (fieldSpec == null) return const _FieldRead(null);
  _TransformMismatch? mismatch;
  for (final candidate in fieldSpec.candidates) {
    final raw = candidate.read(node);
    if (raw == null) continue;
    final transformed = _applyTransform(fieldSpec, raw);
    if (transformed != null) return _FieldRead(transformed);
    mismatch ??= _TransformMismatch(
      path: candidate,
      transform: fieldSpec.transform,
      rawType: _diagnosticTypeName(raw),
    );
  }
  return _FieldRead(fieldSpec.defaultValue, mismatch: mismatch);
}

/// 给错误文案用的**粗粒度**类型名（不暴露 Dart 内部类型名，也不暴露值）。
String _diagnosticTypeName(Object raw) => switch (raw) {
  String() => '字符串',
  int() || double() => '数字',
  bool() => '布尔值',
  List() => '数组',
  Map() => '对象',
  _ => '其它类型',
};

Object? _readRequired(
  OnlineMusicResponseSpec spec,
  OnlineMusicDomainField field,
  Object? node,
) {
  final result = _readWithDiagnosis(spec, field, node);
  final value = result.value;
  if (value != null) return value;
  final mismatch = result.mismatch;
  if (mismatch != null) {
    // P-31：**取到了值、但转换解析不出来** —— 与"字段真的缺失"是两件事，
    // 必须给出不同结论，否则用户会去补一个本来就存在的字段。
    throw DeclarativeMappingException(
      '字段 ${field.name} 的路径「${mismatch.path.source}」取到了值（${mismatch.rawType}），'
      '但按当前类型转换 ${mismatch.transform.name} 解析不出来：请检查该字段的类型转换',
    );
  }
  throw DeclarativeMappingException('缺少必填字段 ${field.name}');
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
