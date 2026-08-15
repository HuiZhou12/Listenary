import 'dart:async';

import 'package:pure_music/component/album_tile.dart';
import 'package:pure_music/component/artist_tile.dart';
import 'package:pure_music/component/audio_tile.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/search_dialog_layout.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/list_action_state.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/library/union_search_result.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return QuietEmptyState(
      icon: icon,
      title: title,
      message: message,
      action: action,
      maxWidth: 380.0,
    );
  }
}

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

class SearchDialog extends StatefulWidget {
  const SearchDialog({super.key, this.onOnlineTrackSelected});

  final ValueChanged<OnlineTrackSelection>? onOnlineTrackSelected;

  static Future<void> show(
    BuildContext context, {
    ValueChanged<OnlineTrackSelection>? onOnlineTrackSelected,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) =>
          SearchDialog(onOnlineTrackSelected: onOnlineTrackSelected),
    );
  }

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchCategory {
  final String label;
  final IconData icon;
  const _SearchCategory(this.label, this.icon);
}

enum _OnlineSearchStatus { idle, loading, success, empty, error }

class _SearchDialogState extends State<SearchDialog> {
  late final TextEditingController _searchController = TextEditingController();
  late final ValueNotifier<UnionSearchResult> _result = ValueNotifier(
    UnionSearchResult(''),
  );
  late final ValueNotifier<bool> _isSearching = ValueNotifier(false);
  Timer? _debounce;
  Timer? _queuedNextResetTimer;
  Audio? _queuedNextAudio;
  Audio? _addingAudioToPlaylist;
  Playlist? _addingTargetPlaylist;
  int _currentIndex = 0;
  int _searchVersion = 0;
  int _onlineRequestVersion = 0;
  _OnlineSearchStatus _onlineStatus = _OnlineSearchStatus.idle;
  MusicSearchPage? _onlinePage;
  ChkszException? _onlineError;
  ChkszCancelToken? _onlineCancelToken;
  String _onlineQuery = '';

  static const _tabs = [
    _SearchCategory('音乐', Symbols.music_note),
    _SearchCategory('艺术家', Symbols.person),
    _SearchCategory('专辑', Symbols.album),
    _SearchCategory('在线', Symbols.cloud),
  ];

  bool get _isOnlineTab => _currentIndex == _tabs.length - 1;

  @override
  void dispose() {
    _debounce?.cancel();
    _queuedNextResetTimer?.cancel();
    _onlineCancelToken?.cancel();
    _searchController.dispose();
    _result.dispose();
    _isSearching.dispose();
    super.dispose();
  }

