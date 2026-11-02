import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:pure_music/core/sqlite_version_guard.dart';
import 'package:pure_music/core/utils.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:win32/win32.dart';

const String databaseLayoutVersion = '2';
const int currentIndexVersion = 111;

const int _smallCoverMaxDimension = 128;
const int _mediumCoverMaxDimension = 320;
const int _maxPersistedSmallCovers = 4096;
const int _maxPersistedMediumCovers = 512;
const int _maxPersistedLargeCovers = 64;
const int _coverPruneReadBatch = 2;
const int _coverPruneWriteBatch = 16;
const int _coverAccessRefreshIntervalMs = 6 * 60 * 60 * 1000;

/// SQLite 里可能是负数的整型字段统一抬到 0（与旧 Rust `max(0)` 同口径）。
int _nonNegative(int value) => value < 0 ? 0 : value;

/// 一条曲目的身份：(文件系统身份, 元数据身份)。
///
/// 两者都是**字节契约**：值要能和旧 Rust 引擎写进库里的值逐字符相等，
/// 否则跨版本/跨引擎的重命名继承会失效（Spec §5.4）。
class AudioIdentity {
  const AudioIdentity({this.mediaId, this.metadataKey});

  final String? mediaId;
  final String? metadataKey;
}

/// 计算一条曲目的身份键。
AudioIdentity audioIdentity({
  required String path,
  required String title,
  required String artist,
  required String album,
  required String? albumArtist,
  required int track,
  required int duration,
  required int? bitrate,
  required int? sampleRate,
}) => AudioIdentity(
  mediaId: stableFileId(path),
  metadataKey: metadataMatchKey(
    path: path,
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    track: track,
    duration: duration,
    bitrate: bitrate,
    sampleRate: sampleRate,
  ),
);

