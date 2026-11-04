import 'package:flutter/material.dart';
import 'package:pure_music/component/search_dialog.dart';

// 起播链路（`OnlineTrackSelection` / `playOnlineSearchResult` /
// `playOnlineHistoryEntry` / `playOnlineTrackSelection` /
// `shouldReuseActiveOnlineTrack`）已拆到 `online_playback_launcher.dart`：
// 那个文件不需要打开搜索弹窗，拆开后 `search_dialog → online_search_panel →
// online_playback_launcher` 是单向的，不再与 `lib/component/` 同层循环。
//
// 这里 re-export ⇒ **既有调用点的 import 一个字都不用改**。
export 'package:pure_music/component/online_playback_launcher.dart';

/// 打开应用级搜索弹窗（本地 / 在线两种来源，同一入口）。
///
/// [initialSource] 默认「本地」（D3 已拍板）：标题栏搜索按钮就是默认走这里。
/// 切换来源由弹窗自己承接；调用方只在确实要预选在线时才传 `online`。
Future<void> showApplicationSearch(
  BuildContext context, {
  SearchSource initialSource = SearchSource.local,
}) {
  return SearchDialog.show(context, initialSource: initialSource);
}
