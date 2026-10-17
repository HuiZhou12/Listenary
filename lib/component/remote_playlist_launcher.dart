import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/services/music_platform/index.dart';

/// **"点封面 = 打开只读预览"的唯一入口**（2026-10-17 / F2 收口）。
///
/// 为什么要有它：同一个跳转此前在四个页面各拼一遍 `context.push(…)` 与那串 record
/// （探索页、榜单页、平台歌单页、主页 ✗）—— 少传一个字段（`ranked` / `creator`）
/// 就多一处"预览页显示的信息比卡片少"的细微不一致 ✓。
///
/// 约定：**只读**、一个字节都不写库 ✓；订阅一律由页面上的按钮触发 ✓。
/// 因为路由 `extra` 的字段是**位置无关的 record 类型**，改这里也保证了四处传同一套字段。
Future<void> openRemotePlaylistPreview(
  BuildContext context, {
  required MusicPlatform platform,
  required String playlistId,
  required String name,
  Uri? coverUri,
  String? creator,
  int? trackCount,
  bool ranked = false,
}) => context.push(
  app_paths.REMOTE_PLAYLIST_PAGE,
  extra: (
    platform: platform,
    playlistId: playlistId,
    name: name,
    coverUri: coverUri,
    creator: creator,
    trackCount: trackCount,
    ranked: ranked,
  ),
);

/// 用远端歌单摘要打开预览（探索页/榜单页手里的就是它）。
///
/// [ranked] 只对**名次集合**（榜单）为 true ✓ —— 普通歌单没有名次，不标序号 ✓。
Future<void> openRemotePlaylistSummaryPreview(
  BuildContext context,
  RemotePlaylistSummary summary, {
  bool ranked = false,
}) => openRemotePlaylistPreview(
  context,
  platform: summary.platform,
  playlistId: summary.id,
  name: summary.name,
  coverUri: summary.coverUri,
  creator: summary.creator,
  trackCount: summary.trackCount,
  ranked: ranked,
);
