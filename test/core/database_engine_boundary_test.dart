import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「双 SQLite 引擎」（3.5）的**归属边界守卫**。
///
/// 现状（3.5-b 完成后的引擎归属，本节即权威说明）：
/// - Dart `sqlite3` 打开 `<appData>/db/app.sqlite`（在线/歌单/歌词/取色 + 本地播放历史）
///   与 `<appData>/library.sqlite`（曲库索引 + 封面缩略图）；
/// - **Rust 进程内不再有任何 SQLite 依赖**（`rusqlite` 已从 `Cargo.toml` 移除），
///   因此不得出现 `library.sqlite` / `app.sqlite` 的任何引用。
///
/// 语义相对 3.5-c 的反转：那次锁的是「Dart 不得碰 library.sqlite」，本包把
/// 曲库库整体交还 Dart 之后，守卫方向变成「**Rust 不得碰**」。表级交叉断言
/// （谁给谁建表）保留 —— 只把「Rust 拥有 folders/audios」改成「Dart 拥有」。
///
/// 本测试只读源码文本，**不打开任何数据库连接**，也不读写任何真实用户数据文件。
void main() {
  // ─────────────────────────────────────────────────────────────────────────
  // 词法工具：剥注释后再匹配
  //
  // 只剥离行注释（含 `///`、`//!` 与块注释的 `*` 续行）——本任务只关心
  // 「代码里是否出现某个字面量」，不解析字符串，避免把注释里的解释性提及
  // 误判成真实引用。这与 `test/lyric/lyric_source_mapping_test.dart:495-502`
  // 的 codeOnly 口径一致。
  // ─────────────────────────────────────────────────────────────────────────

  /// 去掉行注释与块注释后保留代码行。
  ///
  /// **保留行数**：被剥掉的行以空串占位，这样后续报出的行号与源文件一致
  /// （否则白名单里的 `文件:行号` 会错位，且失败信息无法直接定位）。
  String codeOnly(String source) {
    final buffer = StringBuffer();
    var inBlockComment = false;
    for (final line in source.split('\n')) {
      final trimmed = line.trimLeft();
      if (inBlockComment) {
        final end = trimmed.indexOf('*/');
        if (end == -1) {
          buffer.writeln();
          continue;
        }
        inBlockComment = false;
        buffer.writeln(trimmed.substring(end + 2));
        continue;
      }
      if (trimmed.startsWith('/*')) {
        final end = trimmed.indexOf('*/');
        if (end == -1) {
          inBlockComment = true;
          buffer.writeln();
          continue;
        }
        buffer.writeln(trimmed.substring(end + 2));
        continue;
      }
      if (trimmed.startsWith('//') || trimmed.startsWith('*')) {
        buffer.writeln();
        continue;
      }
      buffer.writeln(line);
    }
    return buffer.toString();
  }

  /// 仓库内全部 Dart 源文件（相对路径用 `/` 归一，便于稳定断言）。
  List<File> dartFilesUnder(String root) => Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList(growable: false);

  /// 仓库内全部 Rust 源文件。
  List<File> rustFilesUnder(String root) => Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.rs'))
      .toList(growable: false);

  String normalized(FileSystemEntity entity) =>
      entity.path.replaceAll(r'\', '/');

  /// 收集 `root` 下出现 [pattern] 的位置，返回 `相对路径:行号` 清单。
  List<String> hitsFor(
    String root,
    RegExp pattern, {
    bool stripComments = true,
  }) {
    final hits = <String>[];
    for (final file in dartFilesUnder(root)) {
      final source = stripComments
          ? codeOnly(file.readAsStringSync())
          : file.readAsStringSync();
      final lines = source.split('\n');
      for (var index = 0; index < lines.length; index++) {
        if (pattern.hasMatch(lines[index])) {
          hits.add('${normalized(file)}:${index + 1}');
        }
      }
    }
    return hits;
  }

  /// Rust 侧的同一套扫描（Rust 行注释同样是 `//`）。
  List<String> rustHitsFor(String root, RegExp pattern) {
    final hits = <String>[];
    for (final file in rustFilesUnder(root)) {
      final lines = codeOnly(file.readAsStringSync()).split('\n');
      for (var index = 0; index < lines.length; index++) {
        if (pattern.hasMatch(lines[index])) {
          hits.add('${normalized(file)}:${index + 1}');
        }
      }
    }
    return hits;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // a) Rust 侧不得引用 library.sqlite / app.sqlite
  //
  // 这是 3.5-c 守卫的**方向反转**：当时是「Dart 不得引用 library.sqlite」，
  // 现在曲库库归 Dart，反向约束落在 Rust 上。Spec §2-1 的目标是「Rust 进程内
  // 不再存在任何 SQLite 依赖」，这条断言直接锁住该目标的可观察后果。
  // ─────────────────────────────────────────────────────────────────────────

  test('Rust sources never reference library.sqlite or app.sqlite', () {
    final hits = rustHitsFor(
      'rust/src',
      RegExp(r'library\.sqlite|app\.sqlite'),
    );
    expect(
      hits,
      isEmpty,
      reason:
          'Rust 侧出现了 SQLite 库文件引用。3.5-b 之后 Rust 不再拥有任何数据库：\n'
          '${hits.join('\n')}',
    );
  });

  test('Rust sources carry no rusqlite dependency or SQLite API surface', () {
    // R1 的静态面：依赖不在了，API 表面对应也不该出现。`Connection::open`
    // 这种形态即使误加回依赖也会被这条抓住。
    final hits = rustHitsFor(
      'rust/src',
      RegExp(r'rusqlite|libsqlite3|Connection::open|TransactionBehavior'),
    );
    expect(
      hits,
      isEmpty,
      reason:
          'Rust 侧出现了 SQLite 依赖/API。依赖图里 `rusqlite` 已移除，源码不得复活它：\n'
          '${hits.join('\n')}',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // b) Dart 侧的曲库库引用必须收敛在单一 owner 文件里
  //
  // 「原地接管」要求 Dart 直接开现有文件，因此 `library.sqlite` 会出现在代码里。
  // 但 owner 必须**唯一**：只有 `lib/core/library_db.dart` 可以拼这个文件名
  // 或打开它，其他 lib 文件一律走仓储 API。这条替代了原来的「一处 stat 豁免」。
  // ─────────────────────────────────────────────────────────────────────────

  const libraryDbOwner = 'lib/core/library_db.dart';

  test('only the LibraryDb owner file names library.sqlite', () {
    final hits = hitsFor('lib', RegExp(r'library\.sqlite'));
    final unexpected = hits
        .where((hit) => !hit.startsWith('$libraryDbOwner:'))
        .toList(growable: false);
    expect(
      unexpected,
      isEmpty,
      reason:
          '曲库库的 owner 必须是唯一的 `$libraryDbOwner`；其他 lib 文件只能经\n'
          '`LibraryDb` 仓储访问，不得自己拼文件名或开连接：\n'
          '${unexpected.join('\n')}',
    );
    expect(
      hits,
      isNotEmpty,
      reason: '所有权文件本身必须真的引用 `library.sqlite`，否则本断言是在空转。',
    );
  });

  test('Dart sources name the app database exactly once as an open path', () {
    // 反向守卫：Dart 侧必须仍然只指向 `app.sqlite`，防止「统一引擎」时
    // 顺手改文件名而无人发现。`database.dart` 的打开点是唯一真源。
    //
    // 断言「文件唯一」而不是「文件:行号」：行号会随着该文件的无关键改动漂移，
    // 钉行号只会逼人为了变绿去改基线数字。
    final hits = hitsFor('lib', RegExp(r"'app\.sqlite'"));
    expect(hits, isNotEmpty, reason: 'app.sqlite 的打开路径必须存在（否则本断言是空转）');
    expect(
      hits.map((hit) => hit.split(':').first).toSet(),
      {'lib/core/database.dart'},
      reason:
          'app.sqlite 的打开路径应当只在 lib/core/database.dart 一处。'
          '新增打开点必须先更新引擎归属文档。实际：\n${hits.join('\n')}',
    );
    expect(
      hits.length,
      1,
      reason: '同一文件里也只允许出现一次 app.sqlite 字面量。实际：\n${hits.join('\n')}',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // c) 两侧都不得创建对方的表
  //
  // 3.5-b 之后 `folders`/`audios`/`cover_thumbnails` 归 **Dart**（LibraryDb），
  // Rust 一张表都不再有。因此：
  // - Rust 侧任何 `CREATE TABLE` 都是越界（它已无数据库）；
  // - Dart 侧建这三张表是**允许**的，但只允许在 LibraryDb owner 里。
  // ─────────────────────────────────────────────────────────────────────────

  /// `meta` 是两侧**曾经同名但不同库**的表；现在只剩 Dart 侧一份。
  const libraryTables = r'folders|audios|cover_thumbnails';

  test('Rust never issues any DDL at all', () {
    final hits = rustHitsFor(
      'rust/src',
      RegExp(r'CREATE\s+TABLE', caseSensitive: false),
    );
    expect(
      hits,
      isEmpty,
      reason:
          'Rust 侧出现了建表语句。Rust 已无任何数据库连接，DDL 全部归 Dart：\n'
          '${hits.join('\n')}',
    );
  });

  test('Dart issues library DDL only from the LibraryDb owner', () {
    final hits = hitsFor(
      'lib',
      RegExp(
        'CREATE\\s+(?:TEMP\\s+|TEMPORARY\\s+)?TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?'
        '(?:$libraryTables)\\b',
        caseSensitive: false,
      ),
    );
    final unexpected = hits
        .where((hit) => !hit.startsWith('$libraryDbOwner:'))
        .toList(growable: false);
    expect(
      unexpected,
      isEmpty,
      reason:
          '曲库表的 schema owner 是 `$libraryDbOwner`；其他文件不得建这些表：\n'
          '${unexpected.join('\n')}',
    );
    expect(
      hits,
      isNotEmpty,
      reason: 'LibraryDb 必须真的持有曲库表 DDL，否则前面的 owner 断言是空转。',
    );
  });

  test('each persistence surface is non-empty (no silent all-clear)', () {
    // 正向自检：断言两侧确实都能被扫到，避免「两边都扫不到」造成假绿。
    final dartDdl = hitsFor(
      'lib',
      RegExp(r'CREATE\s+TABLE', caseSensitive: false),
    );
    expect(dartDdl, isNotEmpty, reason: 'Dart 侧应当有建表语句（两库 schema）');
    expect(
      rustFilesUnder('rust/src'),
      isNotEmpty,
      reason: 'Rust 侧源码扫描面不得为空（否则 a/b 组会假绿）',
    );
  });

  // ─────────────────────────────────────────────────────────────────────────
  // d) 变异负控：扫描器本身必须能检出违规样本
  //
  // 与 3.1 边界测试的 fixture 测试同风格：把「未来可能出现的违规写法」直接喂给
  // 匹配器，证明断言不是空转。这些字符串只存在于测试内，不写入任何源码。
  // ─────────────────────────────────────────────────────────────────────────

  group('mutation negative controls', () {
    final libraryDdl = RegExp(
      'CREATE\\s+(?:TEMP\\s+|TEMPORARY\\s+)?TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?'
      '(?:$libraryTables)\\b',
      caseSensitive: false,
    );

    test('a stray library.sqlite reference in Rust is detectable', () {
      const sample = '''
let db = Connection::open(app_data.join("library.sqlite"))?;
''';
      expect(codeOnly(sample), contains('library.sqlite'));
      expect(
        RegExp(r'library\.sqlite|app\.sqlite').hasMatch(codeOnly(sample)),
        isTrue,
        reason: 'Rust 侧出现 library.sqlite 必须被 a) 组检出',
      );
    });

    test('a stray rusqlite dependency in Rust is detectable', () {
      const sample = '''
use rusqlite::{params, Connection};
''';
      expect(
        RegExp(
          r'rusqlite|libsqlite3|Connection::open|TransactionBehavior',
        ).hasMatch(codeOnly(sample)),
        isTrue,
        reason: 'Rust 侧复活 rusqlite 必须被 a) 组检出',
      );
    });

    test('a stray app.sqlite reference in Rust is detectable', () {
      const sample = '''
let db = Connection::open(app_data.join("app.sqlite"))?;
''';
      expect(
        codeOnly(sample),
        matches(RegExp(r'app\.sqlite')),
        reason: 'Rust 侧出现 app.sqlite 必须被 a) 组检出',
      );
    });

    test('a stray Dart DDL outside the owner is detectable', () {
      for (final sample in <String>[
        'CREATE TABLE IF NOT EXISTS folders (id INTEGER PRIMARY KEY)',
        'CREATE TABLE audios (id INTEGER)',
        'create temp table if not exists cover_thumbnails (id INTEGER)',
      ]) {
        expect(
          libraryDdl.hasMatch(sample),
          isTrue,
          reason: 'Dart 侧在 owner 之外建曲库表必须被 c) 组检出：$sample',
        );
        // owner 归属判定是「文件:行号」前缀匹配：同一条 DDL 放在别的文件里不会
        // 落进 owner 前缀，因此会被 unexpected 收走。
        expect(
          'lib/core/somewhere_else.dart:1'.startsWith('$libraryDbOwner:'),
          isFalse,
        );
      }
    });

    test('a stray Rust DDL is detectable', () {
      const sample = '''
db.execute_batch("CREATE TABLE IF NOT EXISTS folders (id INTEGER)")?;
''';
      expect(
        RegExp(
          r'CREATE\s+TABLE',
          caseSensitive: false,
        ).hasMatch(codeOnly(sample)),
        isTrue,
        reason: 'Rust 侧任何建表语句都必须被 c) 组检出',
      );
    });

    test('comment stripping prevents false positives but keeps real code', () {
      const commented = '''
/// 曲库索引库（library.sqlite）由 Dart 侧 LibraryDb 接管
// final dbFile = File('library.sqlite');
final dbFile = File('app.sqlite');
''';
      final code = codeOnly(commented);
      expect(
        code.contains('library.sqlite'),
        isFalse,
        reason: '注释里的提及不得被当成真实引用',
      );
      expect(code.contains("'app.sqlite'"), isTrue, reason: '代码行必须保留');
    });

    test(
      'real repositories still satisfy the scanners (no silent all-clear)',
      () {
        // 若目录/文件后缀变更导致扫描面为空，前面的「isEmpty」断言会假绿。
        expect(dartFilesUnder('lib'), isNotEmpty);
        expect(rustFilesUnder('rust/src'), isNotEmpty);
      },
    );
  });
}
