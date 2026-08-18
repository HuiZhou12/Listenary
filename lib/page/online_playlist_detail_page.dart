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
      final snapshot = await context.read<OnlinePlaylistController>().readSnapshot(
        widget.localId,
      );
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

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return PageScaffold(
      title: snapshot?.playlist.name ?? '在线歌单',
      subtitle: snapshot == null
          ? null
          : '${snapshot.playlist.trackCount ?? snapshot.playlist.tracks.length} 首歌曲 · 只读订阅',
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
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: snapshot.playlist.tracks.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildHeader(snapshot);
        final track = snapshot.playlist.tracks[index - 1];
        final playable = track.availability != TrackAvailability.unavailable &&
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
      },
    );
  }

  Widget _buildHeader(OnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: AppRadius.smCircular,
            child: SizedBox.square(
              dimension: 72,
              child: RemoteMediaCover(
                coverUri: snapshot.playlist.coverUri,
                placeholder: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Symbols.cloud, color: scheme.onSurfaceVariant),
                ),
                cacheWidth: 144,
                cacheHeight: 144,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  snapshot.playlist.creator ?? '网易在线歌单',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                Text(
                  '仅保存本地快照，曲目播放时重新解析',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
