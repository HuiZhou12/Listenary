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
  static const int _pageSize = 30;

  late final TextEditingController _searchController = TextEditingController();
  _OnlineSearchStatus _status = _OnlineSearchStatus.idle;

  /// 累积结果页：`items` 是**已加载的全部结果**（每次成功分页后替换为
  /// 追加去重后的新列表，因为 `MusicSearchPage.items` 是不可变列表），
  /// `total` 是服务端返回的总数。
  MusicSearchPage? _page;
  OnlineMusicException? _error;
  OnlineMusicCancelToken? _cancelToken;
  int _requestVersion = 0;
  bool _loadingMore = false;
  OnlineMusicException? _loadMoreError;

  /// 上一次分页（含首请求）**原始**返回条数，用于 `hasMore` 的第二重判定。
  int _lastPageCount = 0;

  /// 已加载的全部结果（保持服务端顺序）。
  List<MusicTrack> get _loadedTracks => _page?.items ?? const <MusicTrack>[];

  /// 已加载结果对应的服务端总数。
  int get _loadedTotal => _page?.total ?? 0;

  /// `hasMore` 双重判定：已加载数量 < total **且** 上一页原始返回条数 == limit。
  ///
  /// 只信 `total` 不可靠（部分第三方接口不裁剪、或 total 与实际条数不一致），
  /// 沿用 `lyric_source_view.dart:436,443` 的既有先例。
  bool get _hasMore {
    if (_status != _OnlineSearchStatus.success) return false;
    final loaded = _loadedTracks;
    if (loaded.isEmpty) return false;
    if (_lastPageCount < _pageSize) return false;
    return loaded.length < _loadedTotal;
  }

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
    // 取消在途请求（含在途分页请求）并作废其版本号，避免旧响应追加到新列表。
    _cancelToken?.cancel();
    _cancelToken = null;
    _requestVersion++;
    setState(() {
      _status = _OnlineSearchStatus.idle;
      _page = null;
      _error = null;
      _loadingMore = false;
      _loadMoreError = null;
      _lastPageCount = 0;
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
      _loadingMore = false;
      _loadMoreError = null;
      _lastPageCount = 0;
    });

    try {
      final search = widget.search;
      final page = search != null
          ? await search(
              keyword: query,
              limit: _pageSize,
              offset: 0,
              cancelToken: token,
            )
          : await context.read<OnlineMusicService>().search(
              platform: MusicPlatform.netease,
              keyword: query,
              limit: _pageSize,
              offset: 0,
              cancelToken: token,
            );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _page = page;
        _lastPageCount = page.items.length;
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

  /// 加载下一页：`offset = 已加载数量`、同一 keyword、每页 `_pageSize`。
  ///
  /// 加载中或已到底时不可重复触发；失败保留已加载结果，仅记录安全的错误提示，
  /// 入口保持可重试。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final query = normalizedSearchQuery(_searchController.text);
    if (query.isEmpty) return;

    final offset = _loadedTracks.length;
    _cancelToken?.cancel();
    final token = OnlineMusicCancelToken();
    final requestVersion = ++_requestVersion;
    _cancelToken = token;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });

    try {
      final search = widget.search;
      final page = search != null
          ? await search(
              keyword: query,
              limit: _pageSize,
              offset: offset,
              cancelToken: token,
            )
          : await context.read<OnlineMusicService>().search(
              platform: MusicPlatform.netease,
              keyword: query,
              limit: _pageSize,
              offset: offset,
              cancelToken: token,
            );
      if (!mounted || requestVersion != _requestVersion) return;
      _mergeLoadedPage(page);
    } on OnlineMusicException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      if (error.kind == OnlineMusicErrorKind.cancelled) {
        setState(() => _loadingMore = false);
        return;
      }
      setState(() {
        _loadingMore = false;
        _loadMoreError = error;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = const OnlineMusicException(
          kind: OnlineMusicErrorKind.unknown,
          safeMessage: '加载更多失败，请稍后重试',
        );
      });
    } finally {
      if (requestVersion == _requestVersion) _cancelToken = null;
    }
  }

  /// 把新一页追加到已加载结果：按 `track.ref` 去重并保留原有顺序
  /// （搜索链路没有去重，重复 ref 会静默跳过进场动画并让测试 finder 歧义）。
  void _mergeLoadedPage(MusicSearchPage next) {
    final current = _page;
    if (current == null) return;
    final seen = <PlatformTrackRef>{
      for (final track in current.items) track.ref,
    };
    final merged = <MusicTrack>[...current.items];
    for (final track in next.items) {
      if (seen.add(track.ref)) merged.add(track);
    }
    setState(() {
      _page = MusicSearchPage(
        platform: current.platform,
        items: merged,
        offset: current.offset,
        limit: current.limit,
        total: next.total ?? current.total,
      );
      _lastPageCount = next.items.length;
      _loadingMore = false;
      _loadMoreError = null;
    });
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
      // 底部留白：迷你播放器浮在底部（64 高 + 32 边距），否则「加载更多」会被它挡住。
      padding: const EdgeInsets.only(bottom: 96.0),
      itemCount: page.items.length + 1,
      itemBuilder: (context, index) {
        if (index == page.items.length) return _buildLoadMoreFooter();
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
            isNowPlaying: isOnlineTrackNowPlaying(context, track.ref),
          ),
        );
      },
    );
  }

  /// 列表底部的分页入口：可加载 → 「加载更多」按钮；加载中 → 转圈且禁用；
  /// 失败 → 安全提示 + 可重试；到底 → 「没有更多了」。
  Widget _buildLoadMoreFooter() {
    final scheme = Theme.of(context).colorScheme;
    final error = _loadMoreError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error.safeMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.error),
            ),
            const SizedBox(height: 8.0),
            FilledButton.tonalIcon(
              key: const ValueKey('online-search-load-more-retry'),
              onPressed: _loadMore,
              icon: const Icon(Symbols.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16.0),
        child: Center(
          child: SizedBox(
            width: 20.0,
            height: 20.0,
            child: CircularProgressIndicator(strokeWidth: 2.0),
          ),
        ),
      );
    }
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12.0),
        child: Center(
          child: FilledButton.tonalIcon(
            key: const ValueKey('online-search-load-more'),
            onPressed: _loadMore,
            icon: const Icon(Symbols.expand_more),
            label: const Text('加载更多'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Center(
        child: Text(
          '没有更多了',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Future<void> _selectTrack(MusicSearchPage page, MusicTrack selected) async {
    // `page` 是累积后的结果页，`page.items` 即“已加载的全部结果”，
    // 与用户确认的队列语义一致；选中项必然在其中（列表由它渲染）。
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
