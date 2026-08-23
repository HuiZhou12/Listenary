import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

class PersonalPlaylistDetailPage extends StatefulWidget {
  const PersonalPlaylistDetailPage({super.key, required this.localId});

  final int localId;

  @override
  State<PersonalPlaylistDetailPage> createState() =>
      _PersonalPlaylistDetailPageState();
}

class _PersonalPlaylistDetailPageState
    extends State<PersonalPlaylistDetailPage> {
  PersonalOnlinePlaylistSnapshot? _snapshot;
  String? _error;
  bool _loading = true;
  bool _sorting = false;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PersonalOnlinePlaylistController>().loadFavorites();
    });
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await context
          .read<PersonalOnlinePlaylistController>()
          .readSnapshot(widget.localId);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _error = snapshot == null ? '歌单不存在或已被删除' : null;
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _error = '无法读取歌单';
      });
    }
  }

  Future<void> _refresh() async {
    final snapshot = await context
        .read<PersonalOnlinePlaylistController>()
        .readSnapshot(widget.localId);
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
  }

  Future<void> _play(MusicTrack track) async {
    final selection = await context
        .read<PersonalOnlinePlaylistController>()
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

  Future<void> _removeTrack(PlatformTrackRef ref) async {
    final removed = await context
        .read<PersonalOnlinePlaylistController>()
        .removeTrack(widget.localId, ref);
    if (!mounted) return;
    if (removed) {
      await _refresh();
    } else {
      showTextOnSnackBar('移除失败', variant: ToastVariant.error);
    }
  }

  Future<void> _rename() async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenamePlaylistDialog(currentName: snapshot.name),
    );
    if (name == null || !mounted) return;
    final renamed = await context
        .read<PersonalOnlinePlaylistController>()
        .rename(widget.localId, name);
    if (!mounted) return;
    if (renamed) {
      await _refresh();
    } else {
      showTextOnSnackBar('重命名失败（名称可能已存在）', variant: ToastVariant.error);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '删除我的在线歌单？',
      message: '将删除歌单“${_snapshot?.name ?? ''}”及其本地保存的在线曲目引用。',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    final deleted = await context
        .read<PersonalOnlinePlaylistController>()
        .delete(widget.localId);
    if (!mounted) return;
    if (deleted) {
      Navigator.of(context).pop();
    } else {
      showTextOnSnackBar('删除失败', variant: ToastVariant.error);
    }
  }

  Future<void> _commitReorder(int oldIndex, int newIndex) async {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final tracks = [...snapshot.tracks];
    final moved = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, moved);
    final reordered = await context
        .read<PersonalOnlinePlaylistController>()
        .reorder(widget.localId, tracks.map((track) => track.ref).toList());
    if (!mounted) return;
    if (reordered) {
      await _refresh();
    } else {
      showTextOnSnackBar('排序保存失败', variant: ToastVariant.error);
    }
  }

  Widget _buildTrackRow(MusicTrack track, {bool animated = true}) {
    final playable =
        track.availability != TrackAvailability.unavailable &&
        track.availability != TrackAvailability.paid;
    final details = [
      if (track.artistDisplay.isNotEmpty) track.artistDisplay,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');
    final favorites = context.watch<PersonalOnlinePlaylistController>();
    final row = OnlineTrackRow(
      track: track,
      details: details,
      enabled: playable,
      onTap: playable ? () => _play(track) : null,
      onRemove: () => _removeTrack(track.ref),
      showFavorite: true,
      favorite: favorites.isFavorite(track.ref),
      onToggleFavorite: () => favorites.toggleFavorite(track),
    );
    if (!animated) return row;
    return DirectionalListItemEntrance(identity: track.ref, child: row);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    if (snapshot != null && _error == null) {
      return _buildLoadedPage(snapshot);
    }
    return PageScaffold(
      title: snapshot?.name ?? '我的在线歌单',
      subtitle: snapshot == null
          ? null
          : '${snapshot.tracks.length} 首歌曲 · 我的在线歌单',
      actions: const [],
      body: _buildStatusBody(snapshot),
    );
  }

  Widget _buildStatusBody(PersonalOnlinePlaylistSnapshot? snapshot) {
    if (_loading) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return QuietEmptyState(
      icon: Symbols.cloud_off,
      title: '歌单读取失败',
      message: _error ?? '无法读取歌单',
      action: FilledButton.tonalIcon(
        onPressed: _load,
        icon: const Icon(Symbols.refresh),
        label: const Text('重试'),
      ),
    );
  }

  Widget _buildLoadedPage(PersonalOnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = snapshot.tracks;
    return ColoredBox(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildHeader(snapshot),
            const SizedBox(height: 16),
            Expanded(
              child: tracks.isEmpty
                  ? const QuietEmptyState(
                      icon: Symbols.music_off,
                      title: '歌单还没有曲目',
                      message: '从在线搜索、播放历史或订阅歌单中添加。',
                    )
                  : Material(
                      type: MaterialType.transparency,
                      borderRadius: AppRadius.smCircular,
                      child: _sorting
                          ? ReorderableListView.builder(
                              padding: const EdgeInsets.only(bottom: 96),
                              itemCount: tracks.length,
                              onReorderItem: _commitReorder,
                              itemBuilder: (context, index) {
                                final track = tracks[index];
                                return KeyedSubtree(
                                  key: ValueKey(
                                    'personal-${track.ref.platform.name}-${track.ref.trackId}',
                                  ),
                                  child: _buildTrackRow(track, animated: false),
                                );
                              },
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 96),
                              itemCount: tracks.length,
                              itemBuilder: (context, index) =>
                                  _buildTrackRow(tracks[index]),
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(PersonalOnlinePlaylistSnapshot snapshot) {
    final scheme = Theme.of(context).colorScheme;
    final playable = snapshot.tracks.where(
      (track) =>
          track.availability != TrackAvailability.unavailable &&
          track.availability != TrackAvailability.paid,
    );
    final hasPlayableTracks = playable.isNotEmpty;
    Uri? cover;
    for (final track in snapshot.tracks) {
      final uri = track.coverUri;
      if (uri != null) {
        cover = uri;
        break;
      }
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth.isFinite && constraints.maxWidth < 560;
        final coverSize = compact ? 156.0 : 200.0;
        final gap = compact ? 12.0 : 16.0;
        final metadata = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    snapshot.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? AppType.pageTitle : AppType.hero,
                      fontWeight: AppType.weightBold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Symbols.edit, size: 18, color: scheme.primary),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${snapshot.tracks.length} 首歌曲 · 我的在线歌单',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: hasPlayableTracks
                      ? () => _play(playable.first)
                      : null,
                  icon: const Icon(Symbols.play_arrow),
                  label: const Text('播放全部'),
                ),
                IconButton.filledTonal(
                  tooltip: '随机播放',
                  onPressed: hasPlayableTracks
                      ? () => _playRandom(snapshot.tracks)
                      : null,
                  icon: const Icon(Symbols.shuffle),
                ),
                IconButton.filledTonal(
                  tooltip: _sorting ? '完成排序' : '排序',
                  onPressed: snapshot.tracks.isEmpty
                      ? null
                      : () => setState(() => _sorting = !_sorting),
                  icon: Icon(_sorting ? Symbols.check : Symbols.swap_vert),
                ),
                IconButton.filledTonal(
                  tooltip: '重命名',
                  onPressed: _rename,
                  icon: const Icon(Symbols.edit),
                ),
                IconButton.filledTonal(
                  tooltip: '删除歌单',
                  onPressed: _delete,
                  color: scheme.error,
                  icon: const Icon(Symbols.delete),
                ),
              ],
            ),
          ],
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ClipRRect(
              borderRadius: AppRadius.smCircular,
              child: SizedBox.square(
                dimension: coverSize,
                child: RemoteMediaCover(
                  coverUri: cover,
                  placeholder: ColoredBox(
                    color: scheme.surfaceContainer,
                    child: Icon(
                      Symbols.queue_music,
                      size: 48,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  cacheWidth: (coverSize * 2).round(),
                  cacheHeight: (coverSize * 2).round(),
                ),
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: compact
                  ? metadata
                  : SizedBox(
                      height: coverSize,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: metadata,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _RenamePlaylistDialog extends StatefulWidget {
  const _RenamePlaylistDialog({required this.currentName});

  final String currentName;

  @override
  State<_RenamePlaylistDialog> createState() => _RenamePlaylistDialogState();
}

class _RenamePlaylistDialogState extends State<_RenamePlaylistDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty || name == widget.currentName) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名歌单'),
      content: TextField(
        autofocus: true,
        controller: _controller,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(labelText: '歌单名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确认')),
      ],
    );
  }
}
