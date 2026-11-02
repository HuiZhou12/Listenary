import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:pure_music/core/library_db.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/sqlite_version_guard.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';

const latestAppDatabaseVersion = 7;

/// `meta` 里记录本地播放次数导入状态的键。
const String localPlayImportKey = 'local_play_import_v1';

class AppDb {
  AppDb._();

  static final AppDb instance = AppDb._();

  Database? _db;
  Future<Database>? _opening;

  Future<Database> db() {
    final existing = _db;
    if (existing != null) return Future<Database>.value(existing);
    final opening = _opening;
    if (opening != null) return opening;

    final future = _open();
    _opening = future;
    return future;
  }

  Future<Database> _open() async {
    Database? opened;
    try {
      // 版本守卫必须在**首次打开任何连接之前**（Spec §6 / §4.3 步骤 3）。
      final probe = SqliteVersionGuard.instance.probeOnce();
      final dir = await getDbDir();
      final dbFile = File(path.join(dir.path, 'app.sqlite'));
      dbFile.parent.createSync(recursive: true);

      if (probe.isWritable) {
        opened = sqlite3.open(dbFile.path);
      } else if (dbFile.existsSync()) {
        // 禁写态：只读打开，不迁移、不改 schema。
        opened = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
        opened.execute('PRAGMA busy_timeout = 3000;');
        _db = opened;
        return opened;
      } else {
        throw StateError(
          'SQLite 版本不足（${probe.versionNumber} < $minimumSupportedSqliteVersion），'
          '且 app.sqlite 尚不存在',
        );
      }
      final supportPath = (await getAppDataDir()).path;
      initializeAppDatabase(
        opened,
        // 步骤 4 必须早于 LibraryDb 成为写者（Spec §4.3）：这里以**只读**
        // 连接读旧计数，导入失败时曲库库一个字节都没被写过。
        // 路径由 LibraryDb 提供，避免本文件成为第二个「知道曲库文件名」的地方。
        localPlaySourcePath: LibraryDb.databasePathFor(supportPath),
      );
      // 注册 deferred 补跑钩子：等 LibraryDb 完成 checkpoint 后，
      // 用同一段导入代码补跑（Spec §4.3:281-285 / §5.3:354）。
      LibraryDb.instance.deferredPlayImportHook = (indexDir) =>
          resumeDeferredLocalPlayImport(
            sourcePath: LibraryDb.databasePathFor(indexDir),
            database: opened,
          );
      _db = opened;
      return opened;
    } catch (_) {
      opened?.dispose();
      rethrow;
    } finally {
      _opening = null;
    }
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }
}

void initializeAppDatabase(Database db, {String? localPlaySourcePath}) {
  db.execute('''
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA busy_timeout = 3000;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS playlist_items (
  playlist_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  PRIMARY KEY (playlist_id, path)
);

CREATE INDEX IF NOT EXISTS idx_playlist_items_playlist_id ON playlist_items(playlist_id);

CREATE TABLE IF NOT EXISTS lyric_sources (
  path TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  id TEXT
);

CREATE TABLE IF NOT EXISTS album_colors (
  key TEXT PRIMARY KEY,
  sig TEXT NOT NULL,
  p INTEGER NOT NULL,
  on_p INTEGER NOT NULL
);
''');

  _migrateAppDatabase(db, localPlaySourcePath: localPlaySourcePath);
}

/// 给表**补一列**（已经存在就跳过 ✓）—— 迁移里做幂等加列用 ✓。
///
/// 为什么不直接 `ALTER TABLE`：全新库的建表语句已经带上了这些列 ✓，
/// 而迁移是**按版本顺序**跑的（全新库会从 v1 一路走到最新 ✓）⇒ 直接 ALTER 会重复加列报错 ✗。
void _addColumnIfMissing(
  Database db,
  String table,
  String column,
  String type,
) {
  final existing = db
      .select('PRAGMA table_info($table)')
      .map((row) => row['name'] as String)
      .toSet();
  if (existing.contains(column)) return;
  db.execute('ALTER TABLE $table ADD COLUMN $column $type');
}

