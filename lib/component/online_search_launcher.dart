import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/search_dialog.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';

final class OnlineTrackSelection {
  OnlineTrackSelection({
    required Iterable<MusicTrack> tracks,
    required this.selectedIndex,
    this.requestedQuality,
  }) : tracks = List.unmodifiable(tracks);

  /// 从"结果页的一批曲目"里发起播放 ✓。
  ///
  /// **[onlyPlayable]**（2026-10-12 新增）：默认仍按内容平台声明的 `availability` 过滤 ✓
  ///（老调用点语义不变 ✓）。但**内容平台的标记不等于能不能播** ✗ ——
  /// 播放解析（`stream`）是**独立能力、可以路由到另一个平台** ✓（用户指出的正是这一点 ✓）。
  /// ⇒ 已经按"**解析权限在哪个平台**"（`capabilities.canResolveIdentity` ✓）筛过的调用方，
  /// 传 `onlyPlayable: false` ✓，别再拿内容平台的标记二次过滤 ✗。
  factory OnlineTrackSelection.fromResultPage({
    required Iterable<MusicTrack> tracks,
    required PlatformTrackRef selectedRef,
    bool onlyPlayable = true,
  }) {
    final playableTracks = onlyPlayable
        ? tracks
              .where(
                (track) =>
                    track.availability != TrackAvailability.unavailable &&
                    track.availability != TrackAvailability.paid,
              )
              .toList(growable: false)
        : List<MusicTrack>.unmodifiable(tracks);
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
  final String? requestedQuality;

  MusicTrack get selectedTrack => tracks[selectedIndex];

  factory OnlineTrackSelection.fromHistory({
    required Iterable<OnlineHistoryEntry> entries,
    required PlatformTrackRef selectedRef,
  }) {
    final history = List<OnlineHistoryEntry>.unmodifiable(entries);
    final selectedEntry = history.firstWhere(
      (entry) => entry.track.ref == selectedRef,
      orElse: () => throw ArgumentError.value(selectedRef, 'selectedRef'),
    );
    final selection = OnlineTrackSelection.fromResultPage(
      tracks: history.map((entry) => entry.track),
      selectedRef: selectedRef,
    );
    return OnlineTrackSelection(
      tracks: selection.tracks,
      selectedIndex: selection.selectedIndex,
      requestedQuality: selectedEntry.lastQuality,
    );
  }
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

Future<void> playOnlineHistoryEntry(
  BuildContext context, {
  required Iterable<OnlineHistoryEntry> entries,
  required PlatformTrackRef selectedRef,
}) {
  return playOnlineTrackSelection(
    context,
    OnlineTrackSelection.fromHistory(
      entries: entries,
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
  if (shouldReuseActiveOnlineTrack(
    state: controller.controlState.state,
    currentRef: queue.value.currentItem?.ref,
    selectedRef: selection.selectedTrack.ref,
  )) {
    return;
  }
  queue.replace(selection.tracks.map(RemotePlaybackQueueItem.fromTrack));
  try {
    await controller.play(
      selection.selectedIndex,
      requestedQuality:
          controller.requestedQuality ??
          selection.requestedQuality ??
          context
              .read<OnlineMusicService>()
              .defaultQualityFor(selection.selectedTrack.ref.platform),
    );
  } on RemoteStreamPlaybackException catch (error) {
    if (error.kind != RemoteStreamPlaybackErrorKind.cancelled) {
      showTextOnSnackBar(error.safeMessage, variant: ToastVariant.error);
    }
  } on OnlineMusicException catch (error) {
    if (error.kind != OnlineMusicErrorKind.cancelled) {
      showTextOnSnackBar(error.safeMessage, variant: ToastVariant.error);
    }
  } catch (_) {
    showTextOnSnackBar('无法播放远程曲目', variant: ToastVariant.error);
  }
}

@visibleForTesting
bool shouldReuseActiveOnlineTrack({
  required PlaybackBackendState? state,
  required PlatformTrackRef? currentRef,
  required PlatformTrackRef selectedRef,
}) =>
    currentRef == selectedRef &&
    switch (state) {
      PlaybackBackendState.opening ||
      PlaybackBackendState.playing ||
      PlaybackBackendState.paused ||
      PlaybackBackendState.stalled ||
      PlaybackBackendState.completed => true,
      PlaybackBackendState.stopped ||
      PlaybackBackendState.failed ||
      null => false,
    };
