/// 声明式响应模型。
///
/// 设计原则：**只做映射，不做逻辑**。成功判定是「状态码 + 一组 AND 谓词」，
/// 字段映射是「候选路径 + 闭集类型转换」，没有任何表达式、条件或跨字段计算。
library;

import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';

/// 领域模型里可被映射的字段（闭集：数量有限，且与能力一一对应）。
enum OnlineMusicDomainField {
  // search / playlist 的曲目
  trackId,
  title,
  artists,
  album,
  coverUri,
  duration,

  // playlist 自身
  playlistId,
  playlistName,
  playlistCoverUri,
  playlistCreator,
  playlistTrackCount,

  // lyric
  lyricOriginal,
  lyricTranslation,
  lyricRomanization,

  // stream
  streamUrl,
  streamQuality,
  streamBitrate,
  streamExpiresAt,
}

/// 字段级类型转换（闭集）。
enum OnlineMusicFieldTransform {
  asString,
  asInt,
  asUri,

  /// 同 [asUri]，但把 http 提升为 https（与既有 ChkSz 搜索封面行为一致）。
  asHttpsUri,
  asDurationMs,
  asDurationSeconds,

  /// 期望一个字符串，映射成单元素列表。
  asSingleStringList,

  /// 期望一个字符串数组。
  asStringList,
  asBool,
}

enum OnlineMusicPredicateOp { eq, inList, exists }

final class OnlineMusicSuccessPredicate {
  const OnlineMusicSuccessPredicate({
    required this.path,
    required this.op,
    this.value,
  });

  final JsonPath path;
  final OnlineMusicPredicateOp op;
  final Object? value;

  Map<String, dynamic> toJson() => {
    'path': path.source,
    'op': op.name,
    if (value != null) 'value': value,
  };

