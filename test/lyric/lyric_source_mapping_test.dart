import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/matcher.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_source_view.dart';
import 'package:sqlite3/sqlite3.dart';

/// 1.1 映射收敛的结构性验收（原 Spec §7；草案已删除，结论见
/// `docs/specs/decoupling-open-issues.md` §1.1）：
///
/// 1. 映射表是唯一 owner：wire 名 / 展示名 / id 读写都必须经它；
/// 2. `ResultSource` ↔ `LyricSourceType` 的唯一桥接行为正确（`local` 无反向）；
/// 3. 历史数据（`lyric_source.json` / 数据库行）读取**行为不变**（D5：不统一归一化差异）；
/// 4. wp-6 复核 F1/F2：映射实现点唯一（全 `lib/` 源码扫描）+ 四来源"已保存判定"
///    命中/未命中（经公开入口的等价覆盖，见下方 F2 组说明）。
void main() {
  setUp(() {
    lyricSources = {};
  });

  tearDown(() {
    lyricSources = {};
  });

  group('映射表：wire 名与展示名', () {
    test('每个来源都有 wire 名，且与枚举成员名逐字一致', () {
      // 成员自带的 `name` 字段被 AppSettings.preferredOnlineSource 直接持久化，
      // 表内 wire 名必须与之相同，否则落库值会与设置项漂移。
      for (final source in LyricSourceType.values) {
        expect(
          lyricSourceWireName(source),
          source.name,
          reason: 'LyricSourceType.$source 的 wire 名与成员名不一致',
        );
      }
    });

    test('展示名统一为 D3 裁定的四个文案', () {
      expect(lyricSourceLabel(LyricSourceType.qq), 'QQ');
      expect(lyricSourceLabel(LyricSourceType.ne), '网易');
      expect(lyricSourceLabel(LyricSourceType.kugou), '酷狗');
      expect(lyricSourceLabel(LyricSourceType.amll), 'AMLL');
    });

    test('wire 名可反解析回同一枚举', () {
      for (final source in LyricSourceType.values) {
        expect(lyricSourceTypeFromWire(lyricSourceWireName(source)), source);
      }
      expect(lyricSourceTypeFromWire(null), isNull);
      expect(lyricSourceTypeFromWire('unknown-source'), isNull);
    });
  });

  group('唯一桥接', () {
    test('四个搜索来源都能映射到同名字来源', () {
      for (final source in ResultSource.values) {
        expect(
          lyricSourceTypeForResultSource(source).name,
          source.name,
          reason: 'ResultSource.$source 应映射到同名歌词来源',
        );
      }
    });

    test('反向桥接：local 没有对应搜索来源（不兜底成 qq）', () {
      for (final source in ResultSource.values) {
        final lyricSource = lyricSourceTypeForResultSource(source);
        expect(resultSourceForLyricSourceType(lyricSource), source);
      }
      expect(resultSourceForLyricSourceType(LyricSourceType.local), isNull);
    });

    test('搜索结果转 LyricSource 保留 id 字段', () {
      final result = SongSearchResult(
        ResultSource.amll,
        'Manchild',
        'Sabrina Carpenter',
        'Manchild',
        100,
        amllTtmlFile: '1749352311169-142093212-5ad2d962.ttml',
      );

      final source = result.toLyricSource();

      expect(source.source, LyricSourceType.amll);
      expect(source.amllTtmlFile, '1749352311169-142093212-5ad2d962.ttml');
      expect(lyricSourceId(source), '1749352311169-142093212-5ad2d962.ttml');
    });
  });

  group('持久化往返（零迁移）', () {
    test('每个来源的 id 都经表读写，往返后不变', () {
      final cases = <LyricSource>[
        LyricSource(LyricSourceType.qq, qqSongId: '0039MnYb0qxYhV'),
        LyricSource(LyricSourceType.kugou, kugouSongHash: 'abc123hash'),
        LyricSource(LyricSourceType.ne, neSongId: 1475869988),
        LyricSource(LyricSourceType.amll, amllTtmlFile: 'file.ttml'),
        LyricSource(LyricSourceType.local),
      ];

      for (final source in cases) {
        final map = source.toMap();
        final restored = LyricSource.fromMap(map);

        expect(restored, isNotNull, reason: '${source.source} 往返失败');
        expect(restored!.source, source.source);
        expect(
          lyricSourceId(restored),
          lyricSourceId(source),
          reason: '${source.source} 的 id 往返后发生了变化',
        );
      }
    });

    test('local 的 id 恒为 null', () {
      final source = LyricSource(LyricSourceType.local);

      expect(lyricSourceId(source), isNull);
      expect(source.toMap()['id'], isNull);
      expect(source.toMap()['source'], 'local');
    });

    test('历史 JSON：带点号前缀的 source 仍可识别', () {
      // 旧版本可能写入 `LyricSourceType.qq` 形态，_normalizedSourceName 会剥离前缀。
      final restored = LyricSource.fromMap({
        'source': 'LyricSourceType.qq',
        'id': 12345,
      });

      expect(restored!.source, LyricSourceType.qq);
      expect(restored.qqSongId, '12345');
    });

    test('历史 JSON：ne 的 id 接受 int / num / 字符串形态', () {
      for (final raw in <Object>[1475869988, 1475869988.0, '1475869988']) {
        final restored = LyricSource.fromMap({'source': 'ne', 'id': raw});
        expect(
          restored!.neSongId,
          1475869988,
          reason: 'ne id 的 $raw 形态未被识别',
        );
      }
    });

    test('历史 JSON：无法识别的 source 回落本地歌词，不抛异常', () {
      final restored = LyricSource.fromMap({'source': 'weird', 'id': '1'});

      expect(restored!.source, LyricSourceType.local);
      expect(lyricSourceId(restored), isNull);
    });

    test('D5：JSON 侧归一化，文本 id 的数值形态转成字符串', () {
      final restored = LyricSource.fromMap({'source': 'qq', 'id': 98765});

      expect(restored!.qqSongId, '98765');
    });

    test('★ D5：DB 行侧原样透传、JSON 侧归一化（两侧差异被测试固定）', () {
      // `_lyricSourceFromDb` / `_lyricSourceWithId` 是文件级私有，测试**不直调**私有函数。
      // 等价覆盖：D5 的差异点只有一个开关——
      //   DB 行   ：normalizeTextId=false ⇒ rawId?.toString()（原样，不 trim）
      //   JSON 侧 ：normalizeTextId=true  ⇒ _normalizedTextSongId（trim + 数值规范）
      // 故用两条**公开**链路把它固定住：
      //   ① DB 写入链路（公开的 lyricSourceId + 真实建表）：列里存的就是未归一化的原文；
      //   ② JSON 读取链路（公开的 LyricSource.fromMap）：同一份原文被归一化。
      // 还要断言源码里这两处接线确实传了相反的开关，防止有人"统一"掉差异。
      const rawTextId = '  qq-raw-1  ';

      // ① DB 侧：写入列 → 读回，必须逐字原样（不 trim）。
      final database = sqlite3.openInMemory();
      try {
        initializeAppDatabase(database);
        final saved = LyricSource(LyricSourceType.qq, qqSongId: rawTextId);
        final storedId = lyricSourceId(saved);

        expect(
          storedId,
          rawTextId,
          reason: 'DB 侧必须原样透传，不得 trim（D5）',
        );

        database.execute(
          'INSERT INTO lyric_sources(path, source, id) VALUES(?, ?, ?)',
          ['C:/music/d5.mp3', lyricSourceWireName(saved.source), storedId],
        );
        final row = database.select(
          'SELECT source, id FROM lyric_sources',
        ).single;

        expect(row['id'], rawTextId, reason: 'DB 列值必须原样往返');
        // 同一行经 JSON 的 fromMap 读取会被归一化 ⇒ 两侧确实不同。
        final viaJson = LyricSource.fromMap({
          'source': row['source'],
          'id': row['id'],
        });
        expect(
          viaJson!.qqSongId,
          'qq-raw-1',
          reason: 'JSON 侧必须 trim 归一化（D5 的另一半）',
        );
        expect(
          row['id'],
          isNot(viaJson.qqSongId),
          reason: 'D5 允许两侧不同；若哪天被统一，这条会红并迫使更新 Spec',
        );
      } finally {
        database.dispose();
      }

      // ② 接线断言：DB 读取传 normalizeTextId:false，JSON 读取传 true。
      final source = File('lib/lyric/lyric_source.dart').readAsStringSync();
      expect(
        RegExp(
          r'normalizeTextId\s*:\s*false',
        ).allMatches(source).length,
        1,
        reason: 'DB 行读取必须且只能有一处 normalizeTextId:false',
      );
      expect(
        RegExp(r'normalizeTextId\s*:\s*true').allMatches(source).length,
        1,
        reason: 'JSON 读取必须且只能有一处 normalizeTextId:true',
      );
      expect(
        source,
        contains('_lyricSourceFromDb(source, id)'),
        reason: 'DB 读取路径必须仍走 _lyricSourceFromDb',
      );
    });
  });

  group('F2：四个来源的已保存判定（经公开入口的等价覆盖）', () {
    // `_isSavedLyricResult` 是 `lyric_source_view.dart` 的文件级私有函数，测试**不直调**私有函数。
    // 等价覆盖方法：
    //   ① 用公开的 `applyValidatedOnlineLyricResult` 真正写入 `lyricSources`
    //      （与 UI 选中搜索结果走的是同一入口），得到"已保存来源"；
    //   ② 用公开桥接 `lyricSourceTypeForResultSource` 与映射表 `lyricSourceId`
    //      复算该私有函数仅有的两个判定条件：
    //        a. saved.source == lyricSourceTypeForResultSource(result.source)
    //        b. lyricSourceId(saved) != null &&
    //           lyricSourceId(saved) == lyricSourceId(result.toLyricSource())
    //      两条件都满足 = 命中；任一不满足 = 未命中（该私有函数没有其它分支）。
    final lyric = Lyric([LyricLine(Duration.zero, const Duration(seconds: 1))]);
    var audioSeq = 0;

    Audio newAudio() => Audio(
      'T',
      'A',
      'B',
      null,
      1,
      240,
      240,
      44100,
      'C:/music/lyric-source-mapping-${audioSeq++}.mp3',
      0,
      0,
      null,
    );

    Future<bool> applyAsSaved(Audio audio, SongSearchResult result) {
      return applyValidatedOnlineLyricResult(
        audio,
        result,
        loadLyric: (_, _) async => lyric,
        persist: () async {},
        activate: () {},
      );
    }

    bool isSavedByEquivalentLogic(Audio audio, SongSearchResult result) {
      final saved = lyricSources[audio.path];
      if (saved == null) return false;
      if (saved.source != lyricSourceTypeForResultSource(result.source)) {
        return false;
      }
      final savedId = lyricSourceId(saved);
      return savedId != null && savedId == lyricSourceId(result.toLyricSource());
    }

    SongSearchResult qqResult(String? id) => SongSearchResult(
      ResultSource.qq,
      't',
      'a',
      'b',
      100,
      qqSongId: id,
    );
    SongSearchResult kugouResult(String? id) => SongSearchResult(
      ResultSource.kugou,
      't',
      'a',
      'b',
      100,
      kugouSongHash: id,
    );
    SongSearchResult neResult(int? id) => SongSearchResult(
      ResultSource.ne,
      't',
      'a',
      'b',
      100,
      neSongId: id,
    );
    SongSearchResult amllResult(String? id) => SongSearchResult(
      ResultSource.amll,
      't',
      'a',
      'b',
      100,
      amllTtmlFile: id,
    );

    test('qq：命中 / 未命中', () async {
      final audio = newAudio();
      final result = qqResult('qq-1');

      expect(await applyAsSaved(audio, result), isTrue);
      final saved = lyricSources[audio.path]!;
      expect(saved.source, lyricSourceTypeForResultSource(result.source));
      expect(lyricSourceId(saved), 'qq-1');
      expect(isSavedByEquivalentLogic(audio, result), isTrue);

      // 同源不同 id ⇒ 条件 b 不满足。
      expect(isSavedByEquivalentLogic(audio, qqResult('qq-2')), isFalse);
      // 同 id 字符串、不同来源 ⇒ 条件 a 不满足。
      expect(isSavedByEquivalentLogic(audio, amllResult('qq-1')), isFalse);

      // 已保存来源没有 id ⇒ 条件 b 的 `savedId != null` 不满足。
      final noIdAudio = newAudio();
      expect(await applyAsSaved(noIdAudio, qqResult(null)), isTrue);
      expect(isSavedByEquivalentLogic(noIdAudio, qqResult(null)), isFalse);
    });

    test('kugou：命中 / 未命中', () async {
      final audio = newAudio();
      final result = kugouResult('kg-1');

      expect(await applyAsSaved(audio, result), isTrue);
      final saved = lyricSources[audio.path]!;
      expect(saved.source, lyricSourceTypeForResultSource(result.source));
      expect(lyricSourceId(saved), 'kg-1');
      expect(isSavedByEquivalentLogic(audio, result), isTrue);

      expect(isSavedByEquivalentLogic(audio, kugouResult('kg-2')), isFalse);
    });

    test('ne：命中 / 未命中', () async {
      final audio = newAudio();
      final result = neResult(1475869988);

      expect(await applyAsSaved(audio, result), isTrue);
      final saved = lyricSources[audio.path]!;
      expect(saved.source, lyricSourceTypeForResultSource(result.source));
      expect(lyricSourceId(saved), '1475869988');
      expect(isSavedByEquivalentLogic(audio, result), isTrue);

      expect(isSavedByEquivalentLogic(audio, neResult(1475869989)), isFalse);
    });

    test('amll：命中 / 未命中', () async {
      final audio = newAudio();
      final result = amllResult('file.ttml');

      expect(await applyAsSaved(audio, result), isTrue);
      final saved = lyricSources[audio.path]!;
      expect(saved.source, lyricSourceTypeForResultSource(result.source));
      expect(lyricSourceId(saved), 'file.ttml');
      expect(isSavedByEquivalentLogic(audio, result), isTrue);

      expect(isSavedByEquivalentLogic(audio, amllResult('other.ttml')), isFalse);
    });

    test('跨来源不命中：来源不同即使 id 相同也不判为已保存', () async {
      final audio = newAudio();
      expect(await applyAsSaved(audio, neResult(42)), isTrue);

      expect(isSavedByEquivalentLogic(audio, qqResult('42')), isFalse);
      expect(isSavedByEquivalentLogic(audio, amllResult('42')), isFalse);
    });

    test('未保存过来源时不命中', () {
      final audio = newAudio();

      expect(lyricSources[audio.path], isNull);
      expect(isSavedByEquivalentLogic(audio, qqResult('qq-1')), isFalse);
    });

    test('local 已保存来源不会命中任何在线结果', () {
      // `local` 没有对应的搜索结果，只能直接放夹具；判定走同一等价逻辑。
      final audio = newAudio();
      lyricSources[audio.path] = LyricSource(LyricSourceType.local);

      expect(isSavedByEquivalentLogic(audio, qqResult('qq-1')), isFalse);
      expect(isSavedByEquivalentLogic(audio, amllResult('file.ttml')), isFalse);
    });
  });

  group('F3：首选源 → 搜索源的唯一裁定点（local → qq 保留）', () {
    const owner = 'lib/play_service/lyric_service.dart';
    const helper = '_resultSourceForPreferredOnline';

    String codeOf(String path) => File(path)
        .readAsStringSync()
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    test('`?? ResultSource.qq` 在 lyric_service.dart 内只剩 1 处且位于 helper', () {
      final code = codeOf(owner);
      final occurrences = RegExp(
        r'\?\?\s*ResultSource\.qq',
      ).allMatches(code).length;

      expect(occurrences, 1, reason: '兜底必须收敛到唯一裁定点，不得双份');
      expect(code, contains('ResultSource $helper('));
      expect(
        RegExp(
          'ResultSource\\s+$helper\\([^)]*\\)\\s*=>\\s*[\\s\\S]{0,120}?'
          'resultSourceForLyricSourceType\\([^)]*\\)\\s*\\?\\?\\s*ResultSource\\.qq',
        ).hasMatch(code),
        isTrue,
        reason: 'helper 必须委托唯一桥接并保留 local → qq 的搜索路由',
      );
    });

    test('活动来源取设置值，不经任何 qq 兜底', () {
      final code = codeOf(owner);

      // 两处在线分支（updateLyric / useOnlineLyric）都直接赋设置值。
      expect(
        RegExp(
          r'_activeLyricSourceType\s*=\s*preferredSource\s*;',
        ).allMatches(code).length,
        2,
        reason: '活动来源必须直接用 preferredSource（local 不得被改写成 qq）',
      );
      expect(
        RegExp(
          r'_activeLyricSourceType\s*=\s*rs\b',
        ).hasMatch(code),
        isFalse,
        reason: '不得把搜索源（可能已兜底 qq）写回活动来源',
      );
      // 两个调用点：updateLyric 与 useOnlineLyric。
      expect(
        RegExp(helper + r'\(preferredSource\)').allMatches(code).length,
        2,
      );
    });

    test('行为等价：桥接对 local 返回 null，故 helper 只可能回落 qq', () {
      // helper 的语义前提：4 个在线来源都能解析，唯一返回 null 的是 local。
      // 即 `?? ResultSource.qq` 分支只可能被 local 触发（D-C 既有行为保留）。
      for (final source in ResultSource.values) {
        expect(
          resultSourceForLyricSourceType(lyricSourceTypeForResultSource(source)),
          source,
        );
      }
      expect(resultSourceForLyricSourceType(LyricSourceType.local), isNull);
    });
  });

  group('F1：枚举映射实现点 = 1（全 lib 源码扫描）', () {
    // 结构断言：任何人再写一份 `ResultSource.x => LyricSourceType.y`（或反向、
    // 或 map 字面量、或按来源读 id 字段的 switch），这个测试就红。
    // 扫描整个 `lib/`（不写死文件清单），避免"新文件长出一份副本"漏检；
    // 行注释先剔除，避免文档里提到规范写法被误判成实现。
    //
    // 覆盖的重复实现形态（三者都要覆盖，否则"换个写法"就能绕过结构验收）：
    //   ① 表达式 / map 字面量：`ResultSource.qq => LyricSourceType.qq`、
    //      `LyricSourceType.qq: ResultSource.qq`；
    //   ② case 分支：`case ResultSource.qq:` 换行 `return LyricSourceType.qq;`
    //      （标签与分支体不同行，必须跨行匹配）；
    //   ③ 按来源读 id 字段：`ResultSource.qq => saved.qqSongId != null`、
    //      `case ResultSource.ne:` 分支内的 `saved.neSongId`。
    // ②③ 的正向自检见本组末尾的 fixture 负控测试。
    const bridgeOwner = 'lib/core/matcher.dart';
    const tableOwner = 'lib/lyric/lyric_source.dart';

    List<File> libDartFiles() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList(growable: false);

    String normalizedPath(FileSystemEntity entity) =>
        entity.path.replaceAll(r'\', '/');

    /// 去掉行注释（含 `///` 文档注释）后再匹配。
    String codeOnly(String source) => source
        .split('\n')
        .where((line) {
          final trimmed = line.trimLeft();
          return !trimmed.startsWith('//') && !trimmed.startsWith('*');
        })
        .join('\n');

    /// case 分支体允许的最大字符跨度：`case ...:` 到分支体内命中的距离。
    /// 240 覆盖实测最长的分支（lyric_source_view.dart 的搜索结果构造约 600 字符，
    /// 但那类分支不读 id 字段），同时远小于跨 case 串联所需的距离。
    const caseBodySpan = 240;

    /// id 字段名：显式四项 + 语义相近命名（`qqId` / `kgHash` / `neFile` 之类），
    /// 避免改名一份副本就绕过扫描。整体包成单个非捕获组，防止 `|` 逃逸到顶层。
    const idField =
        r'(?:qqSongId|kugouSongHash|neSongId|amllTtmlFile'
        r'|\w*(?:SongId|SongHash|TtmlFile)'
        r'|(?:qq|kugou|kg|ne|netease|amll)\w*(?:Id|Hash|File))';

    /// 正向：`ResultSource.x` → `LyricSourceType.y`，表达式/map 与 case 两种形态。
    final forwardArm = RegExp(
      r'ResultSource\.\w+\s*(?:=>|:)\s*LyricSourceType\.\w+'
      '|case\\s+ResultSource\\.\\w+\\s*:[\\s\\S]{0,$caseBodySpan}?'
      r'\breturn\s+LyricSourceType\.\w+',
    );

    /// 反向：`LyricSourceType.x` → `ResultSource.y`。
    final backwardArm = RegExp(
      r'LyricSourceType\.\w+\s*(?:=>|:)\s*ResultSource\.\w+'
      '|case\\s+LyricSourceType\\.\\w+\\s*:[\\s\\S]{0,$caseBodySpan}?'
      r'\breturn\s+ResultSource\.\w+',
    );

    /// 按来源读 id 字段：分支标签后紧跟 `.<id 字段>`（表达式 / case 两种形态）。
    ///
    /// 第 4 形态是历史被删的 I1 写法（转写自 HEAD `lib/lyric/lyric_source.dart:192`）：
    /// 分支键是 `LyricSourceType`、分支体内才读字段 ——
    /// `case LyricSourceType.qq:` 换行 `return s.qqSongId;`。
    final idArm = RegExp(
      'LyricSourceType\\.\\w+\\s*(?:=>|:)[^\\n]*\\.$idField\\b'
      '|ResultSource\\.\\w+\\s*(?:=>|:)[\\s\\S]{0,120}?\\.$idField\\b'
      '|case\\s+ResultSource\\.\\w+\\s*:[\\s\\S]{0,$caseBodySpan}?\\.$idField\\b'
      '|case\\s+LyricSourceType\\.\\w+\\s*:[\\s\\S]{0,$caseBodySpan}?'
      r'\.(?:qqSongId|kugouSongHash|neSongId|amllTtmlFile)',
    );
    final forwardDecl = RegExp(
      r'^\s*LyricSourceType\s+lyricSourceTypeForResultSource\s*\(',
      multiLine: true,
    );
    final backwardDecl = RegExp(
      r'^\s*ResultSource\?\s+resultSourceForLyricSourceType\s*\(',
      multiLine: true,
    );

    /// id 映射声明：`lyricSourceId(` 与私有写法 `_lyricSourceId(` 都算实现点
    /// （HEAD 的旧实现正是 `_lyricSourceId`，不认私有前缀就等于漏检）。
    final idDecl = RegExp(
      r'^\s*String\?\s+_?lyricSourceId\s*\(',
      multiLine: true,
    );

    /// 对单份源码跑三组结构扫描，返回命中的 arm 名（空 = 无重复实现）。
    /// `lib/` 扫描与 fixture 负控测试共用这一条路径，保证"自检通过"等于
    /// "扫描逻辑对样本确实灵敏"，而不是两套各写一遍的近似逻辑。
    List<String> scanSource(String source) {
      final code = codeOnly(source);
      return <String>[
        if (forwardArm.hasMatch(code)) 'forward',
        if (backwardArm.hasMatch(code)) 'backward',
        if (idArm.hasMatch(code)) 'id',
      ];
    }

    List<({String path, List<String> hits})> scanLib() {
      final offenders = <({String path, List<String> hits})>[];
      for (final file in libDartFiles()) {
        final hits = scanSource(file.readAsStringSync());
        if (hits.isNotEmpty) {
          offenders.add((path: normalizedPath(file), hits: hits));
        }
      }
      return offenders;
    }

    test('全 lib 内没有第二份枚举映射 / 按来源读 id 字段的实现', () {
      final offenders = scanLib();
      final enumOffenders = offenders
          .where(
            (entry) =>
                entry.hits.contains('forward') ||
                entry.hits.contains('backward'),
          )
          .map((entry) => '${entry.path}: ${entry.hits.join('+')}')
          .toList(growable: false);
      final idOffenders = offenders
          .where((entry) => entry.hits.contains('id'))
          .map((entry) => entry.path)
          .toList(growable: false);

      expect(
        enumOffenders,
        isEmpty,
        reason:
            '枚举映射实现点必须只有 1 处（$bridgeOwner 的桥接函数委托映射表）；'
            '发现额外实现：$enumOffenders',
      );
      expect(
        idOffenders,
        isEmpty,
        reason:
            'id 字段映射实现点必须只有 1 处（$tableOwner 的 lyricSourceId）；'
            '发现额外实现：$idOffenders',
      );
    });

    test('实现点声明唯一：正/反向桥接只在 matcher.dart，id 映射只在映射表', () {
      final forwardOwners = <String>[];
      final backwardOwners = <String>[];
      final idOwners = <String>[];

      for (final file in libDartFiles()) {
        final path = normalizedPath(file);
        final source = codeOnly(file.readAsStringSync());
        if (forwardDecl.hasMatch(source)) forwardOwners.add(path);
        if (backwardDecl.hasMatch(source)) backwardOwners.add(path);
        if (idDecl.hasMatch(source)) idOwners.add(path);
      }

      expect(forwardOwners, [bridgeOwner]);
      expect(backwardOwners, [bridgeOwner]);
      expect(idOwners, [tableOwner]);
    });

    test('桥接确实委托映射表，且不自行兜底 local → qq', () {
      final source = File(bridgeOwner).readAsStringSync();

      expect(
        source,
        contains('lyricSourceTypeFromWire('),
        reason: '正向桥接必须委托映射表，而不是自己复制 4 对成员',
      );
      expect(
        source,
        contains('lyricSourceWireName('),
        reason: '反向桥接必须委托映射表',
      );
      expect(
        source,
        contains('resultSourceForLyricSourceType('),
        reason: '反向桥接函数缺失',
      );
      expect(
        source,
        isNot(contains('?? ResultSource.qq')),
        reason: '反向 local → null 由调用点显式处理，桥接处不得兜底成 qq',
      );
    });

    test('负控：扫描对 case 形态与 id 字段形态的重复实现确实会命中', () {
      // 上面的"全 lib 无命中"只有在扫描真的灵敏时才有意义。本测试把 reviewer
      // 实测的两类漏检样本写成临时 fixture，跑**同一条** scanSource 路径，
      // 断言它们被判为重复实现；再用一份合规样本断言扫描不会误报。
      // fixture 只落在系统临时目录下的唯一子目录，tearDown 删除。
      final scratch = Directory.systemTemp.createTempSync(
        'listenary_f1_mapping_probe_',
      );
      addTearDown(() {
        if (scratch.existsSync()) {
          scratch.deleteSync(recursive: true);
        }
      });

      /// 形态 A：case 分支 + 换行 return（旧正则只认 `=>` / `:`，漏检）。
      const caseStyleForward = '''
enum ResultSource { qq, kugou, ne, amll }
enum LyricSourceType { qq, kugou, ne, amll, local }

LyricSourceType duplicatedBridge(ResultSource source) {
  switch (source) {
    case ResultSource.qq:
      return LyricSourceType.qq;
    case ResultSource.kugou:
      return LyricSourceType.kugou;
    case ResultSource.ne:
      return LyricSourceType.ne;
    case ResultSource.amll:
      return LyricSourceType.amll;
  }
}
''';

      /// 形态 B：`ResultSource.x => <读 id 字段>`（HEAD 被删段落的写法）。
      const idFieldDuplication = '''
class SongSearchResult {
  ResultSource source;
  String? qqSongId;
  String? kugouSongHash;
  int? neSongId;
  String? amllTtmlFile;
}

class LyricSource {
  String? qqSongId;
  String? kugouSongHash;
  int? neSongId;
  String? amllTtmlFile;
}

bool isSavedLyricResultByCopy(SongSearchResult result, LyricSource saved) {
  return switch (result.source) {
    ResultSource.qq => saved.qqSongId != null,
    ResultSource.kugou => saved.kugouSongHash != null,
    ResultSource.ne => saved.neSongId != null,
    ResultSource.amll => saved.amllTtmlFile != null,
  };
}
''';

      /// 形态 C：case 分支内读 id 字段（跨行，旧正则同样漏检）。
      const caseStyleIdField = '''
bool readsIdInCase(ResultSource source, LyricSource saved) {
  switch (source) {
    case ResultSource.ne:
      final id = saved.neSongId;
      return id != null;
    default:
      return false;
  }
}
''';

      /// 合规样本：只经映射表对外入口，扫描必须 0 命中（防误报）。
      const compliant = '''
LyricSourceType bridge(ResultSource source) {
  final resolved = lyricSourceTypeFromWire(source.name);
  if (resolved == null) {
    throw StateError('missing mapping');
  }
  return resolved;
}

String? idOf(LyricSource source) => _lyricSourceSpec(source.source).readId
    ?.call(source);
''';

      /// 形态 D：HEAD 被删的 I1 原文（`lib/lyric/lyric_source.dart:192-205`）。
      /// case 键是 `LyricSourceType`、分支体内才读 id 字段，且声明为私有
      /// `_lyricSourceId` —— 上一版 idArm / idDecl 对它**双双漏检**，是真实盲区。
      const headI1IdSwitch = '''
String? _lyricSourceId(LyricSource s) {
  switch (s.source) {
    case LyricSourceType.qq:
      return s.qqSongId?.toString();
    case LyricSourceType.kugou:
      return s.kugouSongHash;
    case LyricSourceType.ne:
      return s.neSongId?.toString();
    case LyricSourceType.amll:
      return s.amllTtmlFile;
    case LyricSourceType.local:
      return null;
  }
}
''';

      final fixtures = <String, ({String source, List<String> expected})>{
        'case_style_forward.dart': (
          source: caseStyleForward,
          expected: <String>['forward'],
        ),
        'id_field_duplication.dart': (
          source: idFieldDuplication,
          expected: <String>['id'],
        ),
        'case_style_id_field.dart': (
          source: caseStyleIdField,
          expected: <String>['id'],
        ),
        'head_i1_id_switch.dart': (
          source: headI1IdSwitch,
          expected: <String>['id'],
        ),
        'compliant.dart': (source: compliant, expected: const <String>[]),
      };

      for (final entry in fixtures.entries) {
        final file = File('${scratch.path}/${entry.key}')
          ..writeAsStringSync(entry.value.source);

        // 断言 fixture 确实落在临时目录内，且经统一扫描入口读回。
        expect(
          normalizedPath(file).startsWith(normalizedPath(scratch)),
          isTrue,
          reason: 'fixture 必须写在临时目录',
        );
        expect(
          scanSource(file.readAsStringSync()),
          entry.value.expected,
          reason: '${entry.key} 的扫描判定不符合预期（重复实现必须被检出）',
        );
      }

      // HEAD I1 的私有声明 `_lyricSourceId(` 也必须被认作 id 映射实现点。
      expect(
        idDecl.hasMatch(headI1IdSwitch),
        isTrue,
        reason: 'idDecl 必须认私有写法 _lyricSourceId（HEAD 旧实现即此形态）',
      );
    });
  });
}
