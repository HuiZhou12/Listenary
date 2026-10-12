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

  /// **艺人 id**（与 [artists] 同序；用于"点艺人名打开艺人页"，2026-10-12 新增）。
  artistIds,

  /// **专辑 id**（用于"点专辑名打开专辑页"，2026-10-12 新增）。
  albumIds,
  album,
  coverUri,
  duration,

  // playlist 自身
  playlistId,
  playlistName,
  playlistCoverUri,
  playlistCreator,
  playlistTrackCount,

  /// 集合的**更新节奏**（平台自己的文案）。榜单这类名次集合靠它说明多久变一次。
  playlistUpdateFrequency,

  // artist（艺人详情，2026-10-12）：标量部分；热门曲目**复用**上面的曲目字段。
  /// 艺人显示名。
  artistName,
  /// 艺人头像（http(s)）。
  artistAvatarUri,
  /// 艺人简介（平台自己的文案；可为空）。
  artistDescription,

  // album（专辑详情，2026-10-12）：标量部分；曲目**复用**上面的曲目字段。
  /// 专辑名。
  albumName,
  /// 专辑封面（http(s)）。
  albumCoverUri,
  /// 专辑艺人（平台自己的文案）。
  albumArtist,
  /// 专辑曲目数（平台声明的 `size`）。
  albumTrackCount,

  // 歌单分类（playlistCategories）
  categoryId,
  categoryName,
  categoryCount,

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

/// 领域字段**由映射层的哪一类读取器消费**（P-30 的唯一契约来源）。
///
/// 为什么要有它：此前 `expectedFieldKinds` 是一张**手写清单**，与映射层真正的读取器
/// 各自维护 ⇒ 出现两类静默失败：
/// - **清单里没有的字段**（`playlistCoverUri`/`playlistCreator`/`playlistId`/
///   `playlistName`/`categoryId`/`categoryName`/lyric 三字段）⇒ 任何转换都放行，
///   而编辑器默认给 `asString`，读取器却要求 `Uri`/`String` ⇒ **字段恒 null**；
/// - **清单比读取器宽**（`playlistTrackCount`/`categoryCount`/`streamExpiresAt`
///   允许 `asString`，读取器只要 `int`）⇒ 同上。
/// 现在改为"**读取器 → 允许的转换**"派生，校验与映射不可能再各说各话。
enum OnlineMusicFieldReader {
  /// `'$v'` 插值成身份/标题字符串：只接受能产出 String/int 的转换 ——
  /// `asBool`/`asDuration*`/`asStringList` 虽然也产出非 null 值，但会写成
  /// `'true'`/`'0:03:00.000000'`/`'[a, b]'` 这类**垃圾身份**（违反 I1）。
  scalar,

  /// 要求非空 `String`。
  text,

  /// 要求 `List<String>`。
  textList,

  /// 要求 http(s) `Uri`。
  uri,

  /// 要求 `int`。
  integer,

  /// 要求 `Duration`。
  duration,

  /// 要求 `int`（秒级时间戳）。
  epochSeconds,
}

/// 每类读取器**真正能消费**的转换集合（P-30 的契约本体）。
const _transformsForReader = <OnlineMusicFieldReader, Set<OnlineMusicFieldTransform>>{
  OnlineMusicFieldReader.scalar: {
    OnlineMusicFieldTransform.asString,
    OnlineMusicFieldTransform.asInt,
  },
  OnlineMusicFieldReader.text: {OnlineMusicFieldTransform.asString},
  OnlineMusicFieldReader.textList: {
    OnlineMusicFieldTransform.asSingleStringList,
    OnlineMusicFieldTransform.asStringList,
  },
  OnlineMusicFieldReader.uri: {
    OnlineMusicFieldTransform.asUri,
    OnlineMusicFieldTransform.asHttpsUri,
  },
  OnlineMusicFieldReader.integer: {OnlineMusicFieldTransform.asInt},
  OnlineMusicFieldReader.duration: {
    OnlineMusicFieldTransform.asDurationMs,
    OnlineMusicFieldTransform.asDurationSeconds,
  },
  OnlineMusicFieldReader.epochSeconds: {OnlineMusicFieldTransform.asInt},
};