void _migrateAppDatabase(Database db, {String? localPlaySourcePath}) {
  db.execute('BEGIN');
  try {
    final version =
        db.select('PRAGMA user_version').first['user_version'] as int;
    if (version < 1) {
      db.execute(
        'ALTER TABLE playlist_items ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
      );
      db.execute('PRAGMA user_version = 1');
    }
    if (version < 2) {
      try {
        db.execute('ALTER TABLE playlist_items DROP COLUMN audio_json');
      } catch (_) {}
      db.execute('PRAGMA user_version = 2');
    }
    if (version < 3) {
      db.execute('ALTER TABLE playlists ADD COLUMN cover_source TEXT');
      db.execute('PRAGMA user_version = 3');
    }
    if (version < 4) {
      db.execute('ALTER TABLE playlist_items ADD COLUMN added_at TEXT');
      db.execute('PRAGMA user_version = 4');
    }
    if (version < 5) {
      db.execute('''
CREATE TABLE IF NOT EXISTS online_tracks (
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  title TEXT NOT NULL,
  album TEXT NOT NULL DEFAULT '',
  -- v6 起建表就带上（老库由下面的 v6 块补 ✓）：专辑 id，可空 ✓。
  album_id TEXT,
  cover_uri TEXT,
  duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(duration_ms >= 0),
  availability TEXT NOT NULL DEFAULT 'unknown',
  last_quality TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (platform, track_id)
);

CREATE TABLE IF NOT EXISTS online_track_artists (
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
  name TEXT NOT NULL,
  -- v6 起建表就带上（老库由下面的 v6 块补 ✓）：艺人 id，可空 ✓。
  artist_id TEXT,
  PRIMARY KEY (platform, track_id, ordinal),
  FOREIGN KEY (platform, track_id)
    REFERENCES online_tracks(platform, track_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS online_play_history (
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  play_count INTEGER NOT NULL DEFAULT 0 CHECK(play_count >= 0),
  last_played_at TEXT NOT NULL,
  PRIMARY KEY (platform, track_id),
  FOREIGN KEY (platform, track_id)
    REFERENCES online_tracks(platform, track_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_online_history_last_played
  ON online_play_history(last_played_at DESC);
CREATE INDEX IF NOT EXISTS idx_online_history_play_count
  ON online_play_history(play_count DESC);

CREATE TABLE IF NOT EXISTS online_playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('subscription', 'personal')),
  name TEXT NOT NULL,
  platform TEXT,
  remote_playlist_id TEXT,
  cover_uri TEXT,
  creator TEXT,
  description TEXT,
  remote_track_count INTEGER CHECK(
    remote_track_count IS NULL OR remote_track_count >= 0
  ),
  last_refreshed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK(
    (kind = 'subscription' AND platform IS NOT NULL
      AND remote_playlist_id IS NOT NULL)
    OR
    (kind = 'personal' AND platform IS NULL
      AND remote_playlist_id IS NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_online_subscription_identity
  ON online_playlists(platform, remote_playlist_id)
  WHERE kind = 'subscription';
CREATE UNIQUE INDEX IF NOT EXISTS idx_online_personal_name
  ON online_playlists(name COLLATE NOCASE)
  WHERE kind = 'personal';

CREATE TABLE IF NOT EXISTS online_playlist_items (
  playlist_id INTEGER NOT NULL,
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  sort_order INTEGER NOT NULL CHECK(sort_order >= 0),
  added_at TEXT NOT NULL,
  PRIMARY KEY (playlist_id, platform, track_id),
  UNIQUE (playlist_id, sort_order),
  FOREIGN KEY (playlist_id)
    REFERENCES online_playlists(id) ON DELETE CASCADE,
  FOREIGN KEY (platform, track_id)
    REFERENCES online_tracks(platform, track_id)
);

CREATE INDEX IF NOT EXISTS idx_online_playlist_items_playlist
  ON online_playlist_items(playlist_id, sort_order);
''');
      // F5-S2（P-43）：幂等只保证「表在」，**不代表结构对**（可能是早期错误形态、
      // 被外部改过或已损坏）。这里补一次结构核对：缺列就明确抛错 ⇒
      // 由外层事务回滚、原库不被改动 —— 绝不把损坏掩盖成「迁移成功」。
      _ensureOnlineSchemaShape(db);
      db.execute('PRAGMA user_version = 5');
    }
    if (version < 6) {
      // v6（2026-10-12）：给"继续听 / 我的收藏"补回**艺人 id / 专辑 id** ✓。
      // 为什么：这两处的行是从本地库读回来的 ✓，而库里只存了**艺人名**与**专辑名** ✗
      // ⇒ 重启之后没有 id ⇒ 行上的"艺人 / 专辑"入口点不动 ✗（在线列表里都有 ✓，就这两处没有）。
      // 两列都**可空** ✓：老数据补不上就是 NULL ✓，界面据此**不显示**入口 ✓（不编造 ✓）。
      //
      // ⚠️ 必须**幂等** ✓：全新库走的是 v5 建表（已经带这两列 ✓）后再落到这里 ⇒
      // 直接 ALTER 会 "duplicate column name" ✗ ⇒ 先查列再加 ✓。
      _addColumnIfMissing(db, 'online_tracks', 'album_id', 'TEXT');
      _addColumnIfMissing(db, 'online_track_artists', 'artist_id', 'TEXT');
      db.execute('PRAGMA user_version = 6');
    }
    if (version < 7) {
      // v7（2026-11-02，3.5-b）：本地播放次数改存 app.sqlite。
      // 表本身幂等；历史次数由 [_importLocalPlayHistory] 一次性从旧库搬过来。
      db.execute('''
CREATE TABLE IF NOT EXISTS local_play_history (
  path TEXT PRIMARY KEY,
  play_count INTEGER NOT NULL DEFAULT 0 CHECK(play_count >= 0),
  last_played_at TEXT
);
''');
      _importLocalPlayHistory(db, localPlaySourcePath);
      db.execute('PRAGMA user_version = 7');
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// v7 的一次性导入：`library.sqlite.audios.play_count` → `local_play_history`。
///
/// 约束（Spec §5）：
/// - **只读源库**：`sqlite3.open(path, mode: OpenMode.readOnly)`，源库一个字节都不写；
/// - 可重入：`meta.local_play_import_v1` 已是 `"1"` 就跳过；
/// - 三类「未执行」都**不阻塞** v7 提交：`skipped-no-source` / `deferred` / `failed`；
/// - 写入用 `ON CONFLICT(path) DO NOTHING`：绝不覆盖用户切换后新产生的计数。
///
/// 源库路径由调用方经 `initializeAppDatabase(localPlaySourcePath:)` 注入
/// （测试用临时 fixture）；生产路径是 `<appData>/library.sqlite`。
void _importLocalPlayHistory(Database db, String? sourcePath) {
  final state = db.select('SELECT value FROM meta WHERE key = ?', [
    localPlayImportKey,
  ]);
  if (state.isNotEmpty && state.first['value'] == '1') return;

  if (sourcePath == null || !File(sourcePath).existsSync()) {
    // `skipped-no-source`：源库不存在。**不自动重试** —— 需要用户先恢复/重建
    // 曲库（重新扫描会写出新的 library.sqlite），届时才会重新判定。
    _markLocalPlayImport(db, 'skipped-no-source');
    return;
  }

  Database? source;
  List<({String path, int playCount})> rows;
  try {
    source = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
    rows = source
        .select(
          'SELECT path, play_count FROM audios WHERE play_count > 0 ORDER BY path',
        )
        .map(
          (row) => (
            path: row['path'] as String,
            playCount: row['play_count'] as int,
          ),
        )
        .toList(growable: false);
  } catch (err) {
    // 只读打开失败（WAL 无 -shm 等）⇒ deferred，由接管完成 checkpoint 后补跑
    // （见 [resumeDeferredLocalPlayImport]）；读到一半失败 ⇒ failed。
    // 两者都正常提交 v7。
    //
    // `failed` **不自动重试**：源库可读但内容/services 出错属用户干预范畴
    // （例如库损坏），静默重试只会重复失败。计数从 0 起步，不伪造历史。
    final deferred = source == null;
    _markLocalPlayImport(db, deferred ? 'deferred' : 'failed');
    logger.w('本地播放次数导入未完成（${deferred ? 'deferred' : 'failed'}）', error: err);
    return;
  } finally {
    source?.dispose();
  }

  if (rows.isEmpty) {
    _markLocalPlayImport(db, '1', rowCount: 0, sum: 0, digest: _digestOf(rows));
    return;
  }

  final insert = db.prepare(
    'INSERT INTO local_play_history(path, play_count) VALUES(?, ?) '
    'ON CONFLICT(path) DO NOTHING',
  );
  try {
    for (final row in rows) {
      insert.execute([row.path, row.playCount]);
    }
  } finally {
    insert.dispose();
  }
  final sum = rows.fold<int>(0, (total, row) => total + row.playCount);
  _markLocalPlayImport(
    db,
    '1',
    rowCount: rows.length,
    sum: sum,
    digest: _digestOf(rows),
  );
}

/// 补跑 `deferred` 的导入（Spec §4.3 的「只读打开的已知限制」）。
///
/// 首次导入若因「库处于 WAL 且 `-shm` 缺失/不可写」而读不了源库，会记
/// `deferred` 并正常提交 v7；等 `LibraryDb` 完成 `wal_checkpoint(TRUNCATE)`
/// 后，源库已可读，于是在**同一进程内**补跑一次。
///
/// 与首次路径**共用同一段代码**（[_importLocalPlayHistory]），因此断言口径
/// 完全一致；成功后标记改成 `"1"`。
///
/// **只处理 `deferred`**：`skipped-no-source`（源库不存在）与 `failed`
/// （读取中途抛错）**不自动重试** —— 前者要等用户重新建库/恢复文件，后者
/// 属用户干预范畴；两者都会在下次导入条件满足时由新的 v7 流程重新判定。
///
/// 返回 `true` 表示这次补跑真的把标记推进到了 `"1"`。
Future<bool> resumeDeferredLocalPlayImport({
  required String sourcePath,
  Database? database,
}) async {
  final db = database ?? await AppDb.instance.db();
  if (db.select('SELECT 1 FROM meta WHERE key = ?', [
    localPlayImportKey,
  ]).isEmpty) {
    return false;
  }
  final state = db.select('SELECT value FROM meta WHERE key = ?', [
    localPlayImportKey,
  ]).first['value'];
  if (state != 'deferred') return false;

  db.execute('BEGIN IMMEDIATE');
  try {
    _importLocalPlayHistory(db, sourcePath);
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
  final after = db.select('SELECT value FROM meta WHERE key = ?', [
    localPlayImportKey,
  ]);
  return after.isNotEmpty && after.first['value'] == '1';
}

/// 源侧与目标侧 `(path, play_count)` 全集的 sha256 摘要（按 `path` 排序）。
///
/// 这是 §5.2 的**行级强一致**断言载体：两侧摘要相同即证明搬过去的
/// 每一行都一致，而不是只比了总数。
String playHistoryDigest(Iterable<({String path, int playCount})> rows) =>
    _digestOf(rows);

String _digestOf(Iterable<({String path, int playCount})> rows) {
  final sorted = rows.toList(growable: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  final buffer = StringBuffer();
  for (final row in sorted) {
    buffer
      ..write(row.path)
      ..write('\u001f')
      ..write(row.playCount)
      ..write('\n');
  }
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}

void _markLocalPlayImport(
  Database db,
  String state, {
  int? rowCount,
  int? sum,
  String? digest,
}) {
  void put(String key, String value) {
    db.execute(
      'INSERT INTO meta(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  put(localPlayImportKey, state);
  if (rowCount != null) put('local_play_import_rows', '$rowCount');
  if (sum != null) put('local_play_import_sum', '$sum');
  if (digest != null) put('local_play_import_digest', digest);
}

/// F5-S2（P-43）：v5 在线表的**期望列**。
///
/// 为什么需要它：把 DDL 改成 `IF NOT EXISTS` 之后，「表已存在但 `user_version` 落后」
/// 的库能继续升级 —— 但**幂等只保证「表在」，不代表结构对**（可能是早期的错误形态、
/// 被外部改过、或已损坏）。若不核对结构就照常推进到 v5，会把损坏**掩盖**成「迁移成功」。
const _onlineTableExpectedColumns = <String, List<String>>{
  'online_tracks': [
    'platform',
    'track_id',
    'title',
    'album',
    // v6（2026-10-12）：专辑 id（可空 ✓ —— 老数据补不上就是 NULL ✓）。
    'album_id',
    'cover_uri',
    'duration_ms',
    'availability',
    'last_quality',
    'created_at',
    'updated_at',
  ],
  'online_track_artists': [
    'platform',
    'track_id',
    'ordinal',
    'name',
    // v6（2026-10-12）：艺人 id（可空 ✓）。
    'artist_id',
  ],
  'online_play_history': [
    'platform',
    'track_id',
    'play_count',
    'last_played_at',
  ],
  'online_playlists': [
    'id',
    'kind',
    'name',
    'platform',
    'remote_playlist_id',
    'cover_uri',
    'creator',
    'description',
    'remote_track_count',
    'last_refreshed_at',
    'created_at',
    'updated_at',
  ],
  'online_playlist_items': [
    'playlist_id',
    'platform',
    'track_id',
    'sort_order',
    'added_at',
  ],
};

/// 核对 v5 在线表的列是否齐全；缺列 ⇒ **明确失败**（由调用方的事务回滚）。
void _ensureOnlineSchemaShape(Database db) {
  for (final entry in _onlineTableExpectedColumns.entries) {
    final columns = db
        .select('PRAGMA table_info(${entry.key})')
        .map((row) => row['name'] as String)
        .toSet();
    final missing = entry.value
        .where((column) => !columns.contains(column))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      throw StateError(
        '在线表 ${entry.key} 的结构不符合预期（缺少列：${missing.join('、')}）。'
        '为避免在损坏或不兼容的库上继续升级，已中止迁移；原库未被修改。',
      );
    }
  }
}
