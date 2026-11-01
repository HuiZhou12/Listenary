import 'dart:convert';
import 'dart:io';

import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';

/// **本地库**那一套歌词子系统的来源枚举。
///
/// ⚠️ 这是**两套歌词子系统**里的"本地歌曲"那一套。另一套（在线歌词**搜索**）的来源
/// 枚举是 `lib/core/matcher.dart` 的 `ResultSource`，值域不同（没有 `local`）。
/// 本文件曾有一个同名平行模块（`lib/services/online_lyric/sources/`），因全仓零使用已删除。
/// 它只被本地播放链路使用（`play_service/lyric_service.dart` 的 `updateLyric` /
/// `useOnlineLyric`，作用于本地 `audioPath`）。
///
/// **在线曲目（`PlatformTrackRef`）不读这个枚举**：那条链路是
/// `RemoteLyricController` → `OnlineMusicService.fetchLyrics(ref)`，按 `ref.platform`
/// 路由到该平台的 Provider。两套**本阶段明确不合并**（Spec S6 边界：不动本地歌词源）。
enum LyricSourceType {
  qq('qq'),
  kugou('kugou'),
  ne('ne'),
  amll('amll'),
  local('local');

  final String name;
  const LyricSourceType(this.name);
}

/// 歌词来源的 id **字段类型**：决定该来源的 id 存在 `LyricSource` 的哪一个字段里。
///
/// - `text`：qq / kugou / amll，字段为 `String?`；
/// - `integer`：ne，字段为 `int?`；
/// - `none`：local，没有 id。
enum _LyricSourceIdKind { text, integer, none }

/// **映射表的一行**：一个歌词来源的 wire 名、展示名、id 字段类型与读写方式。
///
/// ⚠️ 本表是 `LyricSourceType` 的**唯一映射 owner**（原 1.1 收敛 Spec §2/§3；
/// 该草案已删除，结论见 `docs/specs/decoupling-open-issues.md` §1.1）：wire 名解析、
/// id 字段读写、界面展示名**只能**经本表；其它文件不得再写
/// 来源 switch，也不得再散落 id 字段映射。
class _LyricSourceSpec {
  const _LyricSourceSpec({
    required this.wireName,
    required this.label,
    required this.idKind,
    this.readId,
    this.build,
  });

  /// 落库 / 落 `lyric_source.json` 的稳定来源名。
  ///
  /// **必须逐字等于对应 `LyricSourceType` 成员名**：成员自带的 `name` 字段被
  /// `AppSettings.preferredOnlineSource`（`core/settings.dart`）直接持久化，
  /// 表内却用显式常量，避免"改名只改一处、另一处静默漂移"（历史缺陷 D-A）。
  final String wireName;

  /// 界面展示名。D3 已裁定统一为 `QQ` / `网易` / `酷狗` / `AMLL`。
  final String label;

  final _LyricSourceIdKind idKind;

  /// 从 [LyricSource] 读该来源的 id；`local` 没有 id，恒为 `null`。
  final String? Function(LyricSource source)? readId;

  /// 用 id 构造 [LyricSource]：文本来源取 [text]，整数来源取 [integer]。
  final LyricSource Function(String? text, int? integer)? build;
}

/// 唯一映射表（按枚举键）。
final Map<LyricSourceType, _LyricSourceSpec> _lyricSourceSpecs = {
  LyricSourceType.qq: _LyricSourceSpec(
    wireName: 'qq',
    label: 'QQ',
    idKind: _LyricSourceIdKind.text,
    readId: (source) => source.qqSongId,
    build: (text, _) => LyricSource(LyricSourceType.qq, qqSongId: text),
  ),
  LyricSourceType.kugou: _LyricSourceSpec(
    wireName: 'kugou',
    label: '酷狗',
    idKind: _LyricSourceIdKind.text,
    readId: (source) => source.kugouSongHash,
    build: (text, _) => LyricSource(LyricSourceType.kugou, kugouSongHash: text),
  ),
  LyricSourceType.ne: _LyricSourceSpec(
    wireName: 'ne',
    label: '网易',
    idKind: _LyricSourceIdKind.integer,
    readId: (source) => source.neSongId?.toString(),
    build: (_, integer) => LyricSource(LyricSourceType.ne, neSongId: integer),
  ),
  LyricSourceType.amll: _LyricSourceSpec(
    wireName: 'amll',
    label: 'AMLL',
    idKind: _LyricSourceIdKind.text,
    readId: (source) => source.amllTtmlFile,
    build: (text, _) => LyricSource(LyricSourceType.amll, amllTtmlFile: text),
  ),
  LyricSourceType.local: _LyricSourceSpec(
    wireName: 'local',
    label: '本地',
    idKind: _LyricSourceIdKind.none,
    build: (_, _) => LyricSource(LyricSourceType.local),
  ),
};

