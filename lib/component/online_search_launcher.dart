import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/index.dart';

Future<void> showApplicationSearch(
  BuildContext context, {
  bool initialOnline = false,
}) {
  return SearchDialog.show(
    context,
    initialOnline: initialOnline,
    onOnlineTrackSelected: (selection) async {
      final queue = context.read<RemotePlaybackQueue>();
      final controller = context.read<RemotePlaybackSessionController>();
      queue.replace(selection.tracks.map(RemotePlaybackQueueItem.fromTrack));
      try {
        await controller.play(
          selection.selectedIndex,
          requestedQuality: NeteaseAdapter.defaultQuality,
        );
      } on RemoteStreamPlaybackException catch (error) {
        if (error.kind != RemoteStreamPlaybackErrorKind.cancelled) {
          showTextOnSnackBar(error.safeMessage, variant: ToastVariant.error);
        }
      } on ChkszException catch (error) {
        if (error.kind != ChkszErrorKind.cancelled) {
          showTextOnSnackBar(error.safeMessage, variant: ToastVariant.error);
        }
      } catch (_) {
        showTextOnSnackBar('无法播放远程曲目', variant: ToastVariant.error);
      }
    },
  );
}