/// 每个领域字段用哪一类读取器（**穷举 switch**：新增字段漏声明即编译失败）。
///
/// 依据是 `lib/services/music_platform/declarative/declarative_response_mapper.dart`
/// 里各字段实际的读取调用（行号见 `docs/history/f2-admission-review.md` §1.1 P-30）。
OnlineMusicFieldReader fieldReaderOf(OnlineMusicDomainField field) =>
    switch (field) {
      OnlineMusicDomainField.trackId ||
      OnlineMusicDomainField.title ||
      OnlineMusicDomainField.playlistId ||
      OnlineMusicDomainField.categoryId ||
      OnlineMusicDomainField.categoryName => OnlineMusicFieldReader.scalar,
      OnlineMusicDomainField.album ||
      // 歌单名在"详情"路径由 `_readString` 读、在"集合"路径由 `_readRequired` 插值读
      // ⇒ 取**交集**（只要 `asString`），两条路径都安全。
      OnlineMusicDomainField.playlistName ||
      OnlineMusicDomainField.playlistCreator ||
      OnlineMusicDomainField.playlistUpdateFrequency ||
      OnlineMusicDomainField.streamQuality ||
      OnlineMusicDomainField.lyricOriginal ||
      OnlineMusicDomainField.lyricTranslation ||
      OnlineMusicDomainField.artistName ||
      OnlineMusicDomainField.artistDescription ||
      OnlineMusicDomainField.albumName ||
      OnlineMusicDomainField.albumArtist ||
      OnlineMusicDomainField.lyricRomanization => OnlineMusicFieldReader.text,
      OnlineMusicDomainField.artists ||
      OnlineMusicDomainField.artistIds ||
      OnlineMusicDomainField.albumIds => OnlineMusicFieldReader.textList,
      OnlineMusicDomainField.coverUri ||
      OnlineMusicDomainField.artistAvatarUri ||
      OnlineMusicDomainField.albumCoverUri ||
      OnlineMusicDomainField.playlistCoverUri ||
      OnlineMusicDomainField.streamUrl => OnlineMusicFieldReader.uri,
      OnlineMusicDomainField.playlistTrackCount ||
      OnlineMusicDomainField.categoryCount ||
      OnlineMusicDomainField.albumTrackCount ||
      OnlineMusicDomainField.streamBitrate => OnlineMusicFieldReader.integer,
      OnlineMusicDomainField.duration => OnlineMusicFieldReader.duration,
      OnlineMusicDomainField.streamExpiresAt =>
        OnlineMusicFieldReader.epochSeconds,
    };

/// 少数**有意的收紧**：读取器本身也接受，但业务上不该允许。
///
/// 每条都必须给出理由 —— 这是"派生"之外唯一的例外清单。
const _fieldTransformOverrides =
    <OnlineMusicDomainField, Set<OnlineMusicFieldTransform>>{
      OnlineMusicDomainField.streamUrl: {
        // 播放地址**只允许原样解析**：`asHttpsUri` 会把 http 源改写成 https，
        // 对不支持 https 的源直接把"本来能播"变成"播不了"。
        OnlineMusicFieldTransform.asUri,
      },
    };

