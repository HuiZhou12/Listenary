import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// D9 守卫：**在线曲目的歌词只能走 Provider 路由**，不得被"全局歌词源"接管。
///
/// 背景：本仓有两套歌词机制 ——
/// ① 在线路径：`OnlineMusicService.fetchLyrics(ref)`（按 `ref.platform` 路由到 Provider）；
/// ② 本地路径：`lib/services/online_lyric/` 的取词/解析链路（`api/`、`parsers/`、
///    `parsed_lyric_converter.dart`）+ `LyricSourceType` +
///    `AppSettings.preferredOnlineSource`（服务本地歌曲，本阶段明确不合并）。
///
/// 用户确认的禁止项（D9 / 补充口径⑧）：**不得出现"在线歌曲已带 platform，却无视来源、
/// 继续走全局 preferredOnlineSource"**。这里用与 `online_music_dependency_boundary_test`
/// 相同的源码扫描方式把它固定下来 —— 一旦有人把第二套机制接进在线路径，这个测试就会红。
///
/// 2026-10-19：`lib/services/online_lyric/sources/` 下那套与 `lib/lyric/lyric_source.dart`
/// **同名**的平行**接口层**（`abstract class LyricSource` + 三个实现 + 配套两个 model + 桶文件）
/// 已确认全仓零实例化、零测试，**已整体删除**；取词/解析链路（① 之外的 `api/`、`parsers/`、
/// `parsed_lyric_converter.dart`）保持不变。原先那条"禁止实例化"的守卫因此变成空转，
/// 现替换为下面的「唯一声明点」不变量。
void main() {
  const controllerPath = 'lib/play_service/remote_lyric_controller.dart';

  String readSource(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '找不到 $path');
    return file.readAsStringSync();
  }

  test('在线歌词控制器不得引用全局歌词源（D9）', () {
    final source = readSource(controllerPath);

    for (final forbidden in const [
      'preferredOnlineSource',
      'LyricSourceType',
      'online_lyric',
      'LyricSource(',
      'lyric_service.dart',
    ]) {
      expect(
        source.contains(forbidden),
        isFalse,
        reason: '在线歌词路径不得出现 $forbidden —— 在线曲目必须按 Track 来源走 Provider（D9）',
      );
    }
  });

  test('在线歌词控制器确实走 Provider 且先过平台闸门', () {
    final source = readSource(controllerPath);

    // 唯一取词入口。
    expect(source, contains('fetchLyrics'));
    // 平台闸门：不支持该平台的来源直接给 empty，而不是换源。
    expect(source, contains('lyricPlatforms'));
  });

  test('第二套歌词机制只服务本地歌曲，不被在线路径导入', () {
    // 反向确认：本地歌词的**取词/解析链路**仍然存在且独立（没有被搬进在线路径）。
    // 该目录现只剩活文件；曾在这里的同名源接口层已删除（见文件头）。
    expect(Directory('lib/services/online_lyric').existsSync(), isTrue);
    expect(File('lib/lyric/lyric_source.dart').existsSync(), isTrue);
  });

  test('★ 歌词来源模型全仓**只有一个声明点**（不得再长出平行模型）', () {
    // 背景：`lib/services/online_lyric/sources/` 下曾有一整套与 `lib/lyric/lyric_source.dart`
    // **同名**的平行抽象（`abstract class LyricSource` + `enum LyricSourceType` + 三个实现），
    // 全仓零实例化、零测试 —— 任何按名字检索的人都会在两套同名类型之间迷失。
    // 那套件已删除（见文件头）。这里把删除后的**不变量**固定下来，替代原来那条空转的
    // "禁止实例化"守卫：每个名字**只能有一个声明点**，出现第二个就说明又长出了一套平行模型。
    final declarations = <String, RegExp>{
      'LyricSourceType': RegExp(
        r'^\s*(?:enum|class)\s+LyricSourceType\b',
        multiLine: true,
      ),
      'LyricSource': RegExp(
        r'^\s*(?:abstract\s+)?class\s+LyricSource\b',
        multiLine: true,
      ),
    };
    const owner = 'lib/lyric/lyric_source.dart';

    final found = <String, List<String>>{
      for (final name in declarations.keys) name: <String>[],
    };
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      final path = entity.path.replaceAll(r'\', '/');
      for (final entry in declarations.entries) {
        if (entry.value.hasMatch(source)) found[entry.key]!.add(path);
      }
    }

    for (final name in declarations.keys) {
      expect(
        found[name],
        [owner],
        reason:
            '$name 必须只有一个声明点（$owner）；'
            '出现多个 ⇒ 又长出了一套平行的歌词来源模型，请合并回单一 owner',
      );
    }
  });

  test('★ 本地歌词来源的两处 UI 文案必须写明**作用域**', () {
    // 这两个控件原本只写"首选歌词来源 / 默认在线源"，没有任何"只对本地歌曲生效"的说明
    // （而它确实只作用于本地库那一套）。那个控件此前也没有 widget 测试，
    // 因此这里用与依赖边界测试相同的**源码扫描**把文案固定下来：
    // 一旦有人删掉作用域说明，就会红。
    final source = readSource('lib/page/settings_page/settings_tabs.dart');

    expect(
      source,
      contains('仅本地歌曲'),
      reason: '必须写明只对本地歌曲生效',
    );
    expect(
      source,
      contains('在线曲目的歌词按曲目所属平台获取，不受这里影响'),
      reason: '必须说明在线曲目按平台取词，避免用户以为它决定所有歌曲',
    );
    expect(
      source,
      isNot(contains("description: '首选歌词来源',")),
      reason: '不得留下**无作用域限定**的旧文案',
    );
    expect(
      source,
      isNot(contains("description: '默认在线源',")),
      reason: '同上',
    );
  });
}
