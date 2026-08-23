import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/personal_playlist_picker.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/search_action_state.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

typedef OnlineMusicSearch =
    Future<MusicSearchPage> Function({
      required String keyword,
      required int limit,
      required int offset,
      required OnlineMusicCancelToken cancelToken,
    });

typedef OnlineTrackSelected =
    Future<void> Function(MusicSearchPage page, MusicTrack selected);

enum _OnlineSearchStatus { idle, loading, success, empty, error }

class OnlineMusicPage extends StatefulWidget {
  const OnlineMusicPage({
    super.key,
    this.search,
    this.onTrackSelected,
    this.onHistoryRequested,
  });

  final OnlineMusicSearch? search;
  final OnlineTrackSelected? onTrackSelected;
  final VoidCallback? onHistoryRequested;

  @override
  State<OnlineMusicPage> createState() => _OnlineMusicPageState();
}

class _OnlineMusicPageState extends State<OnlineMusicPage> {
  late final TextEditingController _searchController = TextEditingController();
  _OnlineSearchStatus _status = _OnlineSearchStatus.idle;
  MusicSearchPage? _page;
  OnlineMusicException? _error;
  OnlineMusicCancelToken? _cancelToken;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PersonalOnlinePlaylistController>().loadFavorites();
    });
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String raw) {
    if (_status == _OnlineSearchStatus.idle &&
        _page == null &&
        _error == null) {
      return;
    }
    _resetSearch();
  }

  void _resetSearch() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _requestVersion++;
    setState(() {
      _status = _OnlineSearchStatus.idle;
      _page = null;
      _error = null;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _resetSearch();
  }

  Future<void> _submitSearch() async {
    final query = normalizedSearchQuery(_searchController.text);
    if (query.isEmpty) {
      _resetSearch();
      return;
    }

    _cancelToken?.cancel();
    final token = OnlineMusicCancelToken();
    final requestVersion = ++_requestVersion;
    _cancelToken = token;
    setState(() {
      _status = _OnlineSearchStatus.loading;
      _page = null;
      _error = null;
    });

    try {
      final search = widget.search;
      final page = search != null
          ? await search(
              keyword: query,
              limit: 30,
              offset: 0,
              cancelToken: token,
            )
          : await context.read<OnlineMusicService>().search(
              platform: MusicPlatform.netease,
              keyword: query,
              limit: 30,
              offset: 0,
              cancelToken: token,
            );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _page = page;
        _status = page.items.isEmpty
            ? _OnlineSearchStatus.empty
            : _OnlineSearchStatus.success;
      });
    } on OnlineMusicException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      if (error.kind == OnlineMusicErrorKind.cancelled) {
        setState(() => _status = _OnlineSearchStatus.idle);
        return;
      }
      setState(() {
        _error = error;
        _status = _OnlineSearchStatus.error;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = const OnlineMusicException(
          kind: OnlineMusicErrorKind.unknown,
          safeMessage: '音乐服务请求失败',
        );
        _status = _OnlineSearchStatus.error;
      });
    } finally {
      if (requestVersion == _requestVersion) _cancelToken = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '在线音乐',
      actions: [
        IconButton.filledTonal(
          tooltip: '在线播放历史',
          onPressed:
              widget.onHistoryRequested ??
              () => context.go('${app_paths.STATS_PAGE}?source=online'),
          icon: const Icon(Symbols.history),
        ),
      ],
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Focus(
              onFocusChange: HotkeysHelper.onFocusChanges,
              child: TextField(
                key: const ValueKey('online-search-field'),
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Symbols.search),
                  hintText: '搜索网易音乐',
                  suffixIcon: ListenableBuilder(
                    listenable: _searchController,
                    builder: (context, _) {
                      final hasText = canShowSearchClearAction(
                        _searchController.text,
                      );
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasText)
                            IconButton(
                              tooltip: '清除',
                              onPressed: _clearSearch,
                              icon: const Icon(Symbols.close),
                            ),
                          IconButton(
                            tooltip: '在线搜索',
                            onPressed:
                                hasText &&
                                    _status != _OnlineSearchStatus.loading
                                ? _submitSearch
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
                  if (_status != _OnlineSearchStatus.loading) _submitSearch();
                },
              ),
            ),
            SizedBox(
              height: 12.0,
              child: _status == _OnlineSearchStatus.loading
                  ? const Align(
                      alignment: Alignment.topCenter,
                      child: LinearProgressIndicator(minHeight: 2.0),
                    )
                  : null,
            ),
            Expanded(child: _buildSearchBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBody() {
    return switch (_status) {
      _OnlineSearchStatus.idle => const QuietEmptyState(
        icon: Symbols.cloud,
        title: '在线搜索',
        message: '输入关键词查找网易音乐曲目。',
      ),
      _OnlineSearchStatus.loading => const QuietEmptyState(
        icon: Symbols.hourglass_top,
        title: '正在搜索',
        message: '正在获取在线结果。',
      ),
      _OnlineSearchStatus.empty => QuietEmptyState(
        icon: Symbols.cloud_off,
        title: '没有找到在线曲目',
        message: '换个关键词再试试。',
        action: FilledButton.icon(
          onPressed: _submitSearch,
          icon: const Icon(Symbols.refresh),
          label: const Text('重新搜索'),
        ),
      ),
      _OnlineSearchStatus.error => _buildError(),
      _OnlineSearchStatus.success => _buildResultList(),
    };
  }

  Widget _buildError() {
    final error = _error!;
    final unauthorized = error.kind == OnlineMusicErrorKind.notConfigured;
    return QuietEmptyState(
      icon: unauthorized ? Symbols.key_off : Symbols.cloud_off,
      title: '在线搜索失败',
      message: error.safeMessage,
      action: FilledButton.icon(
        onPressed: unauthorized
            ? () => context.go(app_paths.SETTINGS_PAGE)
            : _submitSearch,
        icon: Icon(unauthorized ? Symbols.settings : Symbols.refresh),
        label: Text(unauthorized ? '去设置' : '重试'),
      ),
    );
  }

  Widget _buildResultList() {
    final page = _page!;
    final favorites = context.watch<PersonalOnlinePlaylistController>();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16.0),
      itemCount: page.items.length,
      itemBuilder: (context, index) {
        final track = page.items[index];
        final canPlay =
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
            enabled: canPlay,
            onTap: canPlay ? () => _selectTrack(page, track) : null,
            onAddToPlaylist: () =>
                showPersonalPlaylistPicker(context, track: track),
            showFavorite: true,
            favorite: favorites.isFavorite(track.ref),
            onToggleFavorite: () => favorites.toggleFavorite(track),
          ),
        );
      },
    );
  }

  Future<void> _selectTrack(MusicSearchPage page, MusicTrack selected) async {
    final onTrackSelected = widget.onTrackSelected;
    if (onTrackSelected != null) {
      await onTrackSelected(page, selected);
      return;
    }
    await playOnlineSearchResult(
      context,
      tracks: page.items,
      selectedRef: selected.ref,
    );
  }
}
