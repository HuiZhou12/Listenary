import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:sqlite3/sqlite3.dart';

/// F5（决策 A / L）：在**真实临时文件数据库**（不是内存库）上验证迁移与回滚。
///
/// 为什么单独做一遍：内存库与文件库在 `journal_mode = WAL`、重复打开、事务持久化上并不等价；
/// 授权要求"在隔离的临时环境完成迁移与回滚验证"。
///
/// ⚠️ 全程只用 `Directory.systemTemp` 下的临时目录，**不接触任何真实用户数据库**；每个用例结束即删除。
void main() {
  late Directory tempDir;
  late String databasePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('listenary-f5-migration-');
    databasePath = '${tempDir.path}${Platform.pathSeparator}app.sqlite';
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('★ F5（P-43/L）文件库：v4→v5、重复打开、版本落后（表已存在）都不丢数据', () {
    // 1) 造一个 v4 文件库（与内存库用例同一形态）。
    var database = sqlite3.open(databasePath);
    _createVersion4Database(database);
    database.dispose();

    // 2) v4 → v5（真实文件）。
    database = sqlite3.open(databasePath);
    initializeAppDatabase(database);
    expect(_userVersion(database), latestAppDatabaseVersion);
    expect(_onlineTableCount(database), 5);

    // 3) 重复打开（同一条真实文件路径）。
    database.dispose();
    database = sqlite3.open(databasePath);
    initializeAppDatabase(database);
    expect(_userVersion(database), latestAppDatabaseVersion);
    expect(_onlineTableCount(database), 5);
    expect(
      database.select('SELECT name FROM playlists').single['name'],
      'Local',
      reason: '既有数据必须还在',
    );

    // 4) 版本落后但表已存在（审计里的"半迁移"形态）⇒ 幂等升级 + 数据不丢。
    database.execute('INSERT INTO online_tracks('
        'platform, track_id, title, created_at, updated_at) '
        "VALUES('netease', 't1', '文件库既有曲目', "
        "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')");
    database.execute('PRAGMA user_version = 4');
    initializeAppDatabase(database);

    expect(_userVersion(database), latestAppDatabaseVersion);
    expect(
      database
          .select("SELECT title FROM online_tracks WHERE track_id = 't1'")
          .single['title'],
      '文件库既有曲目',
      reason: '幂等升级不得清掉既有行',
    );
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    database.dispose();

    // 5) WAL 副作用文件确实落在临时目录内（证明我们操作的是这个临时库）。
    expect(
      Directory(tempDir.path).listSync().isNotEmpty,
      isTrue,
    );
  });

  test('★ F5（P-43/L）文件库：结构不符 ⇒ 明确失败、版本不推进、原库内容不被改写', () {
    var database = sqlite3.open(databasePath);
    _createVersion4Database(database);
    // 结构错误的在线表（模拟早期错误形态 / 被外部改过 / 损坏）。
    database.execute('CREATE TABLE online_tracks (platform TEXT, track_id TEXT)');
    database.dispose();

    database = sqlite3.open(databasePath);
    expect(
      () => initializeAppDatabase(database),
      throwsA(isA<StateError>()),
      reason: '幂等不得把"结构不对"伪装成"迁移成功"',
    );

    expect(_userVersion(database), 4, reason: '版本号不推进');
    expect(
      _onlineTableCount(database),
      1,
      reason: '只保留那张错表（其它在线表不得被建出来）',
    );
    expect(
      database.select('PRAGMA table_info(online_tracks)').length,
      2,
      reason: '错表结构原样保留（本片不修复）',
    );
    expect(
      database.select('SELECT name FROM playlists').single['name'],
      'Local',
      reason: 'v4 的既有数据不受影响',
    );
    database.dispose();
  });
}

void _createVersion4Database(Database database) {
  database.execute('''
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
INSERT INTO playlists(name, cover_source) VALUES('Local', NULL);
PRAGMA user_version = 4;
''');
}

int _userVersion(Database database) =>
    database.select('PRAGMA user_version').single['user_version'] as int;

int _onlineTableCount(Database database) =>
    database
        .select(
          'SELECT COUNT(*) AS c FROM sqlite_master '
          "WHERE type = 'table' AND name LIKE 'online_%'",
        )
        .single['c']
        as int;