/// 领域字段可接受的类型转换：**由读取器契约派生**（不再是手写清单）。
///
/// 语义（Spec D4:A）：不支持的转换必须在**保存/试跑**时明确报错，
/// 不得放行后在映射层静默返回 null。
final Map<OnlineMusicDomainField, Set<OnlineMusicFieldTransform>>
expectedFieldKinds = Map.unmodifiable({
  for (final field in OnlineMusicDomainField.values)
    field:
        _fieldTransformOverrides[field] ??
        _transformsForReader[fieldReaderOf(field)]!,
});

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
      op: _requireEnum(map['op'], OnlineMusicPredicateOp.values, '成功判定运算符'),
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
      okStatusCodes: _optionalList(
        map['statusCodes'],
      ).map((entry) => _requireInt(entry, '成功状态码')).toList(growable: false),
      allOf: _optionalList(
        map['allOf'],
      ).map(OnlineMusicSuccessPredicate.fromJson).toList(growable: false),
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

  /// 该字段是否必填。
  ///
  /// ⚠️ **界面/兼容元数据，不参与运行期判定**（P-31 归位）：
  /// - 运行期的必填性来自**能力级**的 [requiredFieldsFor]（保存与试跑都按它校验）；
  ///   映射层是按调用点决定用 `_readRequired` 还是 `_readOptional`，不看这个字段；
  /// - 编辑器显示的"（必填）"同样取自 [requiredFieldsFor]；
  /// - 本字段只用于与既有配置**往返**（`toJson`/`fromJson`），且保存时由
  ///   [requiredFieldsFor] 派生，因此不会出现"界面标必填、文件里写 false"的自相矛盾。
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
      candidates: _optionalList(
        map['paths'],
      ).map((entry) => _requirePath(entry, '字段路径')).toList(growable: false),
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
  int get hashCode => Object.hash(
    Object.hashAll(candidates),
    transform,
    required,
    defaultValue,
  );
}

