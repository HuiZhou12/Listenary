import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/page/uni_page.dart';
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
  String _searchQuery = '';
  Future<ImageProvider?> _primaryPicFuture = Future.value(null);

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
        _primaryPicFuture = _firstCoverProvider(snapshot);
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _error = '无法读取歌单';
      });
    }
  }

  Future<ImageProvider?> _firstCoverProvider(
    PersonalOnlinePlaylistSnapshot? snapshot,
  ) async {
    final snapshotLocal = snapshot;
    if (snapshotLocal == null) return null;
    for (final track in snapshotLocal.tracks) {
      final uri = track.coverUri;
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        return CachedRemoteImageProvider(uri.toString());
      }
    }
    return null;
  }

  Future<void> _refresh() async {
    final snapshot = await context
        .read<PersonalOnlinePlaylistController>()
        .readSnapshot(widget.localId);
    if (!mounted) return;
    setState(() {
      _snapshot = snapshot;
      _primaryPicFuture = _firstCoverProvider(snapshot);
    });
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
      if (snapshot.tracks.isEmpty) {
        return Scaffold(
          body: PageScaffold(
            title: snapshot.name,
            actions: const [],
            body: const QuietEmptyState(
              icon: Symbols.music_off,
              title: '歌单还没有曲目',
              message: '从在线搜索、播放历史或订阅歌单中添加。',
            ),
          ),
        );
      }
      return Scaffold(body: _buildLoadedPage(snapshot));
    }
    return Scaffold(
      body: PageScaffold(
        title: snapshot?.name ?? '我的在线歌单',
        actions: const [],
        body: _buildStatusBody(),
      ),
    );
  }

  Widget _buildStatusBody() {
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
    final allTracks = snapshot.tracks;
    final query = _searchQuery.toLowerCase();
    final tracks = _searchQuery.isEmpty
        ? List<MusicTrack>.from(allTracks)
        : allTracks
              .where(
                (t) =>
                    t.title.toLowerCase().contains(query) ||
                    t.artistDisplay.toLowerCase().contains(query) ||
                    t.album.toLowerCase().contains(query),
              )
              .toList(growable: false);
    final playable = allTracks
        .where(
          (track) =>
              track.availability != TrackAvailability.unavailable &&
              track.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    final scheme = Theme.of(context).colorScheme;
    final pref = AppPreference.instance.playlistDetailPagePref;
    final sortMethods = _sortMethods();
    final currMethodIndex = pref.sortMethod
        .clamp(0, sortMethods.length - 1)
        .toInt();
    final isCustomSort = currMethodIndex == sortMethods.length - 1;
    final canSortTracks = hasEnoughItemsToSort(tracks.length);
    final canReorder = canSortTracks && isCustomSort;
    const primaryActionStyle = ButtonStyle(
      fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
    );
    return UniDetailPage<PersonalOnlinePlaylistSnapshot, MusicTrack, Object>(
      pref: AppPreference.instance.playlistDetailPagePref,
      primaryContent: snapshot,
      primaryPic: _primaryPicFuture,
      backgroundPic: Future.value(null),
      picShape: PicShape.rrect,
      title: snapshot.name,
      subtitle: '${snapshot.tracks.length} 首歌曲 · 我的在线歌单',
      secondaryContent: tracks,
      secondaryContentBuilder: (context, track, index, msc, view) =>
          _buildTrackRow(track),
      enableShufflePlay: false,
      enableSortMethod: canSortTracks,
      enableSortOrder: canSortTracks,
      sortMethods: sortMethods,
      enableSecondaryContentViewSwitch: true,
      enableSearch: true,
      searchQuery: _searchQuery,
      onSearchChanged: (v) => setState(() => _searchQuery = v),
      onSortMethodChanged: () => setState(() => _sorting = false),
      extraActions: [
        FilledButton.icon(
          onPressed: playable.isEmpty ? null : () => _playRandom(tracks),
          icon: const Icon(Symbols.shuffle, size: 20),
          label: const Text('随机播放'),
          style: primaryActionStyle,
        ),
        if (canReorder)
          FilledButton.tonalIcon(
            onPressed: tracks.isEmpty
                ? null
                : () => setState(() => _sorting = !_sorting),
            icon: Icon(_sorting ? Symbols.check : Symbols.reorder, size: 20),
            label: Text(_sorting ? '完成' : '排序'),
            style: ButtonStyle(
              fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40)),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 16),
              ),
              backgroundColor: WidgetStatePropertyAll(
                _sorting ? scheme.tertiaryContainer : scheme.secondaryContainer,
              ),
              foregroundColor: WidgetStatePropertyAll(
                _sorting
                    ? scheme.onTertiaryContainer
                    : scheme.onSecondaryContainer,
              ),
            ),
          ),
      ],
      bodyOverride: _sorting ? _buildReorderBody(tracks) : null,
    );
  }

  List<SortMethodDesc<MusicTrack>> _sortMethods() {
    return [
      SortMethodDesc<MusicTrack>(
        icon: Symbols.title,
        name: '标题',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort((a, b) => a.title.naturalCompareTo(b.title));
              break;
            case SortOrder.decending:
              list.sort((a, b) => b.title.naturalCompareTo(a.title));
              break;
          }
        },
      ),
      SortMethodDesc<MusicTrack>(
        icon: Symbols.artist,
        name: '艺术家',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort(
                (a, b) => a.artistDisplay.naturalCompareTo(b.artistDisplay),
              );
              break;
            case SortOrder.decending:
              list.sort(
                (a, b) => b.artistDisplay.naturalCompareTo(a.artistDisplay),
              );
              break;
          }
        },
      ),
      SortMethodDesc<MusicTrack>(
        icon: Symbols.album,
        name: '专辑',
        method: (list, order) {
          switch (order) {
            case SortOrder.ascending:
              list.sort((a, b) => a.album.naturalCompareTo(b.album));
              break;
            case SortOrder.decending:
              list.sort((a, b) => b.album.naturalCompareTo(a.album));
              break;
          }
        },
      ),
      SortMethodDesc<MusicTrack>(
        icon: Symbols.drag_indicator,
        name: '自定义',
        method: (list, order) {},
      ),
    ];
  }

  Widget _buildReorderBody(List<MusicTrack> tracks) {
    return ReorderableListView.builder(
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
    );
  }
}