  void _onQueryChanged(String raw) {
    final query = normalizedSearchQuery(raw);
    _debounce?.cancel();
    if (_isOnlineTab) {
      _resetOnlineSearch();
      return;
    }
    if (query.isEmpty) {
      _result.value = UnionSearchResult('');
      _isSearching.value = false;
      return;
    }

    _isSearching.value = true;
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _searchVersion++;
      _search(query);
      _isSearching.value = false;
    });
  }

  void _search(String query) {
    final scope = SearchScope.values[_currentIndex];
    _result.value = UnionSearchResult.search(query, scope: scope);
  }

  void _resetOnlineSearch({bool notify = true}) {
    _onlineCancelToken?.cancel();
    _onlineCancelToken = null;
    _onlineRequestVersion++;
    _onlineStatus = _OnlineSearchStatus.idle;
    _onlinePage = null;
    _onlineError = null;
    _onlineQuery = '';
    if (notify && mounted) setState(() {});
  }

  Future<void> _submitOnlineSearch() async {
    final query = normalizedSearchQuery(_searchController.text);
    if (query.isEmpty) {
      _resetOnlineSearch();
      return;
    }

    _onlineCancelToken?.cancel();
    final token = ChkszCancelToken();
    final requestVersion = ++_onlineRequestVersion;
    _onlineCancelToken = token;
    setState(() {
      _onlineStatus = _OnlineSearchStatus.loading;
      _onlinePage = null;
      _onlineError = null;
      _onlineQuery = query;
    });

    try {
      final page = await context.read<ChkszRuntime>().searchNetease(
        keyword: query,
        limit: 30,
        offset: 0,
        cancelToken: token,
      );
      if (!mounted || requestVersion != _onlineRequestVersion) return;
      setState(() {
        _onlinePage = page;
        _onlineStatus = page.items.isEmpty
            ? _OnlineSearchStatus.empty
            : _OnlineSearchStatus.success;
      });
    } on ChkszException catch (error) {
      if (!mounted || requestVersion != _onlineRequestVersion) return;
      if (error.kind == ChkszErrorKind.cancelled) {
        setState(() => _onlineStatus = _OnlineSearchStatus.idle);
        return;
      }
      setState(() {
        _onlineError = error;
        _onlineStatus = _OnlineSearchStatus.error;
      });
    } catch (_) {
      if (!mounted || requestVersion != _onlineRequestVersion) return;
      setState(() {
        _onlineError = const ChkszException(
          kind: ChkszErrorKind.unknown,
          safeMessage: '音乐服务请求失败',
        );
        _onlineStatus = _OnlineSearchStatus.error;
      });
    } finally {
      if (requestVersion == _onlineRequestVersion) {
        _onlineCancelToken = null;
      }
    }
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    if (_isOnlineTab) {
      _resetOnlineSearch();
      return;
    }
    _result.value = UnionSearchResult('');
    _isSearching.value = false;
  }

  void _switchCategory(int index) {
    if (_isOnlineTab) _resetOnlineSearch(notify: false);
    _debounce?.cancel();
    setState(() => _currentIndex = index);

    final query = normalizedSearchQuery(_searchController.text);
    if (_isOnlineTab || query.isEmpty) return;
    _searchVersion++;
    _search(query);
    _isSearching.value = false;
  }

  void _addSearchResultToNext(Audio audio) {
    PlayService.instance.playbackService.addToNext(audio);
    _queuedNextResetTimer?.cancel();
    setState(() => _queuedNextAudio = audio);
    _queuedNextResetTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() => _queuedNextAudio = null);
    });
  }

  Future<void> _addSearchResultToPlaylist(
    Audio audio,
    Playlist playlist,
  ) async {
    if (_addingAudioToPlaylist != null) {
      return;
    }

    final added = playlist.containsPath(audio.path);
    if (added) {
      showTextOnSnackBar('歌曲已在歌单中');
      return;
    }

    setState(() {
      _addingAudioToPlaylist = audio;
      _addingTargetPlaylist = playlist;
    });
    try {
      playlist.addPath(audio.path);
      final saved = await savePlaylists();
      if (!mounted) return;
      if (!saved) {
        playlist.removeByPath(audio.path);
        showTextOnSnackBar('保存歌单失败', variant: ToastVariant.error);
        return;
      }
      showTextOnSnackBar('已添加到歌单');
    } finally {
      _addingAudioToPlaylist = null;
      _addingTargetPlaylist = null;
      if (mounted) setState(() {});
    }
  }

  Widget _musicActionBar(Audio audio) {
    final isAddingThisAudio = identical(_addingAudioToPlaylist, audio);
    final isQueuedNext = identical(_queuedNextAudio, audio);
    final hasNowPlaying =
        PlayService.instance.playbackService.nowPlaying != null;
    final canAddNext = canAddAudioToNext(
      hasNowPlaying: hasNowPlaying,
      isPendingFeedback: isQueuedNext,
    );
    final playlistMemberships = playlists
        .map((playlist) => playlist.containsPath(audio.path))
        .toList(growable: false);
    final canOpenPlaylistMenu = canOpenSingleAudioAddToPlaylistMenu(
      hasAudio: true,
      isBusy: _addingAudioToPlaylist != null,
      alreadyInPlaylists: playlistMemberships,
    );
    final alreadyInAllPlaylists =
        playlists.isNotEmpty && playlistMemberships.every((value) => value);
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: isQueuedNext
              ? '已加入下一首'
              : hasNowPlaying
              ? '下一首播放'
              : '先播放一首歌',
          style: IconButton.styleFrom(
            backgroundColor: isQueuedNext ? scheme.primaryContainer : null,
            disabledBackgroundColor: isQueuedNext
                ? scheme.primaryContainer
                : null,
            disabledForegroundColor: isQueuedNext
                ? scheme.onPrimaryContainer
                : null,
          ),
          onPressed: canAddNext ? () => _addSearchResultToNext(audio) : null,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Icon(
              isQueuedNext ? Symbols.check : Symbols.plus_one,
              key: ValueKey(isQueuedNext),
            ),
          ),
        ),
        MenuAnchor(
          consumeOutsideTap: true,
          menuChildren: List.generate(playlists.length, (playlistIndex) {
            final playlist = playlists[playlistIndex];
            final isAddingTarget =
                isAddingThisAudio && identical(_addingTargetPlaylist, playlist);
            final alreadyInPlaylist = playlist.containsPath(audio.path);
            return MenuItemButton(
              onPressed: _addingAudioToPlaylist == null && !alreadyInPlaylist
                  ? () => _addSearchResultToPlaylist(audio, playlist)
                  : null,
              leadingIcon: isAddingTarget
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      alreadyInPlaylist ? Symbols.check : Symbols.queue_music,
                    ),
              child: Text(playlist.name),
            );
          }),
          builder: (context, controller, _) {
            return IconButton(
              tooltip: isAddingThisAudio
                  ? '添加中'
                  : alreadyInAllPlaylists
                  ? '已存在于所有歌单'
                  : '添加到歌单',
              onPressed: canOpenPlaylistMenu
                  ? () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    }
                  : null,
              icon: isAddingThisAudio
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      alreadyInAllPlaylists
                          ? Symbols.check
                          : Symbols.queue_music,
                    ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SearchDialogFrame(
      title: const Text('搜索'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Focus(
            onFocusChange: HotkeysHelper.onFocusChanges,
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: TextStyle(color: scheme.onSurface),
              decoration: InputDecoration(
                prefixIcon: const Icon(Symbols.search),
                hintText: _isOnlineTab ? '搜索网易音乐' : '搜索歌曲、艺术家、专辑',
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _searchController,
                  builder: (context, value, _) {
                    final hasText = canShowSearchClearAction(value.text);
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasText)
                          IconButton(
                            tooltip: '清除',
                            onPressed: _clearSearch,
                            icon: const Icon(Symbols.close),
                          ),
                        if (_isOnlineTab)
                          IconButton(
                            tooltip: '在线搜索',
                            onPressed:
                                hasText &&
                                    _onlineStatus != _OnlineSearchStatus.loading
                                ? _submitOnlineSearch
                                : null,
                            icon: const Icon(Symbols.travel_explore),
                          ),
                      ],
                    );
                  },
                ),
              ),
              onChanged: _onQueryChanged,
              onSubmitted: (_) {
                if (_isOnlineTab &&
                    _onlineStatus != _OnlineSearchStatus.loading) {
                  _submitOnlineSearch();
                }
              },
            ),
          ),
          if (_isOnlineTab)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: _onlineStatus == _OnlineSearchStatus.loading
                  ? const Padding(
                      padding: EdgeInsets.only(top: 8.0),
                      child: LinearProgressIndicator(minHeight: 2.0),
                    )
                  : const SizedBox(height: 12.0),
            )
          else
            ValueListenableBuilder(
              valueListenable: _isSearching,
              builder: (context, searching, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: searching
                    ? const Padding(
                        padding: EdgeInsets.only(top: 8.0),
                        child: LinearProgressIndicator(minHeight: 2.0),
                      )
                    : const SizedBox(height: 12.0),
              ),
            ),
          ValueListenableBuilder(
            valueListenable: _result,
            builder: (context, result, _) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Wrap(
                  spacing: 8.0,
                  runSpacing: 8.0,
                  children: List.generate(_tabs.length, (i) {
                    final selected = _currentIndex == i;
                    final canSwitch = canSwitchTab(
                      currentIndex: _currentIndex,
                      targetIndex: i,
                    );
                    final count = switch (i) {
                      0 => result.audios.length,
                      1 => result.artists.length,
                      2 => result.album.length,
                      _ => _onlinePage?.items.length ?? 0,
                    };
                    final currentQuery = normalizedSearchQuery(
                      _searchController.text,
                    );
                    final showCount =
                        selected &&
                        (i == _tabs.length - 1
                            ? _onlineStatus == _OnlineSearchStatus.success &&
                                  _onlineQuery == currentQuery
                            : result.query.isNotEmpty &&
                                  result.query == currentQuery);
                    return SearchCategoryButton(
                      label: _tabs[i].label,
                      icon: _tabs[i].icon,
                      selected: selected,
                      count: showCount ? count : null,
                      onPressed: canSwitch ? () => _switchCategory(i) : null,
                    );
                  }),
                ),
              );
            },
          ),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: _result,
              builder: (context, value, _) {
                if (_isOnlineTab) return _buildOnlineSearch();
                final query = value.query.trim();
                if (query.isEmpty) {
                  return const _SearchEmptyState(
                    icon: Symbols.search,
                    title: '输入关键词开始搜索',
                    message: '支持搜索歌曲、艺术家、专辑。',
                  );
                }

                return DirectionalTabView(
                  key: ValueKey('search_$_searchVersion'),
                  index: _currentIndex,
                  children: [
                    _buildMusicList(value),
                    _buildArtistList(value),
                    _buildAlbumList(value),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMusicList(UnionSearchResult value) {
    if (value.audios.isEmpty) {
      return const _SearchEmptyState(
        icon: Symbols.music_note,
        title: '没有找到相关音乐',
        message: '换个关键词，或者切到艺术家、专辑再看。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.audios.length,
          itemBuilder: (context, i) => AudioTile(
            audioIndex: i,
            playlist: value.audios,
            action: _musicActionBar(value.audios[i]),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }

  Widget _buildOnlineSearch() {
    return switch (_onlineStatus) {
      _OnlineSearchStatus.idle => const _SearchEmptyState(
        icon: Symbols.cloud,
        title: '在线搜索',
        message: '输入关键词查找网易音乐曲目。',
      ),
      _OnlineSearchStatus.loading => const _SearchEmptyState(
        icon: Symbols.hourglass_top,
        title: '正在搜索',
        message: '正在获取在线结果。',
      ),
      _OnlineSearchStatus.empty => _SearchEmptyState(
        icon: Symbols.cloud_off,
        title: '没有找到在线曲目',
        message: '换个关键词再试试。',
        action: FilledButton.icon(
          onPressed: _submitOnlineSearch,
          icon: const Icon(Symbols.refresh),
          label: const Text('重新搜索'),
        ),
      ),
      _OnlineSearchStatus.error => _buildOnlineError(),
      _OnlineSearchStatus.success => _buildOnlineResultList(),
    };
  }

  Widget _buildOnlineError() {
    final error = _onlineError!;
    final unauthorized = error.kind == ChkszErrorKind.unauthorized;
    return _SearchEmptyState(
      icon: unauthorized ? Symbols.key_off : Symbols.cloud_off,
      title: '在线搜索失败',
      message: error.safeMessage,
      action: FilledButton.icon(
        onPressed: unauthorized ? _openSettings : _submitOnlineSearch,
        icon: Icon(unauthorized ? Symbols.settings : Symbols.refresh),
        label: Text(unauthorized ? '去设置' : '重试'),
      ),
    );
  }

  void _openSettings() {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.go(app_paths.SETTINGS_PAGE);
  }

  Widget _buildOnlineResultList() {
    final items = _onlinePage!.items;
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final track = items[index];
        final canPlay =
            track.availability != TrackAvailability.unavailable &&
            track.availability != TrackAvailability.paid;
        final details = [
          if (track.artistDisplay.isNotEmpty) track.artistDisplay,
          if (track.album.isNotEmpty) track.album,
        ].join(' · ');
        return ListTile(
          leading: const Icon(Symbols.music_note),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: details.isEmpty
              ? null
              : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: track.duration == Duration.zero
              ? null
              : Text(_formatTrackDuration(track.duration)),
          onTap: widget.onOnlineTrackSelected == null || !canPlay
              ? null
              : () => _selectOnlineTrack(track),
        );
      },
    );
  }

  void _selectOnlineTrack(MusicTrack selected) {
    widget.onOnlineTrackSelected!(
      OnlineTrackSelection.fromResultPage(
        tracks: _onlinePage!.items,
        selectedRef: selected.ref,
      ),
    );
  }

  String _formatTrackDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildArtistList(UnionSearchResult value) {
    if (value.artists.isEmpty) {
      return const _SearchEmptyState(
        icon: Symbols.person,
        title: '没有找到相关艺术家',
        message: '换个关键词，或者回到音乐结果里找。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.artists.length,
          itemBuilder: (context, i) => ArtistTile(artist: value.artists[i]),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }

  Widget _buildAlbumList(UnionSearchResult value) {
    if (value.album.isEmpty) {
      return const _SearchEmptyState(
        icon: Symbols.album,
        title: '没有找到相关专辑',
        message: '换个关键词，或者先从歌曲结果进入专辑。',
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.builder(
          itemCount: value.album.length,
          itemBuilder: (context, i) => AlbumTile(album: value.album[i]),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12.0)),
      ],
    );
  }
}