/// 分页种类：`none` / `offsetLimit` / `pageSize` / `cursor`。
///
/// **F4-S3 定下的分页契约（P-11 + 延期 A）** —— 四条一起看才有意义：
/// 1. **`limit`**：进请求参数（每页条数），**同时**参与分页元数据判定；
///    但它**不裁剪**映射结果 —— 服务端返回多少条就映射多少条
///    （有些第三方接口不按 limit 裁剪；截断会丢数据且掩盖配置问题）。
/// 2. **`offset`**：每平台独立透传（D6c:a：各平台各自加载），老行为不变。
/// 3. **`page`**：运行期**由 `offset ~/ limit + 1` 派生**（`limit <= 0` 时按第 1 页）。
///    以前恒 1 ⇒ 任何按 `page` 取值的绑定都会永远请求第一页。
/// 4. **`cursor`**：**暂不支持** —— 服务层契约里没有"上一页游标"的位置（只有 offset/limit），
///    运行期提供不出游标。按 D4「不支持的必须明确报出、不得静默」：
///    `kind == cursor` 或参数用了 `cursor` 取值来源时，运行期/试跑**明确失败**，
///    绝不静默发出不带游标的请求（那会把第二页当成第一页）。
///
/// ⚠️ 另：搜索页的「加载更多」用 `totalPath`（已加载数 < total）**且**上一页原始条数 == 每页条数
/// 双重判定 ⇒ **没配 `totalPath` 时声明式能力的"加载更多"不会出现**（如实记录，见 F4 验收报告）。
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
      kind: _requireEnum(map['kind'], OnlineMusicPaginationKind.values, '分页类型'),
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
                _requireEnum(entry.key, OnlineMusicDomainField.values, '领域字段'):
                    OnlineMusicFieldSpec.fromJson(entry.value),
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
      // P-30：表是**派生**的，必然覆盖全部字段 ⇒ 不再有"未列出 ⇒ 不限制"的放行口。
      final expected = expectedFieldKinds[entry.key];
      if (expected != null && !expected.contains(entry.value.transform)) {
        issues.add('${entry.key.name} 的类型转换 ${entry.value.transform.name} 不合适');
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
      case OnlineMusicCapability.playlist:
        // S7b：不再是"第二阶段"，改为**真实校验** —— 歌单元数据在 fieldsRootPath、
        // 曲目数组在 listPath，两者都没有就必然映射不出来。
        if (listPath == null && fieldsRootPath == null) {
          issues.add('歌单详情能力必须配置字段根路径或列表路径');
        }
      case OnlineMusicCapability.playlistCollection:
        // 歌单集合只需要一个数组（每个元素是一个歌单摘要），元数据都在元素内部。
        if (listPath == null) {
          issues.add('歌单列表能力必须配置列表路径');
        }
      case OnlineMusicCapability.chartList:
        // 榜单索引与歌单列表同构：一个数组，每个元素是一个名次集合的元数据。
        if (listPath == null) {
          issues.add('榜单能力必须配置列表路径');
        }
      case OnlineMusicCapability.playlistCategories:
        // 分类索引同样只是一个数组，每个元素是一个分类。
        if (listPath == null) {
          issues.add('歌单分类能力必须配置列表路径');
        }
      case OnlineMusicCapability.artist:
        // 艺人详情：标量在 fieldsRootPath、热门曲目在 listPath；两者都没有必然映射不出来。
        if (listPath == null && fieldsRootPath == null) {
          issues.add('艺人详情能力必须配置字段根路径或列表路径');
        }
      case OnlineMusicCapability.album:
        // 专辑详情同理：标量在 `album`、曲目在顶层 `songs` ✓。
        if (listPath == null && fieldsRootPath == null) {
          issues.add('专辑详情能力必须配置字段根路径或列表路径');
        }
      case OnlineMusicCapability.newSongs:
        // 新歌就是一个曲目数组，与搜索同构。
        if (listPath == null) {
          issues.add('新歌能力必须配置列表路径');
        }
      case OnlineMusicCapability.lyric:
        // 至少要有一个歌词字段，否则永远取不到歌词（配置错误，不是"这首没歌词"）。
        if (!const [
          OnlineMusicDomainField.lyricOriginal,
          OnlineMusicDomainField.lyricTranslation,
          OnlineMusicDomainField.lyricRomanization,
        ].any(fields.containsKey)) {
          issues.add('歌词能力至少需要配置一个歌词字段');
        }
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
        OnlineMusicDomainField.artistIds,
        OnlineMusicDomainField.albumIds,
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
        // 可选：映射后用来校验返回的曲目就是请求的那首。
        OnlineMusicDomainField.trackId,
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
        OnlineMusicDomainField.artistIds,
        OnlineMusicDomainField.albumIds,
        OnlineMusicDomainField.album,
        OnlineMusicDomainField.coverUri,
        OnlineMusicDomainField.duration,
      };
    case OnlineMusicCapability.playlistCollection:
      // 歌单集合只有歌单自身的字段，**没有任何曲目字段**（Spec §19.2）。
      return const {
        OnlineMusicDomainField.playlistId,
        OnlineMusicDomainField.playlistName,
        OnlineMusicDomainField.playlistCoverUri,
        OnlineMusicDomainField.playlistCreator,
        OnlineMusicDomainField.playlistTrackCount,
        OnlineMusicDomainField.playlistUpdateFrequency,
      };
    case OnlineMusicCapability.chartList:
      // 榜单索引与歌单集合同构：只有集合自身的字段，没有曲目字段。
      return const {
        OnlineMusicDomainField.playlistId,
        OnlineMusicDomainField.playlistName,
        OnlineMusicDomainField.playlistCoverUri,
        OnlineMusicDomainField.playlistCreator,
        OnlineMusicDomainField.playlistTrackCount,
        OnlineMusicDomainField.playlistUpdateFrequency,
      };
    case OnlineMusicCapability.playlistCategories:
      // 分类只有分类自身：标识、名字、数量。**没有分组的字段** ——
      // 分组名在真实服务里是"以分组 id 为键的另一张表"，拼接它属于逻辑而非映射
      // （见能力枚举的说明）。
      return const {
        OnlineMusicDomainField.categoryId,
        OnlineMusicDomainField.categoryName,
        OnlineMusicDomainField.categoryCount,
      };
    case OnlineMusicCapability.newSongs:
      // 新歌就是一个曲目数组：字段集与搜索**完全相同**（不新增领域字段）。
      return const {
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
        OnlineMusicDomainField.artists,
        OnlineMusicDomainField.artistIds,
        OnlineMusicDomainField.albumIds,
        OnlineMusicDomainField.album,
        OnlineMusicDomainField.coverUri,
        OnlineMusicDomainField.duration,
      };
    case OnlineMusicCapability.album:
      // 专辑详情 = 标量（名字/封面/专辑艺人/曲目数）× 曲目（曲目字段与搜索相同）。
      // 曲目里也允许 `artistIds` ⇒ 专辑页的每一行同样能**点开艺人页** ✓。
      return const {
        OnlineMusicDomainField.albumName,
        OnlineMusicDomainField.albumCoverUri,
        OnlineMusicDomainField.albumArtist,
        OnlineMusicDomainField.albumTrackCount,
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
        OnlineMusicDomainField.artists,
        OnlineMusicDomainField.artistIds,
        OnlineMusicDomainField.albumIds,
        OnlineMusicDomainField.album,
        OnlineMusicDomainField.coverUri,
        OnlineMusicDomainField.duration,
      };
    case OnlineMusicCapability.artist:
      // 艺人详情 = 标量（名字/头像/简介）× 热门曲目（曲目字段与搜索相同）。
      // 曲目是**可选**的：艺人可能没有热门曲目，那不等于配置错 ✓。
      return const {
        OnlineMusicDomainField.artistName,
        OnlineMusicDomainField.artistAvatarUri,
        OnlineMusicDomainField.artistDescription,
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
        OnlineMusicDomainField.artists,
        OnlineMusicDomainField.artistIds,
        OnlineMusicDomainField.albumIds,
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
Set<OnlineMusicDomainField> requiredFieldsFor(
  OnlineMusicCapability capability,
) {
  switch (capability) {
    case OnlineMusicCapability.search:
      return const {
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
      };
    case OnlineMusicCapability.stream:
      // P-42：**播放入口必须能证明身份**（D-F1-2「跨 Provider 解析必须可证明同一内容
      // 或直接失败」）。没有 trackId 映射时，我们无法判断返回的地址是不是请求的那首歌，
      // 而同平台多 Provider 回退会让"错歌"真实发生（身份是请求方回填的，看不出来）。
      // 因此这里要求必须有 trackId 映射：保存/试跑时就会被拦住并说清怎么修。
      return const {
        OnlineMusicDomainField.streamUrl,
        OnlineMusicDomainField.trackId,
      };
    case OnlineMusicCapability.playlist:
      return const {
        OnlineMusicDomainField.playlistName,
        OnlineMusicDomainField.playlistId,
      };
    case OnlineMusicCapability.playlistCollection:
      // 每个歌单摘要至少要有 id 与名字，否则列表里出现空条目。
      return const {
        OnlineMusicDomainField.playlistId,
        OnlineMusicDomainField.playlistName,
      };
    case OnlineMusicCapability.chartList:
      // 同理：榜单摘要至少要有 id 与名字，否则列表里出现空条目。
      return const {
        OnlineMusicDomainField.playlistId,
        OnlineMusicDomainField.playlistName,
      };
    case OnlineMusicCapability.playlistCategories:
      // 分类至少要有 id 与名字，否则 chip 墙上出现空 chip。
      return const {
        OnlineMusicDomainField.categoryId,
        OnlineMusicDomainField.categoryName,
      };
    case OnlineMusicCapability.newSongs:
      // 与搜索同样的最低要求：至少能确定"是哪首歌、叫什么"。
      return const {
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
      };
    case OnlineMusicCapability.artist:
      // 至少要能确定"这是谁"；**热门曲目可以为空**（艺人可能没有）⇒ 不要求曲目字段 ✓。
      return const {OnlineMusicDomainField.artistName};
    case OnlineMusicCapability.album:
      // 至少要能确定"这是哪张专辑"；曲目可以为空 ✓。
      return const {OnlineMusicDomainField.albumName};
    case OnlineMusicCapability.lyric:
      return const {};
  }
}

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