  static OnlineMusicSuccessPredicate fromJson(Object? value) {
    final map = _requireMap(value, '成功判定谓词');
    return OnlineMusicSuccessPredicate(
      path: _requirePath(map['path'], '成功判定路径'),
      op: _requireEnum(
        map['op'],
        OnlineMusicPredicateOp.values,
        '成功判定运算符',
      ),
      value: map['value'],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicSuccessPredicate &&
      other.path == path &&
      other.op == op &&
      other.value == value;

  @override
  int get hashCode => Object.hash(path, op, value);
}

final class OnlineMusicSuccessSpec {
  const OnlineMusicSuccessSpec({
    this.okStatusCodes = const [],
    this.allOf = const [],
  });

  /// 空表示接受 2xx。
  final List<int> okStatusCodes;
  final List<OnlineMusicSuccessPredicate> allOf;

  Map<String, dynamic> toJson() => {
    'statusCodes': okStatusCodes,
    'allOf': [for (final predicate in allOf) predicate.toJson()],
  };

  static OnlineMusicSuccessSpec fromJson(Object? value) {
    final map = _requireMap(value, '成功判定');
    return OnlineMusicSuccessSpec(
      okStatusCodes: _optionalList(map['statusCodes'])
          .map((entry) => _requireInt(entry, '成功状态码'))
          .toList(growable: false),
      allOf: _optionalList(map['allOf'])
          .map(OnlineMusicSuccessPredicate.fromJson)
          .toList(growable: false),
    );
  }

  bool acceptsStatus(int statusCode) {
    if (okStatusCodes.isEmpty) return statusCode >= 200 && statusCode < 300;
    return okStatusCodes.contains(statusCode);
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicSuccessSpec &&
      _listEquals(other.okStatusCodes, okStatusCodes) &&
      _listEquals(other.allOf, allOf);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(okStatusCodes), Object.hashAll(allOf));
}

final class OnlineMusicFieldSpec {
  const OnlineMusicFieldSpec({
    required this.candidates,
    required this.transform,
    this.required = false,
    this.defaultValue,
  });

  /// 按序取第一个存在的路径（firstOf）。
  final List<JsonPath> candidates;
  final OnlineMusicFieldTransform transform;
  final bool required;
  final Object? defaultValue;

  Map<String, dynamic> toJson() => {
    'paths': [for (final path in candidates) path.source],
    'transform': transform.name,
    'required': required,
    if (defaultValue != null) 'default': defaultValue,
  };

  static OnlineMusicFieldSpec fromJson(Object? value) {
    final map = _requireMap(value, '字段映射');
    return OnlineMusicFieldSpec(
      candidates: _optionalList(map['paths'])
          .map((entry) => _requirePath(entry, '字段路径'))
          .toList(growable: false),
      transform: _requireEnum(
        map['transform'],
        OnlineMusicFieldTransform.values,
        '字段转换',
      ),
      required: map['required'] == true,
      defaultValue: map['default'],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicFieldSpec &&
      _listEquals(other.candidates, candidates) &&
      other.transform == transform &&
      other.required == required &&
      other.defaultValue == defaultValue;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(candidates), transform, required, defaultValue);
}

enum OnlineMusicPaginationKind { none, offsetLimit, pageSize, cursor }

final class OnlineMusicPaginationSpec {
  const OnlineMusicPaginationSpec({
    this.kind = OnlineMusicPaginationKind.none,
    this.defaultLimit = 30,
  });

  final OnlineMusicPaginationKind kind;
  final int defaultLimit;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'defaultLimit': defaultLimit,
  };

  static OnlineMusicPaginationSpec fromJson(Object? value) {
    if (value == null) return const OnlineMusicPaginationSpec();
    final map = _requireMap(value, '分页配置');
    return OnlineMusicPaginationSpec(
      kind: _requireEnum(
        map['kind'],
        OnlineMusicPaginationKind.values,
        '分页类型',
      ),
      defaultLimit: map['defaultLimit'] == null
          ? 30
          : _requireInt(map['defaultLimit'], '默认每页数量'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicPaginationSpec &&
      other.kind == kind &&
      other.defaultLimit == defaultLimit;

  @override
  int get hashCode => Object.hash(kind, defaultLimit);
}

final class OnlineMusicResponseSpec {
  const OnlineMusicResponseSpec({
    this.success = const OnlineMusicSuccessSpec(),
    this.listPath,
    this.fieldsRootPath,
    this.totalPath,
    this.nextCursorPath,
    this.fields = const {},
    this.pagination = const OnlineMusicPaginationSpec(),
  });

  final OnlineMusicSuccessSpec success;

  /// 数组所在位置（search）。存在时 [fields] 里的路径**相对数组的每个元素**。
  final JsonPath? listPath;

  /// [listPath] 为空时，[fields] 相对这个对象解析（stream）。
  final JsonPath? fieldsRootPath;

  /// 以下三个都相对**响应根**解析。
  final JsonPath? totalPath;
  final JsonPath? nextCursorPath;

  final Map<OnlineMusicDomainField, OnlineMusicFieldSpec> fields;
  final OnlineMusicPaginationSpec pagination;

  Map<String, dynamic> toJson() => {
    'success': success.toJson(),
    if (listPath != null) 'listPath': listPath!.source,
    if (fieldsRootPath != null) 'fieldsRootPath': fieldsRootPath!.source,
    if (totalPath != null) 'totalPath': totalPath!.source,
    if (nextCursorPath != null) 'nextCursorPath': nextCursorPath!.source,
    'fields': {
      for (final entry in fields.entries) entry.key.name: entry.value.toJson(),
    },
    'pagination': pagination.toJson(),
  };

  static OnlineMusicResponseSpec fromJson(Object? value) {
    final map = _requireMap(value, '响应配置');
    final rawFields = map['fields'];
    return OnlineMusicResponseSpec(
      success: map['success'] == null
          ? const OnlineMusicSuccessSpec()
          : OnlineMusicSuccessSpec.fromJson(map['success']),
      listPath: map['listPath'] == null
          ? null
          : _requirePath(map['listPath'], '列表路径'),
      fieldsRootPath: map['fieldsRootPath'] == null
          ? null
          : _requirePath(map['fieldsRootPath'], '字段根路径'),
      totalPath: map['totalPath'] == null
          ? null
          : _requirePath(map['totalPath'], '总数路径'),
      nextCursorPath: map['nextCursorPath'] == null
          ? null
          : _requirePath(map['nextCursorPath'], '游标路径'),
      fields: rawFields is Map
          ? Map.unmodifiable({
              for (final entry in rawFields.entries)
                _requireEnum(
                  entry.key,
                  OnlineMusicDomainField.values,
                  '领域字段',
                ): OnlineMusicFieldSpec.fromJson(entry.value),
            })
          : const {},
      pagination: OnlineMusicPaginationSpec.fromJson(map['pagination']),
    );
  }

  /// 按能力校验；空列表表示可用。
  List<String> validationIssues(OnlineMusicCapability capability) {
    final issues = <String>[];
    final allowed = domainFieldsFor(capability);
    for (final entry in fields.entries) {
      if (!allowed.contains(entry.key)) {
        issues.add('${entry.key.name} 不属于 ${capability.name} 能力');
      }
      if (entry.value.candidates.isEmpty) {
        issues.add('${entry.key.name} 至少要有一个字段路径');
      }
      final expected = expectedFieldKinds[entry.key];
      if (expected != null && !expected.contains(entry.value.transform)) {
        issues.add(
          '${entry.key.name} 的类型转换 ${entry.value.transform.name} 不合适',
        );
      }
    }
    for (final required in requiredFieldsFor(capability)) {
      if (!fields.containsKey(required)) {
        issues.add('缺少必填字段映射 ${required.name}');
      }
    }
    switch (capability) {
      case OnlineMusicCapability.search:
        if (listPath == null) issues.add('搜索能力必须配置列表路径');
      case OnlineMusicCapability.stream:
        if (listPath == null && fieldsRootPath == null) {
          issues.add('播放解析能力必须配置字段根路径');
        }
      case OnlineMusicCapability.playlist || OnlineMusicCapability.lyric:
        issues.add('${capability.name} 能力的声明式配置属于第二阶段，尚未开放');
    }
    if (pagination.kind == OnlineMusicPaginationKind.cursor &&
        nextCursorPath == null) {
      issues.add('游标分页必须配置游标路径');
    }
    if (pagination.defaultLimit <= 0) issues.add('默认每页数量必须为正数');
    return issues;
  }

  @override
  bool operator ==(Object other) =>
      other is OnlineMusicResponseSpec &&
      other.success == success &&
      other.listPath == listPath &&
      other.fieldsRootPath == fieldsRootPath &&
      other.totalPath == totalPath &&
      other.nextCursorPath == nextCursorPath &&
      _sameFields(other.fields, fields) &&
      other.pagination == pagination;

  @override
  int get hashCode => Object.hash(
    success,
    listPath,
    fieldsRootPath,
    totalPath,
    nextCursorPath,
    Object.hashAllUnordered(
      fields.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    pagination,
  );

  @override
  String toString() =>
      'OnlineMusicResponseSpec(list=$listPath, fields=${fields.length})';
}

/// 每个能力允许出现哪些领域字段。
Set<OnlineMusicDomainField> domainFieldsFor(OnlineMusicCapability capability) {
  switch (capability) {
    case OnlineMusicCapability.search:
      return const {
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
        OnlineMusicDomainField.artists,
        OnlineMusicDomainField.album,
        OnlineMusicDomainField.coverUri,
        OnlineMusicDomainField.duration,
      };
    case OnlineMusicCapability.stream:
      return const {
        OnlineMusicDomainField.streamUrl,
        OnlineMusicDomainField.streamQuality,
        OnlineMusicDomainField.streamBitrate,
        OnlineMusicDomainField.streamExpiresAt,
        OnlineMusicDomainField.coverUri,
      };
    case OnlineMusicCapability.playlist:
      return const {
        OnlineMusicDomainField.playlistId,
        OnlineMusicDomainField.playlistName,
        OnlineMusicDomainField.playlistCoverUri,
        OnlineMusicDomainField.playlistCreator,
        OnlineMusicDomainField.playlistTrackCount,
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
        OnlineMusicDomainField.artists,
        OnlineMusicDomainField.album,
        OnlineMusicDomainField.coverUri,
        OnlineMusicDomainField.duration,
      };
    case OnlineMusicCapability.lyric:
      return const {
        OnlineMusicDomainField.lyricOriginal,
        OnlineMusicDomainField.lyricTranslation,
        OnlineMusicDomainField.lyricRomanization,
      };
  }
}

/// 每个能力必须映射哪些字段。
Set<OnlineMusicDomainField> requiredFieldsFor(OnlineMusicCapability capability) {
  switch (capability) {
    case OnlineMusicCapability.search:
      return const {OnlineMusicDomainField.trackId, OnlineMusicDomainField.title};
    case OnlineMusicCapability.stream:
      return const {OnlineMusicDomainField.streamUrl};
    case OnlineMusicCapability.playlist:
      return const {
        OnlineMusicDomainField.playlistId,
        OnlineMusicDomainField.playlistName,
      };
    case OnlineMusicCapability.lyric:
      return const {};
  }
}

/// 领域字段可接受的类型转换；未列出的字段表示不限制。
const Map<OnlineMusicDomainField, Set<OnlineMusicFieldTransform>>
expectedFieldKinds = {
  OnlineMusicDomainField.trackId: {
    OnlineMusicFieldTransform.asString,
    OnlineMusicFieldTransform.asInt,
  },
  OnlineMusicDomainField.title: {OnlineMusicFieldTransform.asString},
  OnlineMusicDomainField.artists: {
    OnlineMusicFieldTransform.asSingleStringList,
    OnlineMusicFieldTransform.asStringList,
  },
  OnlineMusicDomainField.album: {OnlineMusicFieldTransform.asString},
  OnlineMusicDomainField.coverUri: {
    OnlineMusicFieldTransform.asUri,
    OnlineMusicFieldTransform.asHttpsUri,
  },
  OnlineMusicDomainField.duration: {
    OnlineMusicFieldTransform.asDurationMs,
    OnlineMusicFieldTransform.asDurationSeconds,
  },
  OnlineMusicDomainField.playlistTrackCount: {
    OnlineMusicFieldTransform.asInt,
    OnlineMusicFieldTransform.asString,
  },
  OnlineMusicDomainField.streamUrl: {OnlineMusicFieldTransform.asUri},
  OnlineMusicDomainField.streamQuality: {OnlineMusicFieldTransform.asString},
  OnlineMusicDomainField.streamBitrate: {OnlineMusicFieldTransform.asInt},
  OnlineMusicDomainField.streamExpiresAt: {
    OnlineMusicFieldTransform.asInt,
    OnlineMusicFieldTransform.asString,
  },
};

Map<Object?, Object?> _requireMap(Object? value, String label) {
  if (value is Map) return value;
  throw FormatException('$label 必须是对象');
}

List<Object?> _optionalList(Object? value) {
  if (value == null) return const [];
  if (value is List) return value;
  throw const FormatException('列表字段必须是数组');
}

JsonPath _requirePath(Object? value, String label) {
  if (value is! String) throw FormatException('$label 必须是字符串');
  final path = JsonPath.tryParse(value);
  if (path == null) throw FormatException('$label 写法无效："$value"');
  return path;
}

int _requireInt(Object? value, String label) {
  if (value is int) return value;
  if (value is num && value == value.truncateToDouble()) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  throw FormatException('$label 必须是整数');
}

T _requireEnum<T extends Enum>(Object? value, List<T> values, String label) {
  if (value is String) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
  }
  throw FormatException('$label 取值无效：$value');
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _sameFields(
  Map<OnlineMusicDomainField, OnlineMusicFieldSpec> a,
  Map<OnlineMusicDomainField, OnlineMusicFieldSpec> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
