import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// D9 守卫：**在线曲目的歌词只能走 Provider 路由**，不得被"全局歌词源"接管。
///
/// 背景：本仓有两套歌词机制 ——
/// ① 在线路径：`OnlineMusicService.fetchLyrics(ref)`（按 `ref.platform` 路由到 Provider）；
/// ② 本地路径：`lib/services/online_lyric/` + `LyricSourceType` +
///    `AppSettings.preferredOnlineSource`（服务本地歌曲，本阶段明确不合并）。
///
/// 用户确认的禁止项（D9 / 补充口径⑧）：**不得出现"在线歌曲已带 platform，却无视来源、
/// 继续走全局 preferredOnlineSource"**。这里用与 `online_music_dependency_boundary_test`
/// 相同的源码扫描方式把它固定下来 —— 一旦有人把第二套机制接进在线路径，这个测试就会红。
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
    // 反向确认：真正属于本地歌词的目录仍然存在且独立（没有被搬进在线路径）。
    expect(Directory('lib/services/online_lyric').existsSync(), isTrue);
    expect(File('lib/lyric/lyric_source.dart').existsSync(), isTrue);
  });

  test('★ P-15 那三个旧歌词源类**零实例化**（一旦被接回任何路径立刻变红）', () {
    // 背景：`lib/services/online_lyric/sources/` 下的三个类在 F0 审计时就被发现
    // **全仓无人实例化**（只有日志字符串提到名字），但 `index.dart` 仍在导出它们。
    // 真正的清理（删死代码 / 合并两套子系统）属 F5 收口；本阶段只需要一条守卫：
    // **它们不得被实例化**——否则说明有人把废弃实现接回了某条路径。
    const sources = [
      'NetEaseSource',
      'QQSource',
      'KugouSource',
    ];
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final name in sources) {
        // 只看**构造调用**（`Name(`）：类声明与 import 都不带括号。
        if (source.contains('$name(')) {
          offenders.add('${entity.path}: $name(');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '废弃的歌词源实现被实例化了（要么接回了某条路径，要么该彻底删除）：'
          '\n${offenders.join('\n')}',
    );
  });

  test('★ P-15 本地歌词来源的两处 UI 文案必须写明**作用域**', () {
    // 这两个控件原本只写"首选歌词来源 / 默认在线源"，没有任何"只对本地歌曲生效"的说明
    // （而它确实只作用于本地库那一套）。那个控件此前也没有 widget 测试，
    // 因此这里用与依赖边界测试相同的**源码扫描**把文案固定下来：
    // 一旦有人删掉作用域说明，就会红。
    final source = readSource('lib/page/settings_page/settings_tabs.dart');

    expect(
      source,
      contains('仅本地歌曲'),
      reason: 'P-15：必须写明只对本地歌曲生效',
    );
    expect(
      source,
      contains('在线曲目的歌词按曲目所属平台获取，不受这里影响'),
      reason: 'P-15：必须说明在线曲目按平台取词，避免用户以为它决定所有歌曲',
    );
    expect(
      source,
      isNot(contains("description: '首选歌词来源',")),
      reason: 'P-15：不得留下**无作用域限定**的旧文案',
    );
    expect(
      source,
      isNot(contains("description: '默认在线源',")),
      reason: 'P-15：同上',
    );
  });
}
