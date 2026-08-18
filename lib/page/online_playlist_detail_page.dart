import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

class OnlinePlaylistDetailPage extends StatefulWidget {
  const OnlinePlaylistDetailPage({super.key, required this.localId});

  final int localId;

  @override
  State<OnlinePlaylistDetailPage> createState() =>
      _OnlinePlaylistDetailPageState();
}

class _OnlinePlaylistDetailPageState extends State<OnlinePlaylistDetailPage> {
  OnlinePlaylistSnapshot? _snapshot;
  String? _error;
  bool _loading = true;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await context
          .read<OnlinePlaylistController>()
          .readSnapshot(widget.localId);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _error = snapshot == null ? '在线歌单不存在或已被删除' : null;
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _error = '无法读取在线歌单';
      });
    }
  }

  Future<void> _play(MusicTrack track) async {
    final selection = await context
        .read<OnlinePlaylistController>()
        .playbackSelection(localId: widget.localId, selectedRef: track.ref);
    if (!mounted || selection == null) return;
    await playOnlineTrackSelection(
      context,
      OnlineTrackSelection(
        tracks: selection.tracks,
        selectedIndex: selection.selectedIndex,
      ),
    );
  }

  Future<void> _playRandom(Iterable<MusicTrack> tracks) async {
    final playable = tracks
        .where(
          (track) =>
              track.availability != TrackAvailability.unavailable &&
              track.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    if (playable.isEmpty) return;
    await _play(playable[math.Random().nextInt(playable.length)]);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return PageScaffold(
      title: snapshot?.playlist.name ?? '在线歌单',
      subtitle: snapshot == null
          ? null
          : '${snapshot.playlist.trackCount ?? snapshot.playlist.tracks.length} 首歌曲 · 网易订阅',
      actions: [
        IconButton.filledTonal(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: _buildBody(snapshot),
    );
  }

  Widget _buildBody(OnlinePlaylistSnapshot? snapshot) {
    if (_loading) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null || snapshot == null) {
      return QuietEmptyState(
        icon: Symbols.cloud_off,
        title: '在线歌单读取失败',
        message: _error ?? '无法读取在线歌单',
        action: FilledButton.tonalIcon(
          onPressed: _load,
          icon: const Icon(Symbols.refresh),
          label: const Text('重试'),
        ),
      );
    }
    if (snapshot.playlist.tracks.isEmpty) {
      return const QuietEmptyState(
        icon: Symbols.music_off,
        title: '歌单没有可用曲目',
        message: '刷新后会重新读取第三方平台的完整快照。',
      );
    }
    final tracks = snapshot.playlist.tracks;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: tracks.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) return _buildHeader(snapshot);
        if (index == 1) return const SizedBox(height: 12);
        return _buildTrackRow(tracks[index - 2]);
      },
    );
  }

  Widget _buildTrackRow(MusicTrack track) {
    final playable =
        track.availability != TrackAvailability.unavailable &&
        track.availability != TrackAvailability.paid;
    final details = [
      if (track.artistDisplay.isNotEmpty) track.artistDisplay,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    return DirectionalListItemEntrance(
      identity: track.ref,
      child: OnlineTrackRow(
        track: track,
        details: details,
        enabled: playable,
        onTap: playable ? () => _play(track) : null,
      ),
    );
  }

  Widget _buildHeader(OnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final playable = snapshot.playlist.tracks.where(
      (track) =>
          track.availability != TrackAvailability.unavailable &&
          track.availability != TrackAvailability.paid,
    );
    final hasPlayableTracks = playable.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.mdCircular,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: AppRadius.mdCircular,
            child: SizedBox.square(
              dimension: 176,
              child: RemoteMediaCover(
                coverUri: snapshot.playlist.coverUri,
                placeholder: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Symbols.cloud,
                    size: 48,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                cacheWidth: 352,
                cacheHeight: 352,
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 176),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          snapshot.playlist.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Symbols.cloud, size: 20, color: scheme.primary),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Symbols.account_circle,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          snapshot.playlist.creator ?? '网易用户',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${snapshot.playlist.trackCount ?? snapshot.playlist.tracks.length} 首歌曲 · 只读订阅',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: hasPlayableTracks
                            ? () => _play(playable.first)
                            : null,
                        icon: const Icon(Symbols.play_arrow),
                        label: const Text('播放全部'),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: '随机播放',
                        onPressed: hasPlayableTracks
                            ? () => _playRandom(snapshot.playlist.tracks)
                            : null,
                        icon: const Icon(Symbols.shuffle),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
