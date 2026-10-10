/// 「添加在线歌单（订阅）」这条链路共用的**来源平台解析**与 **ID 校验**。
///
/// 为什么单独一个文件：两个页面（`online_playlists_page`、`playlists_page`）都要做同一件事 ——
/// 让用户选一个**真的能提供歌单详情**的平台，并把 `(platform, id)` 这对来源身份交给控制器。
/// 规则只写一份，避免两处慢慢走偏（多平台聚合的 I1：来源身份从 UI 开始就不能丢）。
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';

export 'package:pure_music/component/online_playlist_draft.dart';

/// 可选的来源平台（顺序 = `builtinMusicPlatforms`）。
///
/// 门槛来自服务层：`capabilities.playlistPlatforms` 只包含"真的有歌单详情候选"的平台
/// （未配置 / 未启用的平台不会伪装成可用）。
///
/// 组件级测试可能没有注册在线音乐 provider，此时回落到默认的网易云 ——
/// 那是**单平台时代的行为**，保证已有界面与测试不变。
List<MusicPlatform> onlinePlaylistPlatformsOf(BuildContext context) {
  final service = context.read<OnlineMusicService?>();
  if (service == null) return const [MusicPlatform.netease];
  final available = service.capabilities.playlistPlatforms;
  return [
    for (final platform in builtinMusicPlatforms)
      if (available.contains(platform)) platform,
  ];
}

/// 校验用户输入的远端歌单 ID；返回 null 表示可用。
///
/// 形状由平台自己决定：已知的网易云歌单 ID 是纯数字，因此对它做数字校验；
/// **其它平台（尤其是自建声明式服务）不做形状假设**，只要求非空白 ——
/// 对不对由试跑/抓取时的真实错误回答（Spec §19.5 的"未知服务"口径）。
String? validateOnlinePlaylistId(MusicPlatform platform, String value) {
  if (value.isEmpty) return '请填写歌单 ID';
  if (RegExp(r'\s').hasMatch(value)) return '歌单 ID 不能包含空白';
  if (platform == MusicPlatform.netease &&
      !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
    return '网易云歌单 ID 是数字';
  }
  return null;
}