/// wire 名 → 枚举（表内派生，禁止另建一份）。
final Map<String, LyricSourceType> _lyricSourceTypesByWire = {
  for (final entry in _lyricSourceSpecs.entries)
    entry.value.wireName: entry.key,
};

_LyricSourceSpec _lyricSourceSpec(LyricSourceType source) {
  final spec = _lyricSourceSpecs[source];
  if (spec == null) {
    throw StateError('LyricSourceType.$source 缺少映射表条目');
  }
  return spec;
}

_LyricSourceSpec? _lyricSourceSpecFromWire(String? wire) {
  final source = lyricSourceTypeFromWire(wire);
  return source == null ? null : _lyricSourceSpecs[source];
}

/// 该来源落库 / 落 JSON 的稳定来源名。
String lyricSourceWireName(LyricSourceType source) =>
    _lyricSourceSpec(source).wireName;

/// 该来源的界面展示名（唯一文案 owner）。
String lyricSourceLabel(LyricSourceType source) =>
    _lyricSourceSpec(source).label;

/// 由 wire 名解析来源；无法识别时返回 `null`（调用方自行决定回落）。
LyricSourceType? lyricSourceTypeFromWire(String? wire) =>
    wire == null ? null : _lyricSourceTypesByWire[wire];

/// 该来源在 `lyric_sources.id` 列里的取值；`local` 为 `null`。
String? lyricSourceId(LyricSource source) =>
    _lyricSourceSpec(source.source).readId?.call(source);

/// 用 id 构造 [LyricSource]（表驱动的唯一 id 写入口）。
///
/// [normalizeTextId] 是**既有行为差异**（D5 保留，不统一）：
/// - `fromMap`（`lyric_source.json`）传 `true`：文本 id 走 [_normalizedTextSongId]；
/// - `_lyricSourceFromDb`（数据库行）传 `false`：文本 id **原样透传**。
/// `ne` 是整数来源，两条路径都走 [_normalizedNeSongId]。
LyricSource _lyricSourceWithId(
  _LyricSourceSpec spec,
  Object? rawId, {
  required bool normalizeTextId,
}) {
  final text = spec.idKind == _LyricSourceIdKind.text
      ? (normalizeTextId ? _normalizedTextSongId(rawId) : rawId?.toString())
      : null;
  final integer = spec.idKind == _LyricSourceIdKind.integer && rawId != null
      ? _normalizedNeSongId(rawId)
      : null;
  return spec.build!(text, integer);
}

class LyricSource {
  LyricSourceType source;
  String? qqSongId;
  String? kugouSongHash;
  int? neSongId;
  String? amllTtmlFile;

  LyricSource(
    this.source, {
    this.qqSongId,
    this.kugouSongHash,
    this.neSongId,
    this.amllTtmlFile,
  });

  static LyricSource? fromMap(Map? map) {
    if (map == null) return null;
    final spec = _lyricSourceSpecFromWire(_normalizedSourceName(map['source']));
    // 认不出的来源沿用既有容错：回落本地歌词（不抛异常），见 Spec §5。
    if (spec == null) return LyricSource(LyricSourceType.local);
    return _lyricSourceWithId(spec, map['id'], normalizeTextId: true);
  }

