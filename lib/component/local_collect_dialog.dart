import 'package:flutter/material.dart';
import 'package:pure_music/component/collect_playlist_dialog.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';

/// 居中「收藏到歌单」弹窗：选择或新建一个本地歌单并把 [audio] 加入其中。
Future<void> showLocalCollectDialog(
  BuildContext context, {
  required Audio audio,
}) async {
  final target = await showCollectPlaylistDialog<Playlist>(
    context: context,
    title: '收藏到歌单',
    choices: [
      for (final playlist in playlists)
        CollectPlaylistChoice(
          value: playlist,
          name: playlist.name,
          trackCount: playlist.paths.length,
          alreadyContained: playlist.containsPath(audio.path),
        ),
    ],
    onCreate: (name) async {
      if (hasEquivalentPlaylistName(
        existingNames: playlists.map((playlist) => playlist.name),
        targetName: name,
      )) {
        showTextOnSnackBar('该名称已存在', variant: ToastVariant.error);
        return null;
      }
      final playlist = await createPlaylist(name);
      playlists.add(playlist);
      return playlist;
    },
  );
  if (target == null || !context.mounted) return;

  if (target.containsPath(audio.path)) {
    showTextOnSnackBar('歌曲已在歌单中');
    return;
  }
  target.addPath(audio.path);
  final saved = await savePlaylists();
  if (!context.mounted) return;
  if (!saved) {
    target.removeByPath(audio.path);
    showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
    return;
  }
  showTextOnSnackBar('已添加到歌单', variant: ToastVariant.success);
}
