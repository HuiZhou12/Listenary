import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/collect_playlist_dialog.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

/// 居中「收藏到歌单」弹窗：选择或新建一个我的在线歌单并把 [track] 加入其中。
Future<void> showPersonalPlaylistPicker(
  BuildContext context, {
  required MusicTrack track,
}) async {
  final controller = context.read<PersonalOnlinePlaylistController>();
  if (controller.snapshot.status == PersonalOnlinePlaylistStatus.idle) {
    await controller.load();
  }
  if (!context.mounted) return;
  final localId = await showCollectPlaylistDialog<int>(
    context: context,
    title: '收藏到歌单',
    choices: [
      for (final playlist in controller.snapshot.playlists)
        CollectPlaylistChoice(
          value: playlist.localId,
          name: playlist.name,
          trackCount: playlist.tracks.length,
          alreadyContained: playlist.tracks.any((t) => t.ref == track.ref),
        ),
    ],
    onCreate: (name) => controller.create(name),
  );
  if (localId == null || !context.mounted) return;
  final added = await controller.addTrack(localId, track);
  if (added) {
    showTextOnSnackBar('已添加到歌单', variant: ToastVariant.success);
  }
}