  Map toMap() {
    return {
      'source': lyricSourceWireName(source),
      'id': lyricSourceId(this),
    };
  }
}

Map<String, LyricSource> lyricSources = {};

Future<void> readLyricSources() async {
  final stopwatch = Stopwatch()..start();
  lyricSources = {};
  try {
    final dir = await getAppDataDir();
    final jsonFile = File(
      '${dir.path}${Platform.pathSeparator}lyric_source.json',
    );

    final db = await AppDb.instance.db();
    final count =
        db.select('SELECT COUNT(1) AS c FROM lyric_sources').first['c'] as int;
    if (count == 0 && jsonFile.existsSync()) {
      final fromJson = _readLyricSourcesFromJson(jsonFile);
      _writeLyricSourcesToDb(db, fromJson);
      lyricSources = fromJson;
      logger.i(
        '[perf] lyric sources load=${stopwatch.elapsedMilliseconds}ms '
        'count=${lyricSources.length} migrated=true',
      );
      return;
    }

    final result = <String, LyricSource>{};
    final rows = db.select('SELECT path, source, id FROM lyric_sources');
    for (final row in rows) {
      final p = row['path'] as String;
      final source = row['source'] as String;
      final id = row['id'] as String?;
      final ls = _lyricSourceFromDb(source, id);
      if (ls != null) {
        result[p] = ls;
      }
    }
    lyricSources = result;
    logger.i(
      '[perf] lyric sources load=${stopwatch.elapsedMilliseconds}ms '
      'count=${lyricSources.length} migrated=false',
    );
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
  }
}

void pruneLyricSourcesWhereMissing(bool Function(String path) containsPath) {
  lyricSources.removeWhere((path, _) => !containsPath(path));
}

Future<void> saveLyricSources() async {
  try {
    final db = await AppDb.instance.db();
    _writeLyricSourcesToDb(db, lyricSources);
  } catch (err, trace) {
    logger.e(err, stackTrace: trace);
  }
}

Map<String, LyricSource> _readLyricSourcesFromJson(File jsonFile) {
  final result = <String, LyricSource>{};
  final lyricSourceStr = jsonFile.readAsStringSync();
  final decoded = json.decode(lyricSourceStr);
  if (decoded is! Map) return result;

  for (final item in decoded.entries) {
    if (item.key is! String || item.value is! Map) continue;
    final p = item.key as String;
    final source = LyricSource.fromMap(item.value as Map);
    if (source != null) {
      result[p] = source;
    }
  }
  return result;
}

void _writeLyricSourcesToDb(Database db, Map<String, LyricSource> sources) {
  db.execute('BEGIN');
  try {
    db.execute('DELETE FROM lyric_sources');
    for (final e in sources.entries) {
      final p = e.key;
      final s = lyricSourceWireName(e.value.source);
      final id = lyricSourceId(e.value);
      db.execute(
        'INSERT INTO lyric_sources(path, source, id) VALUES(?, ?, ?)',
        [p, s, id],
      );
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

LyricSource? _lyricSourceFromDb(String source, String? id) {
  final spec = _lyricSourceSpecFromWire(_normalizedSourceName(source));
  if (spec == null) return LyricSource(LyricSourceType.local);
  return _lyricSourceWithId(spec, id, normalizeTextId: false);
}

String? _normalizedSourceName(Object? value) {
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  final separator = normalized.lastIndexOf('.');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

int? _normalizedNeSongId(Object value) {
  if (value is int) return value <= 0 ? null : value;
  final number = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value.trim()),
    _ => null,
  };
  if (number == null || !number.isFinite) return null;
  if (number != number.truncateToDouble()) return null;
  final id = number.toInt();
  return id <= 0 ? null : id;
}

String? _normalizedTextSongId(Object? value) {
  if (value == null) return null;
  if (value is int) return value <= 0 ? null : value.toString();
  if (value is num) {
    if (!value.isFinite) return null;
    if (value <= 0) return null;
    if (value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return null;
  }
  final normalized = value.toString().trim();
  return normalized.isEmpty ? null : normalized;
}
