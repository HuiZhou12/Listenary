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
}
