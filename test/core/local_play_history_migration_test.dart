import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/library_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// R6 / R7：`play_count` 历史数据迁移与双层验证（Spec §5.2）。
///
/// 两层口径：
/// - **行级（强一致）**：源侧与目标侧 `(path, play_count)` 全集 sha256 相同，
///   `COUNT(*)` 与 `SUM(play_count)` 相同；
/// - **文件级（不回归）**：迁移**只读**源库 —— 前后 `size` 与
///   `page_count * page_size` 相等。
///
/// ⚠️ 源库是**测试内造的 Rust 格式 fixture**（临时目录），不打开任何真实
/// 用户数据库文件（Spec §3.3 / 红线）。
void main() {
  late Directory tempDir;
  late String sourcePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('listenary-playimport-');
    sourcePath = '${tempDir.path}${Platform.pathSeparator}library.sqlite';
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 造一个 Rust 格式的 `library.sqlite`，带给定 `(path, play_count)` 行。
  void seedSource(Map<String, int> counts) {
    final db = sqlite3.open(sourcePath);
    try {
      db.execute('''
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE folders (
  path TEXT PRIMARY KEY,
  modified INTEGER NOT NULL,
  latest INTEGER NOT NULL
);
CREATE TABLE audios (
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
CREATE TABLE cover_thumbnails (
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
      db.execute(
        "INSERT INTO meta(key, value) VALUES('database_layout_version', '2')",
      );
      db.execute(
        "INSERT INTO meta(key, value) VALUES('identity_backfill_v1', '1')",
      );
      db.execute("INSERT INTO meta(key, value) VALUES('version', '111')");
      db.execute(
        "INSERT INTO folders(path, modified, latest) VALUES('C:/M', 1, 2)",
      );
      final insert = db.prepare(
        'INSERT INTO audios(path, folder_path, title, artist, album, duration, '
        'modified, created, play_count) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)',
      );
      try {
        for (final entry in counts.entries) {
          insert.execute([
            entry.key,
            'C:/M',
            'T',
            'A',
            'B',
            180,
            4,
            5,
            entry.value,
          ]);
        }
      } finally {
        insert.dispose();
      }
    } finally {
      db.dispose();
    }
  }

  /// 源库的 `(path, play_count)` 全集（只读）。
  List<({String path, int playCount})> readSourceCounts() {
    final db = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
    try {
      return db
          .select(
            'SELECT path, play_count FROM audios WHERE play_count > 0 '
            'ORDER BY path',
          )
          .map(
            (row) => (
              path: row['path'] as String,
              playCount: row['play_count'] as int,
            ),
          )
          .toList(growable: false);
    } finally {
      db.dispose();
    }
  }

  List<({String path, int playCount})> readTargetCounts(Database db) => db
      .select('SELECT path, play_count FROM local_play_history ORDER BY path')
      .map(
        (row) =>
            (path: row['path'] as String, playCount: row['play_count'] as int),
      )
      .toList(growable: false);

  String? metaValue(Database db, String key) {
    final rows = db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// 文件级指纹：`size` 与 `page_count * page_size`。
  (int, int) fileFingerprint(String path) {
    final file = File(path);
    final size = file.lengthSync();
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final pageCount =
          db.select('PRAGMA page_count').first.values.first as int;
      final pageSize = db.select('PRAGMA page_size').first.values.first as int;
      return (size, pageCount * pageSize);
    } finally {
      db.dispose();
    }
  }

  Database freshAppDb() => sqlite3.openInMemory();

  group('R6 双层验证', () {
    test('row-level digest matches the source exactly', () {
      seedSource({'C:/M/a.flac': 3, 'C:/M/b.flac': 1, 'C:/M/zero.flac': 0});

      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);

        final source = readSourceCounts();
        expect(source.length, 2, reason: '只有 play_count > 0 的行被读');
        final target = readTargetCounts(app);
        expect(target, source, reason: '行级逐条相等');
        expect(
          playHistoryDigest(target),
          playHistoryDigest(source),
          reason: '行级 sha256 摘要强一致',
        );
        expect(target.length, source.length);
        expect(
          target.fold<int>(0, (sum, row) => sum + row.playCount),
          source.fold<int>(0, (sum, row) => sum + row.playCount),
          reason: 'SUM(play_count) 相同',
        );
        expect(metaValue(app, localPlayImportKey), '1');
        expect(metaValue(app, 'local_play_import_rows'), '2');
        expect(metaValue(app, 'local_play_import_sum'), '4');
        expect(
          metaValue(app, 'local_play_import_digest'),
          playHistoryDigest(source),
        );
      } finally {
        app.dispose();
      }
    });

    test('source file is never written (file-level no-regression)', () {
      seedSource({'C:/M/a.flac': 5, 'C:/M/b.flac': 2});
      final before = fileFingerprint(sourcePath);
      final beforeBytes = File(sourcePath).readAsBytesSync();

      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(metaValue(app, localPlayImportKey), '1');
      } finally {
        app.dispose();
      }

      final after = fileFingerprint(sourcePath);
      expect(after.$1, before.$1, reason: '源库文件 size 不变');
      expect(after.$2, before.$2, reason: 'page_count*page_size 不变');
      expect(
        File(sourcePath).readAsBytesSync(),
        beforeBytes,
        reason: '源库一个字节都没被写（只读连接）',
      );
    });

    test('no -wal is created by this import', () {
      seedSource({'C:/M/a.flac': 1});
      final walPath = '$sourcePath-wal';
      // 先把 fixture 的 WAL 收干净，再断言导入不新增。
      final cleanup = sqlite3.open(sourcePath);
      cleanup.execute('PRAGMA journal_mode = DELETE;');
      cleanup.dispose();
      expect(File(walPath).existsSync(), isFalse);

      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
      } finally {
        app.dispose();
      }
      expect(File(walPath).existsSync(), isFalse, reason: '只读连接不得创建 -wal');
    });
  });

  group('R7 幂等与三类未执行态', () {
    test('re-running the import does not double count', () {
      seedSource({'C:/M/a.flac': 3});
      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(readTargetCounts(app).single.playCount, 3);

        // 再次打开同一个库：已导入 ⇒ 跳过，不重复累加。
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(readTargetCounts(app).single.playCount, 3);
      } finally {
        app.dispose();
      }
    });

    test('import does not overwrite counts produced after the switch', () {
      seedSource({'C:/M/a.flac': 3});
      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        // 用户切换后新产生的计数。
        app.execute(
          "UPDATE local_play_history SET play_count = 99 WHERE path = 'C:/M/a.flac'",
        );
        // 删掉标记，强制重跑导入。
        app.execute('DELETE FROM meta WHERE key = ?', [localPlayImportKey]);
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(
          readTargetCounts(app).single.playCount,
          99,
          reason: 'ON CONFLICT DO NOTHING ⇒ 绝不覆盖新计数',
        );
      } finally {
        app.dispose();
      }
    });

    test('skipped-no-source: v7 commits, count starts at 0, no throw', () {
      final app = freshAppDb();
      try {
        // 源库不存在。
        initializeAppDatabase(
          app,
          localPlaySourcePath:
              '${tempDir.path}${Platform.pathSeparator}missing.sqlite',
        );
        expect(
          app.select('PRAGMA user_version').first['user_version'],
          latestAppDatabaseVersion,
        );
        expect(readTargetCounts(app), isEmpty);
        expect(metaValue(app, localPlayImportKey), 'skipped-no-source');
      } finally {
        app.dispose();
      }
    });

    test('deferred when the read-only open fails', () {
      // 用**排他文件锁**让只读打开真的失败（真实场景是 WAL 无 -shm /
      // 文件被占用）。锁住后 `sqlite3.open(..., readOnly)` 抛
      // `SqliteException(10) disk I/O error` ⇒ 走 deferred 分支。
      seedSource({'C:/M/a.flac': 7});
      final lock = File(sourcePath).openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(
          app.select('PRAGMA user_version').first['user_version'],
          latestAppDatabaseVersion,
          reason: '未执行导入也必须正常提交 v7',
        );
        expect(readTargetCounts(app), isEmpty, reason: '计数从 0 起步，不伪造历史');
        expect(metaValue(app, localPlayImportKey), 'deferred');
      } finally {
        app.dispose();
        try {
          lock.unlockSync();
        } catch (_) {}
        lock.closeSync();
      }
    });

    test('failed when the read itself throws', () {
      // 一个合法的 SQLite 文件，但没有 audios 表 ⇒ 读取中途抛错。
      final emptyDb =
          '${tempDir.path}${Platform.pathSeparator}no-audios.sqlite';
      final db = sqlite3.open(emptyDb);
      try {
        db.execute(
          'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      } finally {
        db.dispose();
      }
      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: emptyDb);
        expect(
          app.select('PRAGMA user_version').first['user_version'],
          latestAppDatabaseVersion,
        );
        expect(readTargetCounts(app), isEmpty);
        expect(metaValue(app, localPlayImportKey), 'failed');
      } finally {
        app.dispose();
      }
    });

    test('source present but all counts zero imports nothing', () {
      seedSource({'C:/M/a.flac': 0, 'C:/M/b.flac': 0});
      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(readTargetCounts(app), isEmpty);
        expect(metaValue(app, localPlayImportKey), '1');
        expect(metaValue(app, 'local_play_import_rows'), '0');
        expect(metaValue(app, 'local_play_import_sum'), '0');
      } finally {
        app.dispose();
      }
    });
  });

  group('§4.3 deferred 补跑', () {
    /// 造一个「首次只能 deferred」的状态：先锁住源库跑一次迁移，再解锁。
    Database seedDeferredState(Map<String, int> counts) {
      seedSource(counts);
      final lock = File(sourcePath).openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(metaValue(app, localPlayImportKey), 'deferred');
        expect(readTargetCounts(app), isEmpty);
      } finally {
        try {
          lock.unlockSync();
        } catch (_) {}
        lock.closeSync();
      }
      return app;
    }

    test('deferred → resume → "1" with row-level digest equality', () async {
      final app = seedDeferredState({'C:/M/a.flac': 4, 'C:/M/b.flac': 2});

      // checkpoint 之后源库已可读 ⇒ 补跑。
      final resumed = await resumeDeferredLocalPlayImport(
        sourcePath: sourcePath,
        database: app,
      );
      expect(resumed, isTrue, reason: '补跑成功必须返回 true');
      expect(metaValue(app, localPlayImportKey), '1', reason: '标记改成 "1"');
      expect(metaValue(app, 'local_play_import_rows'), '2');
      expect(metaValue(app, 'local_play_import_sum'), '6');

      final source = readSourceCounts();
      final target = readTargetCounts(app);
      expect(target, source, reason: '补跑与首次共用同一段代码 ⇒ 行级逐条相等');
      expect(
        playHistoryDigest(target),
        playHistoryDigest(source),
        reason: '行级 sha256 摘要强一致',
      );
      expect(
        metaValue(app, 'local_play_import_digest'),
        playHistoryDigest(source),
      );
      app.dispose();
    });

    test('resume is a no-op when the state is already "1"', () async {
      seedSource({'C:/M/a.flac': 3});
      final app = freshAppDb();
      try {
        initializeAppDatabase(app, localPlaySourcePath: sourcePath);
        expect(metaValue(app, localPlayImportKey), '1');
        final resumed = await resumeDeferredLocalPlayImport(
          sourcePath: sourcePath,
          database: app,
        );
        expect(resumed, isFalse, reason: '已成功不再补跑');
        expect(readTargetCounts(app).single.playCount, 3, reason: '不重复累加');
      } finally {
        app.dispose();
      }
    });

    test('resume does not touch skipped-no-source or failed', () async {
      // skipped-no-source：源库不存在。
      final skipped = freshAppDb();
      try {
        initializeAppDatabase(
          skipped,
          localPlaySourcePath:
              '${tempDir.path}${Platform.pathSeparator}nope.sqlite',
        );
        expect(metaValue(skipped, localPlayImportKey), 'skipped-no-source');
        final resumed = await resumeDeferredLocalPlayImport(
          sourcePath: sourcePath,
          database: skipped,
        );
        expect(resumed, isFalse, reason: 'skipped-no-source 不自动重试');
        expect(
          metaValue(skipped, localPlayImportKey),
          'skipped-no-source',
          reason: '标记保持不变，等用户干预',
        );
      } finally {
        skipped.dispose();
      }

      // failed：源库存在但读不了（无 audios 表）。
      final emptyDb =
          '${tempDir.path}${Platform.pathSeparator}no-audios2.sqlite';
      final raw = sqlite3.open(emptyDb);
      try {
        raw.execute(
          'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      } finally {
        raw.dispose();
      }
      final failed = freshAppDb();
      try {
        initializeAppDatabase(failed, localPlaySourcePath: emptyDb);
        expect(metaValue(failed, localPlayImportKey), 'failed');
        final resumed = await resumeDeferredLocalPlayImport(
          sourcePath: sourcePath,
          database: failed,
        );
        expect(resumed, isFalse, reason: 'failed 不自动重试');
        expect(metaValue(failed, localPlayImportKey), 'failed');
      } finally {
        failed.dispose();
      }
    });

    test('resume keeps deferred when the source is still unreadable', () async {
      final app = seedDeferredState({'C:/M/a.flac': 2});
      final lock = File(sourcePath).openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      try {
        final resumed = await resumeDeferredLocalPlayImport(
          sourcePath: sourcePath,
          database: app,
        );
        expect(resumed, isFalse);
        expect(
          metaValue(app, localPlayImportKey),
          'deferred',
          reason: '仍然读不了 ⇒ 保留 deferred，下次启动再试',
        );
        expect(readTargetCounts(app), isEmpty);
      } finally {
        try {
          lock.unlockSync();
        } catch (_) {}
        lock.closeSync();
        app.dispose();
      }
    });

    test('LibraryDb hook drives the resume end to end', () async {
      // 走真实接线：LibraryDb 成为写者 + checkpoint 后调用注册的钩子。
      final app = seedDeferredState({'C:/M/a.flac': 5});
      LibraryDb.instance.dispose();
      LibraryDb.instance.debugOpenAtForTest(tempDir.path);
      LibraryDb.instance.deferredPlayImportHook = (indexDir) =>
          resumeDeferredLocalPlayImport(
            sourcePath: LibraryDb.databasePathFor(indexDir),
            database: app,
          );
      try {
        await LibraryDb.instance.resumeDeferredPlayImportForTest(tempDir.path);
        expect(metaValue(app, localPlayImportKey), '1');
        expect(readTargetCounts(app).single.playCount, 5);
      } finally {
        LibraryDb.instance.deferredPlayImportHook = null;
        LibraryDb.instance.dispose();
        app.dispose();
      }
    });
  });

  group('R7 写入失败回滚', () {
    test(
      'write failure rolls back: user_version stays 6, no local_play_history',
      () {
        seedSource({'C:/M/a.flac': 1});
        final app = freshAppDb();
        try {
          // 造一个 v6 库：没有 local_play_history，且用一个同名的**视图**占住
          // 表名，让 v7 的 CREATE TABLE 必然失败 ⇒ 事务 ROLLBACK。
          _createVersion6Database(app);
          app.execute(
            'CREATE VIEW local_play_history AS SELECT 1 AS path, 0 AS play_count',
          );
          expect(app.select('PRAGMA user_version').first['user_version'], 6);

          expect(
            () => initializeAppDatabase(app, localPlaySourcePath: sourcePath),
            throwsA(isA<SqliteException>()),
            reason: '建表失败必须上抛（由 AppDb 决定是否降级）',
          );

          expect(
            app.select('PRAGMA user_version').first['user_version'],
            6,
            reason: '事务回滚 ⇒ user_version 停在 6',
          );
          expect(
            app
                .select(
                  'SELECT COUNT(*) AS c FROM sqlite_master '
                  "WHERE type='table' AND name='local_play_history'",
                )
                .single['c'],
            0,
            reason: '回滚后不得留下 local_play_history 表',
          );
          expect(
            metaValue(app, localPlayImportKey),
            isNull,
            reason: '导入标记也不得留下',
          );
        } finally {
          app.dispose();
        }
      },
    );
  });

  group('v7 schema', () {
    test('local_play_history exists with the documented shape and CHECK', () {
      final app = freshAppDb();
      try {
        initializeAppDatabase(app);
        final columns = app
            .select('PRAGMA table_info(local_play_history)')
            .map((row) => row['name'] as String)
            .toSet();
        expect(columns, {'path', 'play_count', 'last_played_at'});
        expect(
          app.select('PRAGMA user_version').first['user_version'],
          latestAppDatabaseVersion,
        );
        expect(latestAppDatabaseVersion, 7);
        // CHECK(play_count >= 0) 必须真的能拒绝负值（行为断言）。
        expect(
          () => app.execute(
            'INSERT INTO local_play_history(path, play_count) '
            "VALUES('C:/x.flac', -1)",
          ),
          throwsA(isA<SqliteException>()),
        );
        app.execute(
          "INSERT INTO local_play_history(path, play_count) VALUES('C:/x.flac', 0)",
        );
      } finally {
        app.dispose();
      }
    });

    test('v7 migration is idempotent', () {
      final app = freshAppDb();
      try {
        initializeAppDatabase(app);
        initializeAppDatabase(app);
        expect(
          app
              .select(
                'SELECT COUNT(*) AS c FROM sqlite_master '
                "WHERE type='table' AND name='local_play_history'",
              )
              .single['c'],
          1,
        );
      } finally {
        app.dispose();
      }
    });
  });
}

/// 造一个 v6 库：只有应用库的基础表，没有 v7 的 `local_play_history`。
void _createVersion6Database(Database db) {
  db.execute('''
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE playlists (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  cover_source TEXT
);
CREATE TABLE playlist_items (
  playlist_id INTEGER NOT NULL,
  path TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  added_at TEXT,
  PRIMARY KEY (playlist_id, path)
);
CREATE TABLE online_tracks (
  platform TEXT NOT NULL,
  track_id TEXT NOT NULL,
  title TEXT NOT NULL,
  album TEXT NOT NULL DEFAULT '',
  album_id TEXT,
  cover_uri TEXT,
  duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(duration_ms >= 0),
  availability TEXT NOT NULL DEFAULT 'unknown',
  last_quality TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (platform, track_id)
);
PRAGMA user_version = 6;
''');
}