/// 路径归一键：`trim` → `\`→`/` → 去尾斜杠（保 `/`）→ 小写。
String pathLookupKey(String value) {
  var normalized = value.trim().replaceAll('\\', '/');
  while (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.toLowerCase();
}

/// 元数据匹配键：9 段以 `\x1f` 连接后取 MD5，输出 `meta:{小写十六进制}`。
String metadataMatchKey({
  required String path,
  required String title,
  required String artist,
  required String album,
  required String? albumArtist,
  required int track,
  required int duration,
  required int? bitrate,
  required int? sampleRate,
}) {
  final material = [
    normalizeIdentityPart(title),
    normalizeIdentityPart(artist),
    normalizeIdentityPart(album),
    normalizeIdentityPart(albumArtist ?? ''),
    '$track',
    '$duration',
    '${bitrate ?? 0}',
    '${sampleRate ?? 0}',
    pathExtensionLowercase(path),
  ].join('\u001f');
  return 'meta:${md5.convert(utf8.encode(material))}';
}

/// 空白折叠 + 小写。空白口径对齐 Rust `char::is_whitespace`
/// （Unicode `White_Space` 属性），不是 Dart 正则 `\s`。
String normalizeIdentityPart(String value) {
  final parts = <String>[];
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (isUnicodeWhitespace(rune)) {
      if (buffer.isNotEmpty) {
        parts.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.writeCharCode(rune);
  }
  if (buffer.isNotEmpty) parts.add(buffer.toString());
  return parts.join(' ').toLowerCase();
}

/// Unicode `White_Space` 属性（Rust `char::is_whitespace` 的口径）。
bool isUnicodeWhitespace(int rune) =>
    (rune >= 0x09 && rune <= 0x0d) ||
    rune == 0x20 ||
    rune == 0x85 ||
    rune == 0xa0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200a) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202f ||
    rune == 0x205f ||
    rune == 0x3000;

/// 扩展名（小写、不含点）。语义对齐 Rust `Path::extension`：
/// 无文件名 / 无内嵌点 / 「以点开头且无其它点」都返回空串。
String pathExtensionLowercase(String value) {
  final name = _fileName(value);
  if (name == null) return '';
  if (name == '..') return '';
  final dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  if (dot == 0) return '';
  return name.substring(dot + 1).toLowerCase();
}

String? _fileName(String value) {
  if (value.isEmpty) return null;
  final last = value[value.length - 1];
  if (last == '/' || last == '\\') return null;
  final slash = value.lastIndexOf('/');
  final backslash = value.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  return value.substring(cut + 1);
}

/// 文件系统稳定身份：`win:{卷序列号:08x}:{(高32位<<32|低32位):016x}`。
///
/// 非 Windows 返回 `null`（与旧 Rust 的 `#[cfg(not(any(windows, unix)))]`
/// 兜底分支等价）；本项目只发布 Windows，`unix` 分支不移植。文件打不开
/// （已删除 / 无权限）同样返回 `null`——身份键缺失只会让重命名继承降级，
/// 不会阻断索引同步。
String? stableFileId(String path) {
  if (!Platform.isWindows) return null;
  const share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
  final pathPtr = path.toNativeUtf16();
  final infoPtr = calloc<BY_HANDLE_FILE_INFORMATION>();
  var handle = INVALID_HANDLE_VALUE;
  try {
    // `FILE_FLAG_BACKUP_SEMANTICS`：允许对**目录**取句柄（回填时路径理论上
    // 都是文件，但拿不到句柄就降级为 null 更稳妥）。
    handle = CreateFile(
      pathPtr,
      GENERIC_READ,
      share,
      nullptr,
      OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS,
      0,
    );
    if (handle == INVALID_HANDLE_VALUE) return null;
    if (GetFileInformationByHandle(handle, infoPtr) == 0) return null;
    final info = infoPtr.ref;
    final fileIndex =
        (info.nFileIndexHigh << 32) | (info.nFileIndexLow & 0xffffffff);
    final volume = info.dwVolumeSerialNumber & 0xffffffff;
    return 'win:${volume.toRadixString(16).padLeft(8, '0')}:'
        '${fileIndex.toRadixString(16).padLeft(16, '0')}';
  } catch (err) {
    logger.w('stable_file_id 获取失败', error: err);
    return null;
  } finally {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    calloc.free(pathPtr);
    calloc.free(infoPtr);
  }
}

/// 索引里的一条曲目（`audios` 表一行的投影）。
class LibraryAudio {
  const LibraryAudio({
    required this.title,
    required this.artist,
    required this.album,
    required this.albumArtist,
    required this.track,
    required this.disc,
    required this.duration,
    required this.bitrate,
    required this.sampleRate,
    required this.path,
    required this.modified,
    required this.created,
    required this.by,
    required this.playCount,
  });

  final String title;
  final String artist;
  final String album;
  final String? albumArtist;
  final int track;
  final int disc;
  final int duration;
  final int? bitrate;
  final int? sampleRate;
  final String path;
  final int modified;
  final int created;
  final String? by;
  final int playCount;
}

/// 索引里的一个曲库文件夹（`folders` 表一行 + 其下曲目）。
class LibraryFolder {
  LibraryFolder({
    required this.path,
    required this.modified,
    required this.latest,
    required this.audios,
  });

  final String path;
  final int modified;
  final int latest;
  final List<LibraryAudio> audios;
}

/// `updateIndex` 的快路径入参：上次同步进库的索引快照。
class LibraryIndexSnapshot {
  const LibraryIndexSnapshot({
    required this.version,
    required this.folders,
    required this.indexSourceModified,
    required this.indexSourceSize,
  });

  final int version;
  final List<LibraryFolderSnapshot> folders;
  final int? indexSourceModified;
  final int? indexSourceSize;
}

class LibraryFolderSnapshot {
  const LibraryFolderSnapshot({required this.path, required this.modified});

  final String path;
  final int modified;
}

/// `library.sqlite` 的 Dart 侧仓储（3.5-b 起唯一 owner）。
///
/// 设计要点：
/// - **原地接管**：直接打开现有文件，不新建、不改名、不迁移数据；
/// - **幂等 DDL + layout 校验**：等价复刻 Rust 时代的四类自愈行为（含整库重建）；
/// - **禁写降级**：`winsqlite3.dll` 版本不足或探测失败时，所有写路径直接跳过，
///   读路径由调用方回退到 `index.json`。
class LibraryDb {
  LibraryDb._();

  static final LibraryDb instance = LibraryDb._();

  /// `library.sqlite` 的文件名。**只有本文件**可以拼它：
  /// 其他模块要拿路径一律走 [databasePathFor]，这样「谁拥有这个库」在
  /// 源码层面只有一处（边界守卫据此断言）。
  static const String databaseFileName = 'library.sqlite';

  /// 给定数据目录，返回曲库库的完整路径。
  static String databasePathFor(String indexDir) =>
      p.join(indexDir, databaseFileName);

  /// 接管完成（checkpoint 之后）的补跑钩子，由 `AppDb` 在打开应用库时注册。
  ///
  /// **为什么不直接 import `database.dart`**：那会让 `library_db.dart` 与
  /// `database.dart` 形成新的同层循环依赖，把 `sameLayerSccBaseline` 的
  /// 6 组推成 7 组（计数被锁死，不能为了变绿去改基线）。用回调把方向保持为
  /// 「database → library_db」单向。
  Future<bool> Function(String indexDir)? deferredPlayImportHook;

  Database? _db;
  String? _indexDir;

  /// 当前是否真的具备写能力（版本守卫 + 连接已建立）。
  bool get isWritable => SqliteVersionGuard.instance.canWrite && _db != null;

  /// 库是否已打开（读路径据此决定是否回退 `index.json`）。
  bool get isOpen => _db != null;

  String? get indexDir => _indexDir;

  /// 仅供测试：当前连接（生产代码不得使用）。
  Database? get debugDatabaseForTest => _db;

  /// 测试专用：指向一个隔离目录（不接触真实用户数据）。
  void debugOpenAtForTest(String indexDir, {Database? database}) {
    dispose();
    _indexDir = indexDir;
    _db = database ?? sqlite3.open(p.join(indexDir, 'library.sqlite'));
  }

  /// 打开（或以只读方式探测）`<indexDir>/library.sqlite`。
  ///
  /// 文件缺失时默认**不创建**：返回 `false`，调用方按「无库」处理。
  /// [createIfMissing] 为 `true` 时（上一级存在 `index.json`），会先建空库、
  /// 跑幂等 DDL，再由调用方 `syncIndexJson` 全量灌入。
  Future<bool> initialize({
    required String indexDir,
    bool createIfMissing = false,
  }) async {
    if (_indexDir == indexDir && _db != null) return true;
    if (_indexDir != indexDir) {
      dispose();
      _indexDir = indexDir;
    }
    final probe = SqliteVersionGuard.instance.probeOnce();
    final dbPath = p.join(indexDir, 'library.sqlite');
    final legacyPath = p.join(indexDir, 'library.sqlite.legacy');
    var creates = false;
    if (!File(dbPath).existsSync()) {
      if (!probe.isWritable) return false;
      if (File(legacyPath).existsSync()) {
        // H4：`.legacy` 在、主库缺失 ⇒ 先重建。
        await rebuildFromLegacy(indexDir);
      } else if (createIfMissing) {
        creates = true;
      } else {
        return false;
      }
    }
    // 残留文件必须先于任何读处理掉（H4）。
    if (probe.isWritable) {
      _removeDatabaseFiles(p.join(indexDir, 'library.sqlite.migrating'));
    }
    final Database opened;
    try {
      opened = sqlite3.open(
        dbPath,
        mode: !probe.isWritable
            ? OpenMode.readOnly
            : (creates ? OpenMode.readWriteCreate : OpenMode.readWrite),
      );
    } catch (err, trace) {
      logger.w(
        'library.sqlite 打开失败，曲库回退 JSON 索引',
        error: err,
        stackTrace: trace,
      );
      return false;
    }
    _db = opened;
    _applyConnectionPragmas(opened, writable: probe.isWritable);
    if (!probe.isWritable) {
      logger.w('SQLite 版本不足，library.sqlite 以只读方式打开，跳过自愈与接管标记');
      return true;
    }
    try {
      // 收掉旧 Rust 进程遗留的 -wal（W1）。失败不删文件、不阻断启动。
      try {
        opened.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      } catch (err) {
        logger.w('library.sqlite checkpoint 失败，按只读语义继续', error: err);
      }
      ensureLayout(opened, indexDir);
      // `ensureLayout` 触发整库重建时会替换（并关闭）连接，因此这里必须
      // 用当前 `_db`，不能用 `opened` 这个可能已失效的引用。
      final active = _db;
      if (active == null) throw StateError('library.sqlite 连接丢失');
      active.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('dart_takeover_v1', '1')",
      );
      // Spec §4.3：本进程到这里才第一次成为写者、且 `-wal` 已被 checkpoint
      // 收掉 ⇒ 源库此时可读，补跑首次因只读打开失败而 `deferred` 的计数导入。
      // 失败只记日志，不影响曲库可用性。
      await _resumeDeferredPlayImport(indexDir);
    } catch (err, trace) {
      // 自愈失败由调用方的 JSON 回退接住，不升级成启动失败。
      logger.w(
        'library.sqlite 接管失败，曲库回退 JSON 索引',
        error: err,
        stackTrace: trace,
      );
      dispose();
      return false;
    }
    return true;
  }

  /// 补跑首次 `deferred` 的本地播放次数导入（Spec §4.3 / §5.3）。
  ///
  /// 仅在「本进程已完成 checkpoint、成为写者」之后调用；钩子未注册
  /// （纯仓储测试 / 应用库不可用）时静默跳过。
  Future<void> _resumeDeferredPlayImport(String indexDir) async {
    final hook = deferredPlayImportHook;
    if (hook == null) return;
    try {
      final resumed = await hook(indexDir);
      if (resumed) {
        logger.i('[play history] deferred 导入已在 checkpoint 后补跑完成');
      }
    } catch (err, trace) {
      // 补跑失败不改写标记（仍停在 deferred），下次启动再试；不影响曲库使用。
      logger.w('本地播放次数补跑失败，保留 deferred 待下次启动', error: err, stackTrace: trace);
    }
  }

  /// 仅供测试：直接驱动 [deferredPlayImportHook]（验证接线，不必真跑整个 open）。
  Future<void> resumeDeferredPlayImportForTest(String indexDir) =>
      _resumeDeferredPlayImport(indexDir);

  void _applyConnectionPragmas(Database db, {required bool writable}) {
    if (writable) {
      db.execute('''
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA temp_store = MEMORY;
PRAGMA auto_vacuum = INCREMENTAL;
''');
    } else {
      db.execute('PRAGMA temp_store = MEMORY;');
    }
    // 今日 Rust 是 2s；取 3s 与 app.sqlite 对齐，不低于旧值（Spec §2-4③）。
    db.execute('PRAGMA busy_timeout = 3000;');
  }

  void dispose() {
    _db?.dispose();
    _db = null;
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 自愈（H1–H6 的等价移植）
  // ───────────────────────────────────────────────────────────────────────────

  void _removeDatabaseFile(String path) {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  void _removeDatabaseFiles(String path) {
    _removeDatabaseFile(path);
    _removeDatabaseFile('$path-wal');
    _removeDatabaseFile('$path-shm');
  }

  bool hasLayoutMarker(Database db) {
    final rows = db.select(
      "SELECT value FROM meta WHERE key = 'database_layout_version'",
    );
    return rows.isNotEmpty && rows.first['value'] == databaseLayoutVersion;
  }

  bool _coverTierExceedsLimit(Database db, String condition, int maxEntries) {
    final rows = db.select(
      'SELECT EXISTS('
      'SELECT 1 FROM cover_thumbnails WHERE $condition LIMIT 1 OFFSET ?'
      ')',
      [maxEntries],
    );
    return (rows.first.values.first as int) != 0;
  }

  /// H2 的判定：`auto_vacuum == 0` **且**任一封面档超限才重建。
  bool shouldRebuildDatabase(Database db) {
    final autoVacuum =
        db.select('PRAGMA auto_vacuum').first.values.first as int;
    if (autoVacuum != 0) return false;
    const small = _smallCoverMaxDimension;
    const medium = _mediumCoverMaxDimension;
    return _coverTierExceedsLimit(
          db,
          'width <= $small AND height <= $small',
          _maxPersistedSmallCovers,
        ) ||
        _coverTierExceedsLimit(
          db,
          '(width > $small OR height > $small) '
          'AND width <= $medium AND height <= $medium',
          _maxPersistedMediumCovers,
        ) ||
        _coverTierExceedsLimit(
          db,
          'width > $medium OR height > $medium',
          _maxPersistedLargeCovers,
        );
  }

  /// 幂等 DDL + layout + 身份回填（H1/H2/H5/H6）。
  ///
  /// 顺序与今日 Rust `ensure_database_layout` → `init_schema` 一致。
  void ensureLayout(Database db, String indexDir) {
    if (!SqliteVersionGuard.instance.canWrite) return;
    final current = File(p.join(indexDir, 'library.sqlite'));
    final legacy = p.join(indexDir, 'library.sqlite.legacy');

    initSchema(db);
    if (hasLayoutMarker(db)) {
      _removeDatabaseFiles(legacy);
      return;
    }
    if (!shouldRebuildDatabase(db)) {
      // H1：auto_vacuum 已不是 0，或封面都没超限 ⇒ 直接补标记，不重建。
      db.execute('INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)', [
        'database_layout_version',
        databaseLayoutVersion,
      ]);
      _removeDatabaseFiles(legacy);
      return;
    }
    // H2：走 `.legacy` → `.migrating` → rename 覆盖。
    try {
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } catch (_) {}
    db.dispose();
    _removeDatabaseFiles(legacy);
    _removeDatabaseFile('${current.path}-wal');
    _removeDatabaseFile('${current.path}-shm');
    current.renameSync(legacy);
    rebuildFromLegacy(indexDir);
    final reopened = sqlite3.open(current.path);
    _applyConnectionPragmas(reopened, writable: true);
    initSchema(reopened);
    _db = reopened;
  }

  /// 从 `.legacy` 重建主库（H2/H3）。
  ///
  /// 复制列集合与今日一致：`meta` / `folders` / `audios`，**不含**
  /// `cover_thumbnails`（超限重建的意义就是把封面清掉）。
  Future<void> rebuildFromLegacy(String indexDir) async {
    final currentPath = p.join(indexDir, 'library.sqlite');
    final legacyPath = p.join(indexDir, 'library.sqlite.legacy');
    final migratingPath = p.join(indexDir, 'library.sqlite.migrating');
    _removeDatabaseFiles(migratingPath);

    try {
      final migrating = sqlite3.open(migratingPath);
      try {
        _applyConnectionPragmas(migrating, writable: true);
        initSchema(migrating);
        migrating.execute('ATTACH DATABASE ? AS legacy', [legacyPath]);
        migrating.execute('BEGIN IMMEDIATE');
        try {
          migrating.execute('''
INSERT OR REPLACE INTO meta(key, value)
  SELECT key, value FROM legacy.meta;
INSERT INTO folders(path, modified, latest)
  SELECT path, modified, latest FROM legacy.folders;
INSERT INTO audios(
  path, folder_path, title, artist, album, album_artist, track, disc,
  duration, bitrate, sample_rate, modified, created, by, play_count,
  media_id, metadata_key
) SELECT
  path, folder_path, title, artist, album, album_artist, track, disc,
  duration, bitrate, sample_rate, modified, created, by, play_count,
  media_id, metadata_key
FROM legacy.audios;
''');
          migrating.execute(
            'INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)',
            ['database_layout_version', databaseLayoutVersion],
          );
          migrating.execute('COMMIT');
        } catch (_) {
          migrating.execute('ROLLBACK');
          rethrow;
        }
        migrating.execute('DETACH DATABASE legacy;');
        migrating.execute('PRAGMA optimize;');
        migrating.execute('PRAGMA wal_checkpoint(TRUNCATE);');
      } finally {
        migrating.dispose();
      }
      _removeDatabaseFile('$migratingPath-wal');
      _removeDatabaseFile('$migratingPath-shm');
      File(migratingPath).renameSync(currentPath);
      final check = sqlite3.open(currentPath, mode: OpenMode.readOnly);
      try {
        if (!hasLayoutMarker(check)) {
          throw StateError('rebuilt database layout marker missing');
        }
      } finally {
        check.dispose();
      }
    } catch (err) {
      // H3：失败回滚 —— 删 `.migrating`；若 `.legacy` 在 ⇒ 删主库并把
      // `.legacy` 改名回主库；最后原样上抛，由调用方 JSON 回退接住。
      _removeDatabaseFiles(migratingPath);
      if (File(legacyPath).existsSync()) {
        _removeDatabaseFiles(currentPath);
        File(legacyPath).renameSync(currentPath);
      }
      rethrow;
    }
    _removeDatabaseFiles(legacyPath);
  }

  /// 幂等 DDL + 列级补丁 + 身份回填（H5/H6）。
  void initSchema(Database db) {
    db.execute('''
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS folders (
  path TEXT PRIMARY KEY,
  modified INTEGER NOT NULL,
  latest INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS audios (
  path TEXT PRIMARY KEY,
  folder_path TEXT NOT NULL,
  title TEXT NOT NULL,
  artist TEXT NOT NULL,
  album TEXT NOT NULL,
  album_artist TEXT,
  track INTEGER,
  disc INTEGER,
  duration INTEGER NOT NULL,
  bitrate INTEGER,
  sample_rate INTEGER,
  modified INTEGER NOT NULL,
  created INTEGER NOT NULL,
  by TEXT,
  play_count INTEGER NOT NULL DEFAULT 0,
  media_id TEXT,
  metadata_key TEXT
);

CREATE INDEX IF NOT EXISTS idx_audios_folder_path_path ON audios(folder_path, path);
CREATE INDEX IF NOT EXISTS idx_audios_title ON audios(title);
CREATE INDEX IF NOT EXISTS idx_audios_artist ON audios(artist);
CREATE INDEX IF NOT EXISTS idx_audios_album ON audios(album);

CREATE TABLE IF NOT EXISTS cover_thumbnails (
  path TEXT NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  source_modified INTEGER NOT NULL,
  source_size INTEGER NOT NULL,
  last_accessed INTEGER NOT NULL DEFAULT 0,
  png BLOB NOT NULL,
  PRIMARY KEY (path, width, height)
);
''');
    // H6：列级补丁。用 `PRAGMA table_info` 判存在（等价今日的
    // `SELECT col … LIMIT 1` 试错策略），同列同默认值。
    _addColumnIfMissing(
      db,
      'audios',
      'play_count',
      'INTEGER NOT NULL DEFAULT 0',
    );
    _addColumnIfMissing(db, 'audios', 'disc', 'INTEGER');
    _addColumnIfMissing(db, 'audios', 'media_id', 'TEXT');
    _addColumnIfMissing(db, 'audios', 'metadata_key', 'TEXT');
    _addColumnIfMissing(
      db,
      'cover_thumbnails',
      'last_accessed',
      'INTEGER NOT NULL DEFAULT 0',
    );
    db.execute('''
CREATE INDEX IF NOT EXISTS idx_audios_media_id ON audios(media_id);
CREATE INDEX IF NOT EXISTS idx_audios_metadata_key ON audios(metadata_key);
DROP INDEX IF EXISTS idx_audios_folder_path;
''');
    // H5：一次性身份回填。
    final backfill = db.select(
      "SELECT value FROM meta WHERE key = 'identity_backfill_v1'",
    );
    final done = backfill.isNotEmpty && backfill.first['value'] == '1';
    if (!done) {
      backfillAudioIdentities(db);
      db.execute(
        "INSERT OR REPLACE INTO meta(key, value) VALUES('identity_backfill_v1', '1')",
      );
    }
  }

  void _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) {
    final columns = db
        .select('PRAGMA table_info($table)')
        .map((row) => row['name'] as String)
        .toSet();
    if (columns.contains(column)) return;
    db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  void backfillAudioIdentities(Database db) {
    final missing = db.select(
      'SELECT path, title, artist, album, album_artist, track, duration, '
      'bitrate, sample_rate FROM audios '
      'WHERE media_id IS NULL OR metadata_key IS NULL',
    );
    if (missing.isEmpty) return;
    final update = db.prepare(
      'UPDATE audios SET '
      'media_id = COALESCE(media_id, ?1), '
      'metadata_key = COALESCE(metadata_key, ?2) '
      'WHERE path = ?3',
    );
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final row in missing) {
        final path = row['path'] as String;
        final identity = audioIdentity(
          path: path,
          title: row['title'] as String,
          artist: row['artist'] as String,
          album: row['album'] as String,
          albumArtist: row['album_artist'] as String?,
          track: (row['track'] as int?) ?? 0,
          duration: (row['duration'] as int?) ?? 0,
          bitrate: row['bitrate'] as int?,
          sampleRate: row['sample_rate'] as int?,
        );
        update.execute([identity.mediaId, identity.metadataKey, path]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      update.dispose();
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 读取
  // ───────────────────────────────────────────────────────────────────────────

  /// 读全量索引。返回 `null` 表示「不可读，调用方应回退 `index.json`」。
  List<LibraryFolder>? readIndex() {
    final db = _db;
    if (db == null) return null;
    final version = db.select("SELECT value FROM meta WHERE key = 'version'");
    if (version.isEmpty) return null;

    final folders = <LibraryFolder>[];
    final folderIndexByPath = <String, int>{};
    for (final row in db.select(
      'SELECT path, modified, latest FROM folders ORDER BY path',
    )) {
      folderIndexByPath[row['path'] as String] = folders.length;
      folders.add(
        LibraryFolder(
          path: row['path'] as String,
          modified: _nonNegative(row['modified'] as int),
          latest: _nonNegative(row['latest'] as int),
          audios: <LibraryAudio>[],
        ),
      );
    }

    for (final row in db.select(
      'SELECT folder_path, title, artist, album, album_artist, track, disc, '
      'duration, bitrate, sample_rate, path, modified, created, by, play_count '
      'FROM audios ORDER BY folder_path, path',
    )) {
      final index = folderIndexByPath[row['folder_path'] as String];
      // 与旧实现一致：folder 行缺失的 audios 行被丢弃。
      if (index == null) continue;
      final track = row['track'] as int?;
      final disc = row['disc'] as int?;
      final bitrate = row['bitrate'] as int?;
      final sampleRate = row['sample_rate'] as int?;
      folders[index].audios.add(
        LibraryAudio(
          title: row['title'] as String,
          artist: row['artist'] as String,
          album: row['album'] as String,
          albumArtist: row['album_artist'] as String?,
          track: _nonNegative(track ?? 0),
          disc: _nonNegative(disc ?? 0),
          duration: _nonNegative(row['duration'] as int),
          bitrate: bitrate == null ? null : _nonNegative(bitrate),
          sampleRate: sampleRate == null ? null : _nonNegative(sampleRate),
          path: row['path'] as String,
          modified: _nonNegative(row['modified'] as int),
          created: _nonNegative(row['created'] as int),
          by: row['by'] as String?,
          playCount: row['play_count'] as int,
        ),
      );
    }
    return folders;
  }

  /// 读快路径入参；无可用快照时返回 `null`（⇒ 调用方传 `null`，全量检查）。
  LibraryIndexSnapshot? readSnapshot() {
    final db = _db;
    if (db == null) return null;
    final versionRows = db.select(
      "SELECT value FROM meta WHERE key = 'version'",
    );
    if (versionRows.isEmpty) return null;
    final version = int.tryParse('${versionRows.first['value']}');
    if (version == null) return null;
    final folders = <LibraryFolderSnapshot>[];
    for (final row in db.select(
      'SELECT path, modified FROM folders ORDER BY path',
    )) {
      folders.add(
        LibraryFolderSnapshot(
          path: row['path'] as String,
          modified: _nonNegative(row['modified'] as int),
        ),
      );
    }
    return LibraryIndexSnapshot(
      version: version,
      folders: folders,
      indexSourceModified: _metaInt(db, 'index_source_modified'),
      indexSourceSize: _metaInt(db, 'index_source_size'),
    );
  }

  int? _metaInt(Database db, String key) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return int.tryParse('${rows.first['value']}');
  }

  // ───────────────────────────────────────────────────────────────────────────
  // 写入
  // ───────────────────────────────────────────────────────────────────────────

  /// 若库里的索引已落后于 `index.json`，把 JSON 全量同步进库。
  ///
  /// 取代旧 Rust 在扫描结束时自己写库的两个钩子（`build_index_*` /
  /// `update_index`）。判定用 `meta.index_source_modified/size` 对文件签名，
  /// 与旧快路径同一口径，因此重复调用是幂等的、不会白解析 24MB JSON。
  ///
  /// 返回 `true` 表示本次确实写了库。
  bool syncIndexJsonIfStale({required String indexDir}) {
    if (!isWritable) return false;
    final indexPath = p.join(indexDir, 'index.json');
    final file = File(indexPath);
    if (!file.existsSync()) return false;
    final signature = _fileSourceSignature(indexPath);
    if (signature == null) return false;
    final db = _db!;
    final storedModified = _metaInt(db, 'index_source_modified');
    final storedSize = _metaInt(db, 'index_source_size');
    final hasVersion = db
        .select("SELECT 1 FROM meta WHERE key = 'version'")
        .isNotEmpty;
    if (hasVersion &&
        storedModified == signature.$1 &&
        storedSize == signature.$2) {
      return false;
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) throw StateError('index.json is not an object');
    return syncIndexJson(decoded.cast<String, Object?>(), indexDir: indexDir);
  }

  /// 把 `index.json` 的内容同步进库（取代 Rust 的
  /// `migrateIndexJsonToSqlite` / `write_index_value_to_sqlite`）。
  ///
  /// 保留今日全部增量语义：按 `path_lookup_key` 归一复用 `play_count`、
  /// 陈旧 `audios`/`folders` 行删除、`cover_thumbnails` 孤儿清理、
  /// `meta.version` 与 `index_source_*` 写回。写事务用 `BEGIN IMMEDIATE`。
  ///
  /// 返回 `false` 表示本次没有写（禁写态 / 库未打开）。
  bool syncIndexJson(Map<String, Object?> index, {required String indexDir}) {
    final db = _db;
    if (db == null || !isWritable) return false;
    final stopwatch = Stopwatch()..start();
    final rawFolders = index['folders'];
    if (rawFolders is! List) throw StateError('missing folders');
    final version = (index['version'] as num?)?.toInt() ?? 0;
    final signature = _fileSourceSignature(p.join(indexDir, 'index.json'));

    final currentAudioKeys = <String>{};
    final currentAudioExactPaths = <String>{};
    final currentFolderPaths = <String>{};
    final identityInputs = <_IdentityInput>[];
    for (final folder in rawFolders) {
      if (folder is! Map) throw StateError('folder is not a map');
      final folderPath = folder['path'];
      if (folderPath is! String) throw StateError('folder.path missing');
      if (!currentFolderPaths.add(folderPath)) {
        throw StateError('duplicate folder path');
      }
      final audios = folder['audios'];
      if (audios is! List) throw StateError('folder.audios missing');
      for (final audio in audios) {
        if (audio is! Map) throw StateError('audio is not a map');
        final path = audio['path'];
        if (path is! String) throw StateError('audio.path missing');
        if (!currentAudioExactPaths.add(path)) {
          throw StateError('duplicate audio path');
        }
        final pathKey = pathLookupKey(path);
        currentAudioKeys.add(pathKey);
        identityInputs.add(
          _IdentityInput(
            path: path,
            pathKey: pathKey,
            modified: (audio['modified'] as num?)?.toInt() ?? 0,
            metadataKey: metadataMatchKey(
              path: path,
              title: audio['title'] as String? ?? '',
              artist: audio['artist'] as String? ?? '',
              album: audio['album'] as String? ?? '',
              albumArtist: audio['album_artist'] as String?,
              track: (audio['track'] as num?)?.toInt() ?? 0,
              duration: (audio['duration'] as num?)?.toInt() ?? 0,
              bitrate: (audio['bitrate'] as num?)?.toInt(),
              sampleRate: (audio['sample_rate'] as num?)?.toInt(),
            ),
          ),
        );
      }
    }

    db.execute('BEGIN IMMEDIATE');
    try {
      final storedFolderPaths = db
          .select('SELECT path FROM folders')
          .map((row) => row['path'] as String)
          .toSet();

      final playCountByPath = <String, int>{};
      final orphanCountsByMediaId = <String, List<int>>{};
      final orphanCountsByMetadataKey = <String, List<int>>{};
      final storedIdentities = <String, _StoredIdentity>{};
      final staleAudioPaths = <String>[];
      for (final row in db.select(
        'SELECT path, media_id, metadata_key, play_count, modified FROM audios',
      )) {
        final path = row['path'] as String;
        final pathKey = pathLookupKey(path);
        final playCount = row['play_count'] as int;
        playCountByPath.update(
          pathKey,
          (value) => value > playCount ? value : playCount,
          ifAbsent: () => playCount,
        );
        if (!currentAudioExactPaths.contains(path)) {
          staleAudioPaths.add(path);
        }
        if (!currentAudioKeys.contains(pathKey)) {
          final mediaId = row['media_id'] as String?;
          if (mediaId != null) {
            orphanCountsByMediaId.putIfAbsent(mediaId, () => []).add(playCount);
          }
          final metadataKey = row['metadata_key'] as String?;
          if (metadataKey != null) {
            orphanCountsByMetadataKey
                .putIfAbsent(metadataKey, () => [])
                .add(playCount);
          }
        }
        storedIdentities[path] = _StoredIdentity(
          mediaId: row['media_id'] as String?,
          metadataKey: row['metadata_key'] as String?,
          modified: _nonNegative(row['modified'] as int),
        );
      }
      final staleFolderPaths = storedFolderPaths
          .where((path) => !currentFolderPaths.contains(path))
          .toList(growable: false);

      final identities = <String, AudioIdentity>{};
      final currentMediaIdCounts = <String, int>{};
      final currentMetadataKeyCounts = <String, int>{};
      var reusedMediaIds = 0;
      var refreshedMediaIds = 0;
      for (final input in identityInputs) {
        final stored = storedIdentities[input.path];
        final String? mediaId;
        if (stored != null && stored.modified == input.modified) {
          reusedMediaIds++;
          mediaId = stored.mediaId;
        } else {
          refreshedMediaIds++;
          mediaId = stableFileId(input.path);
        }
        final identity = AudioIdentity(
          mediaId: mediaId,
          metadataKey: input.metadataKey,
        );
        if (mediaId != null) {
          currentMediaIdCounts.update(
            mediaId,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
        }
        currentMetadataKeyCounts.update(
          identity.metadataKey!,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        identities[input.pathKey] = identity;
      }

      var metaChanges = 0;
      metaChanges += _upsertMeta(db, 'version', '$version');
      if (signature != null) {
        metaChanges += _upsertMeta(
          db,
          'index_source_modified',
          '${signature.$1}',
        );
        metaChanges += _upsertMeta(db, 'index_source_size', '${signature.$2}');
      } else {
        db.execute(
          'DELETE FROM meta WHERE key IN '
          "('index_source_modified', 'index_source_size')",
        );
      }

      var folderChanges = 0;
      var audioChanges = 0;
      final folderStatement = db.prepare('''
INSERT INTO folders(path, modified, latest) VALUES(?1, ?2, ?3)
ON CONFLICT(path) DO UPDATE SET
  modified = excluded.modified,
  latest = excluded.latest
WHERE folders.modified IS NOT excluded.modified
   OR folders.latest IS NOT excluded.latest
''');
      final audioStatement = db.prepare('''
INSERT INTO audios(path, folder_path, title, artist, album, album_artist,
  track, disc, duration, bitrate, sample_rate, modified, created, by,
  play_count, media_id, metadata_key)
VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
ON CONFLICT(path) DO UPDATE SET
  folder_path = excluded.folder_path,
  title = excluded.title,
  artist = excluded.artist,
  album = excluded.album,
  album_artist = excluded.album_artist,
  track = excluded.track,
  disc = excluded.disc,
  duration = excluded.duration,
  bitrate = excluded.bitrate,
  sample_rate = excluded.sample_rate,
  modified = excluded.modified,
  created = excluded.created,
  by = excluded.by,
  play_count = excluded.play_count,
  media_id = excluded.media_id,
  metadata_key = excluded.metadata_key
WHERE audios.folder_path IS NOT excluded.folder_path
   OR audios.title IS NOT excluded.title
   OR audios.artist IS NOT excluded.artist
   OR audios.album IS NOT excluded.album
   OR audios.album_artist IS NOT excluded.album_artist
   OR audios.track IS NOT excluded.track
   OR audios.disc IS NOT excluded.disc
   OR audios.duration IS NOT excluded.duration
   OR audios.bitrate IS NOT excluded.bitrate
   OR audios.sample_rate IS NOT excluded.sample_rate
   OR audios.modified IS NOT excluded.modified
   OR audios.created IS NOT excluded.created
   OR audios.by IS NOT excluded.by
   OR audios.play_count IS NOT excluded.play_count
   OR audios.media_id IS NOT excluded.media_id
   OR audios.metadata_key IS NOT excluded.metadata_key
''');
      try {
        for (final folder in rawFolders) {
          final map = folder as Map;
          final folderPath = map['path'] as String;
          folderChanges += _executeCount(db, folderStatement, [
            folderPath,
            (map['modified'] as num?)?.toInt() ?? 0,
            (map['latest'] as num?)?.toInt() ?? 0,
          ]);
          for (final audio in (map['audios'] as List)) {
            final audioMap = audio as Map;
            final path = audioMap['path'] as String;
            final pathKey = pathLookupKey(path);
            final identity =
                identities[pathKey] ?? const AudioIdentity(metadataKey: '');
            final playCount = _resolvePlayCount(
              pathKey: pathKey,
              identity: identity,
              playCountByPath: playCountByPath,
              currentMediaIdCounts: currentMediaIdCounts,
              currentMetadataKeyCounts: currentMetadataKeyCounts,
              orphanCountsByMediaId: orphanCountsByMediaId,
              orphanCountsByMetadataKey: orphanCountsByMetadataKey,
            );
            audioChanges += _executeCount(db, audioStatement, [
              path,
              folderPath,
              audioMap['title'] as String? ?? '',
              audioMap['artist'] as String? ?? '',
              audioMap['album'] as String? ?? '',
              audioMap['album_artist'] as String?,
              (audioMap['track'] as num?)?.toInt() ?? 0,
              (audioMap['disc'] as num?)?.toInt() ?? 0,
              (audioMap['duration'] as num?)?.toInt() ?? 0,
              (audioMap['bitrate'] as num?)?.toInt(),
              (audioMap['sample_rate'] as num?)?.toInt(),
              (audioMap['modified'] as num?)?.toInt() ?? 0,
              (audioMap['created'] as num?)?.toInt() ?? 0,
              audioMap['by'] as String?,
              playCount,
              identity.mediaId,
              identity.metadataKey,
            ]);
          }
        }
      } finally {
        folderStatement.dispose();
        audioStatement.dispose();
      }

      var removedAudios = 0;
      final deleteAudio = db.prepare('DELETE FROM audios WHERE path = ?');
      try {
        for (final path in staleAudioPaths) {
          removedAudios += _executeCount(db, deleteAudio, [path]);
        }
      } finally {
        deleteAudio.dispose();
      }
      var removedFolders = 0;
      final deleteFolder = db.prepare('DELETE FROM folders WHERE path = ?');
      try {
        for (final path in staleFolderPaths) {
          removedFolders += _executeCount(db, deleteFolder, [path]);
        }
      } finally {
        deleteFolder.dispose();
      }
      db.execute(
        'DELETE FROM cover_thumbnails '
        'WHERE path NOT IN (SELECT path FROM audios)',
      );
      final removedCovers = db.updatedRows;
      db.execute('COMMIT');

      logger.i(
        '[perf] sqlite index sync audios=${currentAudioExactPaths.length} '
        'changed=$audioChanges removed=$removedAudios '
        'folders=${currentFolderPaths.length} changed=$folderChanges '
        'removed=$removedFolders meta=$metaChanges '
        'coversRemoved=$removedCovers '
        'mediaIdsReused=$reusedMediaIds '
        'mediaIdsRefreshed=$refreshedMediaIds '
        'elapsed=${stopwatch.elapsedMilliseconds}ms',
      );
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    try {
      db.execute('PRAGMA optimize;');
    } catch (_) {}
    return true;
  }

  /// 执行一条 prepared statement 并返回受影响行数（`execute` 本身返回 void）。
  int _executeCount(
    Database db,
    PreparedStatement statement,
    List<Object?> parameters,
  ) {
    statement.execute(parameters);
    return db.updatedRows;
  }

  int _upsertMeta(Database db, String key, String value) {
    db.execute(
      'INSERT INTO meta(key, value) VALUES(?1, ?2) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value '
      'WHERE meta.value IS NOT excluded.value',
      [key, value],
    );
    return db.updatedRows;
  }

  int _resolvePlayCount({
    required String pathKey,
    required AudioIdentity identity,
    required Map<String, int> playCountByPath,
    required Map<String, int> currentMediaIdCounts,
    required Map<String, int> currentMetadataKeyCounts,
    required Map<String, List<int>> orphanCountsByMediaId,
    required Map<String, List<int>> orphanCountsByMetadataKey,
  }) {
    final byPath = playCountByPath[pathKey];
    if (byPath != null) return byPath;
    final mediaId = identity.mediaId;
    if (mediaId != null && currentMediaIdCounts[mediaId] == 1) {
      final count = _uniquePlayCount(orphanCountsByMediaId, mediaId);
      if (count != null) return count;
    }
    final metadataKey = identity.metadataKey;
    if (metadataKey != null && currentMetadataKeyCounts[metadataKey] == 1) {
      final count = _uniquePlayCount(orphanCountsByMetadataKey, metadataKey);
      if (count != null) return count;
    }
    return 0;
  }

  int? _uniquePlayCount(Map<String, List<int>> candidates, String key) {
    final counts = candidates[key];
    if (counts == null || counts.length != 1) return null;
    return counts.first;
  }

  /// 封面缓存：命中直接返回 BLOB；未命中返回 `null`，由调用方解码后
  /// 再调 [writeCoverThumbnail]。
  Uint8List? readCoverThumbnail({
    required String path,
    required int width,
    required int height,
    required int sourceModified,
    required int sourceSize,
  }) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select(
      'SELECT png, last_accessed FROM cover_thumbnails '
      'WHERE path = ? AND width = ? AND height = ? '
      'AND source_modified = ? AND source_size = ?',
      [path, width, height, sourceModified, sourceSize],
    );
    if (rows.isEmpty) return null;
    final png = rows.first['png'] as Uint8List;
    final lastAccessed = rows.first['last_accessed'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - lastAccessed >= _coverAccessRefreshIntervalMs && isWritable) {
      db.execute(
        'UPDATE cover_thumbnails SET last_accessed = ? '
        'WHERE path = ? AND width = ? AND height = ?',
        [now, path, width, height],
      );
      _pruneCoverTier(db, width, height, _coverPruneReadBatch);
    }
    return png;
  }

  /// 写入（或刷新）一档封面缩略图，并按档位上限淘汰。
  void writeCoverThumbnail({
    required String path,
    required int width,
    required int height,
    required int sourceModified,
    required int sourceSize,
    required Uint8List png,
  }) {
    final db = _db;
    if (db == null || !isWritable) return;
    db.execute(
      'INSERT INTO cover_thumbnails('
      'path, width, height, source_modified, source_size, last_accessed, png'
      ') VALUES(?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(path, width, height) DO UPDATE SET '
      'source_modified = excluded.source_modified, '
      'source_size = excluded.source_size, '
      'last_accessed = excluded.last_accessed, '
      'png = excluded.png',
      [
        path,
        width,
        height,
        sourceModified,
        sourceSize,
        DateTime.now().millisecondsSinceEpoch,
        png,
      ],
    );
    _pruneCoverTier(db, width, height, _coverPruneWriteBatch);
  }

  void _pruneCoverTier(Database db, int width, int height, int batchSize) {
    final maxDimension = width > height ? width : height;
    final String condition;
    final int maxEntries;
    if (maxDimension <= _smallCoverMaxDimension) {
      condition =
          'width <= $_smallCoverMaxDimension '
          'AND height <= $_smallCoverMaxDimension';
      maxEntries = _maxPersistedSmallCovers;
    } else if (maxDimension <= _mediumCoverMaxDimension) {
      condition =
          '(width > $_smallCoverMaxDimension '
          'OR height > $_smallCoverMaxDimension) '
          'AND width <= $_mediumCoverMaxDimension '
          'AND height <= $_mediumCoverMaxDimension';
      maxEntries = _maxPersistedMediumCovers;
    } else {
      condition =
          'width > $_mediumCoverMaxDimension '
          'OR height > $_mediumCoverMaxDimension';
      maxEntries = _maxPersistedLargeCovers;
    }
    db.execute(
      'DELETE FROM cover_thumbnails WHERE rowid IN ('
      'SELECT rowid FROM cover_thumbnails WHERE $condition '
      'ORDER BY last_accessed DESC, rowid DESC LIMIT ? OFFSET ?'
      ')',
      [batchSize, maxEntries],
    );
    final deleted = db.updatedRows;
    if (deleted > 0) {
      try {
        db.execute('PRAGMA incremental_vacuum(32);');
      } catch (_) {}
    }
  }
}

/// 文件签名 `(modified 微秒, size)`；取不到时返回 `null`。
(int, int)? fileSourceSignature(String path) => _fileSourceSignature(path);

(int, int)? _fileSourceSignature(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    final stat = file.statSync();
    return (stat.modified.microsecondsSinceEpoch, stat.size);
  } catch (_) {
    return null;
  }
}

class _IdentityInput {
  const _IdentityInput({
    required this.path,
    required this.pathKey,
    required this.modified,
    required this.metadataKey,
  });

  final String path;
  final String pathKey;
  final int modified;
  final String metadataKey;
}

class _StoredIdentity {
  const _StoredIdentity({
    required this.mediaId,
    required this.metadataKey,
    required this.modified,
  });

  final String? mediaId;
  final String? metadataKey;
  final int modified;
}
