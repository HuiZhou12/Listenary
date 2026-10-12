/// 把 JSON 响应按 [OnlineMusicResponseSpec] 映射成 Domain Model。
///
/// 纯函数：输入响应体、输出领域对象；没有网络、没有状态。
/// 映射失败一律抛 [DeclarativeMappingException]，绝不"猜一半"。
library;

import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';
import 'package:pure_music/services/online_lyric/parsed_lyric_converter.dart';
import 'package:pure_music/services/online_lyric/parsers/lrc_tool.dart';

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
  String? platformId,
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
    platformId: platformId,
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
    artistIds:
        _readStringList(spec, OnlineMusicDomainField.artistIds, element) ??
        const [],
    albumIds:
        _readStringList(spec, OnlineMusicDomainField.albumIds, element) ??
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

  // P-42（「跨 Provider 解析必须可证明同一内容或直接失败」）：**无法证明身份就不返回结果**。
  //
  // 以前这里写的是 `returnedId != null && …` —— 也就是说"没配 trackId 映射"
  // 或"配了但读不到"时校验被**静默跳过**，我们会把 `expectedRef` 直接回填给一个
  // 可能根本不是同一首的播放地址（同平台多 Provider 回退时尤其危险）。
  // 现在三种情况都失败：
  //   1. 根本没配 trackId 映射（保存/试跑另有校验提前报，这里是运行期兜底）；
  //   2. 配了但按当前路径/转换读不出来；
  //   3. 读出来了但与请求的不是同一首。
  final read = _readWithDiagnosis(spec, OnlineMusicDomainField.trackId, root);
  final returnedId = read.value;
  if (returnedId == null) {
    final mismatch = read.mismatch;
    throw DeclarativeMappingException(
      mismatch == null
          ? '无法证明返回的曲目与请求的是同一首：没有配置或取到「曲目 ID」映射'
                '（请在字段映射里把它指到响应里的 id 路径）'
          : '无法证明返回的曲目与请求的是同一首：路径「${mismatch.path.source}」取到了值'
                '（${mismatch.rawType}），但按当前类型转换 ${mismatch.transform.name} 解析不出来',
    );
  }
  if ('$returnedId' != expectedRef.trackId) {
    throw DeclarativeMappingException(
      '返回的曲目与请求的不是同一首（请求 ${expectedRef.trackId}、返回 $returnedId）',
    );
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
/// 把声明式响应映射成 [OnlineArtist]（`artist` 能力，2026-10-12 新增）。
///
/// 形状与 [mapDeclarativePlaylistResponse] 同构：
/// - `fieldsRootPath` 指向**艺人标量**所在对象（网易云在 `artist` 下；未配置时用整个响应体）；
/// - `listPath` 指向**热门曲目数组**（网易云在 `hotSongs`）；
/// - **艺人 id 不在响应里**（它是请求输入）⇒ 由 [requestedArtistId] 传入 ✓
///   （与 `playlist` 那边处理 `requestedPlaylistId` 的做法一致）。
/// 把声明式响应映射成 [OnlineAlbum]（`album` 能力，2026-10-12 新增）。
///
/// 与 [mapDeclarativePlaylistResponse]/[mapDeclarativeArtistResponse] 同构：
/// - `fieldsRootPath` 指向**专辑标量**所在对象（网易云在 `album` 下）；
/// - `listPath` 指向**曲目数组**（网易云在**顶层** `songs`）；
/// - **专辑 id 不在响应里**（它是请求输入）⇒ 由 [requestedAlbumId] 传入 ✓。
OnlineAlbum mapDeclarativeAlbumResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required MusicPlatform platform,
  String? platformId,
  required String requestedAlbumId,
}) {
  final root = spec.fieldsRootPath?.read(body) ?? body;

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

  return OnlineAlbum(
    platform: platform,
    platformId: platformId,
    id: requestedAlbumId,
    name:
        _readString(spec, OnlineMusicDomainField.albumName, root) ??
        requestedAlbumId,
    coverUri: _readUri(spec, OnlineMusicDomainField.albumCoverUri, root),
    artist: _readString(spec, OnlineMusicDomainField.albumArtist, root),
    artistId: switch (_readOptional(
      spec,
      OnlineMusicDomainField.albumArtistId,
      root,
    )) {
      final Object value => '$value',
      _ => null,
    },
    trackCount: _readIntField(
      spec,
      OnlineMusicDomainField.albumTrackCount,
      root,
    ),
    // 发行时间是**毫秒**时间戳 ⇒ 用 UTC 换算（只展示年份，见模型说明 ✓）。
    releaseTime: switch (_readIntField(
      spec,
      OnlineMusicDomainField.albumReleaseTime,
      root,
    )) {
      final int millis when millis > 0 =>
        DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
      _ => null,
    },
    tracks: tracks,
  );
}

