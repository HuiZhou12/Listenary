import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/index.dart';

final class OnlineTrackSelection {
  OnlineTrackSelection({
    required Iterable<MusicTrack> tracks,
    required this.selectedIndex,
  }) : tracks = List.unmodifiable(tracks);

  factory OnlineTrackSelection.fromResultPage({
    required Iterable<MusicTrack> tracks,
    required PlatformTrackRef selectedRef,
  }) {
    final playableTracks = tracks
        .where(
          (track) =>
              track.availability != TrackAvailability.unavailable &&
              track.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    final selectedIndex = playableTracks.indexWhere(
      (track) => track.ref == selectedRef,
    );
    if (selectedIndex < 0) {
      throw ArgumentError.value(selectedRef, 'selectedRef');
    }
    return OnlineTrackSelection(
      tracks: playableTracks,
      selectedIndex: selectedIndex,
    );
  }

  final List<MusicTrack> tracks;
  final int selectedIndex;

  MusicTrack get selectedTrack => tracks[selectedIndex];
}

Future<void> showApplicationSearch(BuildContext context) {
  return SearchDialog.show(context);
}

Future<void> playOnlineSearchResult(
  BuildContext context, {
  required Iterable<MusicTrack> tracks,
  required PlatformTrackRef selectedRef,
}) {
  return playOnlineTrackSelection(
    context,
    OnlineTrackSelection.fromResultPage(
      tracks: tracks,
      selectedRef: selectedRef,
    ),
  );
}

Future<void> playOnlineTrackSelection(
  BuildContext context,
  OnlineTrackSelection selection,
) async {
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
}
