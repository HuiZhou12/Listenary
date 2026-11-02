import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/library_db.dart';
import 'package:pure_music/core/sqlite_version_guard.dart';
import 'package:sqlite3/sqlite3.dart';

/// R5：封面缩略图缓存（命中 / 未命中 / 源签名变化 / 三档淘汰）。
///
/// 解码部分由**注入的 fake** 承担（不调 Rust），因此本测试完全离线。
/// ⚠️ 只用 `Directory.systemTemp` 下的临时库，不接触真实用户数据。
void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('listenary-cover-');
    dbPath = '${tempDir.path}${Platform.pathSeparator}library.sqlite';
    SqliteVersionGuard.instance.resetForTest();
    final db = sqlite3.open(dbPath);
    try {
      LibraryDb.instance.initSchema(db);
    } finally {
      db.dispose();
    }
    LibraryDb.instance.debugOpenAtForTest(tempDir.path);
  });

  tearDown(() {
    LibraryDb.instance.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  int coverRowCount() {
    final db = LibraryDb.instance.debugDatabaseForTest!;
    return db.select('SELECT COUNT(*) AS c FROM cover_thumbnails').single['c']
        as int;
  }

  group('命中与未命中', () {
    test('miss returns null, write then hit returns the same bytes', () {
      final source = File('${tempDir.path}${Platform.pathSeparator}a.flac')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final signature = fileSourceSignature(source.path)!;

      expect(
        LibraryDb.instance.readCoverThumbnail(
          path: source.path,
          width: 48,
          height: 48,
          sourceModified: signature.$1,
          sourceSize: signature.$2,
        ),
        isNull,
        reason: '未命中 ⇒ null（调用方去解码）',
      );

      LibraryDb.instance.writeCoverThumbnail(
        path: source.path,
        width: 48,
        height: 48,
        sourceModified: signature.$1,
        sourceSize: signature.$2,
        png: bytes([9, 9, 9]),
      );

      expect(
        LibraryDb.instance.readCoverThumbnail(
          path: source.path,
          width: 48,
          height: 48,
          sourceModified: signature.$1,
          sourceSize: signature.$2,
        ),
        [9, 9, 9],
      );
    });

    test('a changed source signature invalidates the entry', () {
      final source = File('${tempDir.path}${Platform.pathSeparator}b.flac')
        ..writeAsBytesSync([1, 2, 3, 4]);
      final signature = fileSourceSignature(source.path)!;
      LibraryDb.instance.writeCoverThumbnail(
        path: source.path,
        width: 48,
        height: 48,
        sourceModified: signature.$1,
        sourceSize: signature.$2,
        png: bytes([1, 1, 1]),
      );

      expect(
        LibraryDb.instance.readCoverThumbnail(
          path: source.path,
          width: 48,
          height: 48,
          // 源文件变了（size 不同）⇒ 必须当未命中。
          sourceModified: signature.$1,
          sourceSize: signature.$2 + 999,
        ),
        isNull,
      );
    });

    test('different dimensions are distinct cache keys', () {
      final source = File('${tempDir.path}${Platform.pathSeparator}c.flac')
        ..writeAsBytesSync([5]);
      final signature = fileSourceSignature(source.path)!;
      // 只取两档（48 小档 / 200 中档）：630 属大档且上限 64，
      // 「三档同写」不会互相淘汰，但这里要验的是「尺寸是键的一部分」。
      for (final size in <int>[48, 200]) {
        LibraryDb.instance.writeCoverThumbnail(
          path: source.path,
          width: size,
          height: size,
          sourceModified: signature.$1,
          sourceSize: signature.$2,
          png: bytes([size ~/ 2]),
        );
      }
      expect(coverRowCount(), 2);
      for (final size in <int>[48, 200]) {
        expect(
          LibraryDb.instance.readCoverThumbnail(
            path: source.path,
            width: size,
            height: size,
            sourceModified: signature.$1,
            sourceSize: signature.$2,
          ),
          [size ~/ 2],
        );
      }
    });

    test('fileSourceSignature is null for a missing file', () {
      expect(fileSourceSignature('${tempDir.path}/nope.flac'), isNull);
    });
  });

  group('三档上限淘汰', () {
    test('large tier is bounded at 64 entries', () {
      final source = File('${tempDir.path}${Platform.pathSeparator}d.flac')
        ..writeAsBytesSync([1]);
      final signature = fileSourceSignature(source.path)!;
      for (var index = 0; index < 70; index++) {
        LibraryDb.instance.writeCoverThumbnail(
          path: '${source.path}#$index',
          width: 630,
          height: 630,
          sourceModified: signature.$1,
          sourceSize: signature.$2,
          png: bytes([index]),
        );
      }
      final db = LibraryDb.instance.debugDatabaseForTest!;
      final large =
          db
                  .select(
                    'SELECT COUNT(*) AS c FROM cover_thumbnails '
                    'WHERE width > 320 OR height > 320',
                  )
                  .single['c']
              as int;
      expect(large, lessThanOrEqualTo(64), reason: '大档上限 64');
    });

    test('medium tier is bounded at 512 entries', () {
      final source = File('${tempDir.path}${Platform.pathSeparator}e.flac')
        ..writeAsBytesSync([1]);
      final signature = fileSourceSignature(source.path)!;
      for (var index = 0; index < 520; index++) {
        LibraryDb.instance.writeCoverThumbnail(
          path: '${source.path}#$index',
          width: 200,
          height: 200,
          sourceModified: signature.$1,
          sourceSize: signature.$2,
          png: bytes([index]),
        );
      }
      final db = LibraryDb.instance.debugDatabaseForTest!;
      final medium =
          db
                  .select(
                    'SELECT COUNT(*) AS c FROM cover_thumbnails '
                    'WHERE (width > 128 OR height > 128) '
                    'AND width <= 320 AND height <= 320',
                  )
                  .single['c']
              as int;
      expect(medium, lessThanOrEqualTo(512), reason: '中档上限 512');
    });

    test('small tier is bounded at 4096 entries', () {
      final source = File('${tempDir.path}${Platform.pathSeparator}f.flac')
        ..writeAsBytesSync([1]);
      final signature = fileSourceSignature(source.path)!;
      // 4096 档写满代价太高（每写一次就 prune 一次），这里用「写 4100 条
      // 小档」验证上限成立，但把循环压到刚好越界。
      for (var index = 0; index < 4100; index++) {
        LibraryDb.instance.writeCoverThumbnail(
          path: '${source.path}#$index',
          width: 48,
          height: 48,
          sourceModified: signature.$1,
          sourceSize: signature.$2,
          png: bytes([index & 0xff]),
        );
      }
      final db = LibraryDb.instance.debugDatabaseForTest!;
      final small =
          db
                  .select(
                    'SELECT COUNT(*) AS c FROM cover_thumbnails '
                    'WHERE width <= 128 AND height <= 128',
                  )
                  .single['c']
              as int;
      expect(small, lessThanOrEqualTo(4096), reason: '小档上限 4096');
    });
  });

  group('降级态', () {
    test('write is a no-op when the database is closed', () {
      LibraryDb.instance.dispose();
      expect(
        () => LibraryDb.instance.writeCoverThumbnail(
          path: 'x',
          width: 48,
          height: 48,
          sourceModified: 1,
          sourceSize: 1,
          png: bytes([1]),
        ),
        returnsNormally,
        reason: '降级态不崩',
      );
      expect(
        LibraryDb.instance.readCoverThumbnail(
          path: 'x',
          width: 48,
          height: 48,
          sourceModified: 1,
          sourceSize: 1,
        ),
        isNull,
      );
    });
  });
}