OnlineArtist mapDeclarativeArtistResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required MusicPlatform platform,
  String? platformId,
  required String requestedArtistId,
}) {
  final root = spec.fieldsRootPath?.read(body) ?? body;

  final hotSongs = <MusicTrack>[];
  final listPath = spec.listPath;
  if (listPath != null) {
    final rawList = listPath.read(body);
    if (rawList is! List) {
      throw const DeclarativeMappingException('列表路径没有取到数组');
    }
    for (final element in rawList) {
      hotSongs.add(_mapTrack(spec, element, platform));
    }
  }

  return OnlineArtist(
    platform: platform,
    platformId: platformId,
    id: requestedArtistId,
    name:
        _readString(spec, OnlineMusicDomainField.artistName, root) ??
        requestedArtistId,
    avatarUri: _readUri(spec, OnlineMusicDomainField.artistAvatarUri, root),
    description: _readString(
      spec,
      OnlineMusicDomainField.artistDescription,
      root,
    ),
    hotSongs: hotSongs,
  );
}

RemotePlaylist mapDeclarativePlaylistResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required MusicPlatform platform,
  String? platformId,
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
    platformId: platformId,
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
  String? platformId,
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
        platformId: platformId,
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
  String? platformId,
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
        platformId: platformId,
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
Future<MusicLyrics> mapDeclarativeLyricsResponse({
  required OnlineMusicResponseSpec spec,
  required Object? body,
  required PlatformTrackRef ref,
}) async {
  const lyricFields = [
    OnlineMusicDomainField.lyricOriginal,
    OnlineMusicDomainField.lyricTranslation,
    OnlineMusicDomainField.lyricRomanization,
  ];
  if (!lyricFields.any(spec.fields.containsKey)) {
    throw const DeclarativeMappingException('未配置任何歌词字段');
  }

  final root = spec.fieldsRootPath?.read(body) ?? body;
  final original = _readString(
    spec,
    OnlineMusicDomainField.lyricOriginal,
    root,
  );
  final translation = _readString(
    spec,
    OnlineMusicDomainField.lyricTranslation,
    root,
  );
  final romanization = _readString(
    spec,
    OnlineMusicDomainField.lyricRomanization,
    root,
  );

  // ⚠️ **必须把 LRC 解析成 `parsed`**：播放侧只认 `MusicLyrics.parsed`
  //（`remote_lyric_controller`：`result.parsed == null ⇒ 显示"暂无歌词"`）。
  // 旧实现只填 original/translation/romanization ⇒ **任何声明式 Provider 的歌词都会显示
  // "暂无歌词"**，而试跑只看 original（显示"原文有"）⇒ 典型假阳性。
  // 这里与**内置路径**（`chksz_netease_codec.parseLyricsResponse`）用同一个解析器与转换，
  // 保证两条路径产出的 `MusicLyrics` 一致。
  final hasOriginal = original != null && original.trim().isNotEmpty;
  final parsedResult = hasOriginal
      ? await parseLyricInIsolate(
          text: original,
          transText: translation,
          romanizationText: romanization,
        )
      : null;

  return MusicLyrics(
    original: original,
    translation: translation,
    romanization: romanization,
    parsed: parsedResult == null
        ? null
        : parsedLyricToLyric(parsedResult, rawText: original),
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
    var raw = candidate.read(node);
    if (raw == null) continue;
    // **投影恰好命中一个值 ⇒ 对标量字段视作该值**（F3 后续）。
    // 场景：QQ 播放解析 `data.playUrl[*].url` —— 键是动态 songmid，只能投影；
    // 结果理论上逐键取值（List），但实际只会有请求的那一个键 ⇒ 标量字段应当能用。
    // ⚠️ 三条边界：① 只对**投影路径**生效（`[0]` / 裸路径语义不变）；
    // ② 只对**标量转换**生效（列表字段要的就是 List，绝不解包）；
    // ③ 多于一个值时**不解包** —— 宁可报"缺少必填字段"（fail-closed），也不静默取第一个。
    if (raw is List &&
        raw.length == 1 &&
        candidate.projects &&
        !_isListTransform(fieldSpec.transform)) {
      raw = raw.first;
      // 解包后可能正好是 null（数组里那一项是 null）⇒ 与"路径落空"同样处理。
      if (raw == null) continue;
    }
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

/// 列表类转换：它们**要的就是 List**，因此投影结果绝不能被"单元素解包"。
bool _isListTransform(OnlineMusicFieldTransform transform) =>
    transform == OnlineMusicFieldTransform.asStringList ||
    transform == OnlineMusicFieldTransform.asSingleStringList;

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
      // 单个值包成单元素列表：**数字同样按字符串取**（专辑 id 在网易云就是 int ✓，
      // 与 `asStringList` 同一条规则 ⇒ 否则"专辑 id"恒为空 ✓）。
      if (value is int) return ['$value'];
      return value is String && value.trim().isNotEmpty ? [value] : null;
    case OnlineMusicFieldTransform.asStringList:
      if (raw is! List) return null;
      final result = [
        for (final entry in raw)
          if (entry is String && entry.trim().isNotEmpty)
            entry
          // **数字按字符串取**：平台把 id 给成数字很常见（网易云实测 `ar[*].id` 是 int），
          // 而身份要的就是字符串 ⇒ 丢掉它会让"艺人 id"这类字段恒为空（2026-10-12 实测踩到）。
          // 其它类型（对象 / 布尔 / 空串）仍然**丢弃**，不猜 ✓。
          else if (entry is int)
            '$entry',
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
