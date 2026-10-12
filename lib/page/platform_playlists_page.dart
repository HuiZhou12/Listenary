import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

/// **平台歌单列表页**（2026-10-12 新增 ✓）。
///
/// 两处进来：探索页「平台歌单」每组的「**查看全部**」✓，以及「歌单分类」里点一个 tag ✓。
///
/// 用户要求：**别再给「加载更多」按钮** ✗ —— 之前那个按钮一次只追加一屏横向的卡片，
/// 用户根本感觉不到内容变多 ✓ ⇒ 改成**滑到底自动加载**（列表式，符合直觉 ✓），
/// 到底了才显示「没有更多了」✓（不假装还有 ✓）。
class PlatformPlaylistsPage extends StatefulWidget {
  const PlatformPlaylistsPage({
    super.key,
    required this.platform,
    required this.title,
    this.categoryId,
    this.subtitle,
    this.limit = 30,
  });

  final MusicPlatform platform;
  final String title;
  final String? categoryId;
  final String? subtitle;
  final int limit;

  @override
  State<PlatformPlaylistsPage> createState() => _PlatformPlaylistsPageState();
}

class _PlatformPlaylistsPageState extends State<PlatformPlaylistsPage>
    with RemoteListLoading<PlatformPlaylistsPage> {
  static const _key = 0;

  final RemoteLoadState<int, RemotePlaylistSummary> _state =
      RemoteLoadState<int, RemotePlaylistSummary>();
  final ScrollController _scroll = ScrollController();
  final Set<MusicPlatform> _subscribing = {};

  int _offset = 0;
  bool _hasMore = true;
  bool _loadingMore = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _scroll.addListener(_onScroll);
    unawaited(_loadFirst());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // 提前 400px 触发 ⇒ 用户滑到底之前就开始取，感觉是"连续"的 ✓。
    if (position.pixels >= position.maxScrollExtent - 400) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadFirst() async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _fetch(service, offset: 0, append: false);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _fetch(service, offset: _offset, append: true);
  }

  Future<void> _fetch(
    OnlineMusicService service, {
    required int offset,
    required bool append,
  }) async {
    if (append) setState(() => _loadingMore = true);
    await loadRemoteList(
      _state,
      _key,
      () => service.fetchPlaylistCollection(
        platform: widget.platform,
        limit: widget.limit,
        offset: offset,
        categoryId: widget.categoryId,
        cancelToken: newCancelToken(),
      ),
      append: append,
      fallback: '读取该平台歌单失败',
    );
    if (!mounted) return;
    // 「还有没有更多」只能按**上一页是否取满**推断 ✓（能力层的返回值是裸列表，平台的 total 没传上来 ✓）；
    // 推断错也不会误导：取回一页不满就直接显示"没有更多了"✓。
    final page = _state.items(_key).length - _offset;
    setState(() {
      _loadingMore = false;
      _offset = _state.items(_key).length;
      _hasMore = page >= widget.limit && _state.error(_key) == null;
    });
    // 首屏没铺满就不该等用户滑（宽屏上一页就填满了大半屏 ✓）⇒ 主动补一次 ✓。
    if (_hasMore && append == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (_scroll.position.maxScrollExtent <= 0) unawaited(_loadMore());
      });
    }
  }

  Future<void> _subscribe(RemotePlaylistSummary summary) async {
    if (_subscribing.contains(summary.platform)) return;
    setState(() => _subscribing.add(summary.platform));
    final controller = context.read<OnlinePlaylistController>();
    final saved = await controller.addOrRefresh(
      platform: summary.platform,
      remotePlaylistId: summary.id,
    );
    if (!mounted) return;
    setState(() => _subscribing.remove(summary.platform));
    if (saved == null) {
      showTextOnSnackBar(
        controller.snapshot.errorMessage ?? '订阅该歌单失败',
        variant: ToastVariant.error,
      );
      return;
    }
    showTextOnSnackBar(
      '已订阅「${saved.playlist.name}」，可在媒体库查看',
      variant: ToastVariant.success,
    );
    // **订阅后不再自动跳进详情页**（用户指出这条反直觉 ✓）：留在列表/预览页 ✓。
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = _state.items(_key);
    final firstLoading = _state.isLoading(_key) && items.isEmpty;

    return PageScaffold(
      title: widget.title,
      subtitle:
          widget.subtitle ??
          '${musicPlatformLabel(widget.platform)} · 滑到底自动加载更多',
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () => unawaited(_loadFirst()),
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: firstLoading
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? Center(
              child: _state.error(_key) != null
                  ? InlineFailureHint(
                      message: _state.error(_key)!,
                      onRetry: () => unawaited(_loadFirst()),
                    )
                  : const InlineEmptyHint(
                      icon: Symbols.queue_music,
                      message: '这个条件下没有歌单。',
                    ),
            )
          : CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.only(
                    bottom: Spacing.lg,
                    right: 20,
                  ),
                  sliver: SliverGrid.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 260,
                          mainAxisSpacing: Spacing.md,
                          crossAxisSpacing: Spacing.md,
                          childAspectRatio: 0.72,
                        ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final summary = items[index];
                      // 网格里卡片**撑满格子**：宽度由格子给 ⇒ 用 LayoutBuilder 取实测宽 ✓。
                      return LayoutBuilder(
                        builder: (context, constraints) => RemoteMediaCard(
                          width: constraints.maxWidth,
                          title: summary.name,
                        coverUri: summary.coverUri,
                        details: _detailsOf(summary),
                        sourceLabel: platformLabelForIdentityOnly(
                          summary.identity,
                        ),
                        placeholderIcon: Symbols.queue_music,
                        // **点封面 = 打开预览**（与探索页同一条规则 ✓）：只读、不订阅 ✓，
                        // 也不会点了没反应 ✗；订阅只由下面的按钮触发 ✓。
                        onTap: () => context.push(
                          app_paths.REMOTE_PLAYLIST_PAGE,
                          extra: (
                            platform: summary.platform,
                            playlistId: summary.id,
                            name: summary.name,
                            coverUri: summary.coverUri,
                            creator: summary.creator,
                            trackCount: summary.trackCount,
                            ranked: false,
                          ),
                        ),
                        semanticLabel:
                            '${summary.name}，来自'
                            '${platformLabelForIdentityOnly(summary.identity)}，'
                            '点击预览（不会订阅）',
                        footer: TextButton(
                          onPressed: _subscribing.contains(widget.platform)
                              ? null
                              : () => unawaited(_subscribe(summary)),
                          child: const Text('订阅'),
                        ),
                        ),
                      );
                    },
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      bottom: Spacing.bottomNav,
                      right: 20,
                    ),
                    child: _buildFooter(scheme),
                  ),
                ),
              ],
            ),
    );
  }

  /// 底部状态：**取更多中** / **取更多失败（可重试）** / **没有更多了** ✓ —— 三态如实分开 ✓。
  Widget _buildFooter(ColorScheme scheme) {
    final error = _state.error(_key);
    if (_loadingMore || (_state.isLoading(_key) && error == null)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (error != null) {
      // 取更多失败 ⇒ **就地说失败**并给重试 ✓，不要把已经看到的内容盖掉 ✓。
      return InlineFailureHint(
        message: error,
        onRetry: () => unawaited(_loadMore()),
      );
    }
    if (!_hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
            ),
          ),
        ),
      );
    }
    return const SizedBox(height: Spacing.lg);
  }
}

String _detailsOf(RemotePlaylistSummary summary) => [
  if (summary.trackCount case final count?) '$count 首',
  if (summary.creator case final creator? when creator.isNotEmpty) creator,
].join(' · ');
