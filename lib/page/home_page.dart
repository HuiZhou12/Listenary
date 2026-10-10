import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/platform_capability_view.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

/// **聚合主页**：先把**你自己的东西**放前面，再是平台内容，最后才是配置诊断。
///
/// 设计口径：
/// - 区块顺序 = 价值顺序：「继续听」→「我的收藏」→「我的在线歌单」→「来自平台的歌单」；
/// - **平台能力是诊断信息，不是内容** ⇒ 收进底部一个默认收起的区块，不再占据首屏；
/// - 内容按**已启用平台 + 真实可用能力**动态生成，能力不足的平台如实说明；
/// - 平台原生内容由对应 Provider 提供，应用内部数据走应用自己的数据层；
/// - **单平台失败不影响整页**：每个平台的歌单列表各自加载、各自报错、各自可重试；
/// - 不硬编码任何歌曲/歌单，也不为没有接口依据的数据源编造 API。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.previewLimit = 6, this.collectionLimit = 12});

  /// 每个"最近播放 / 收藏 / 自建歌单"区块最多展示多少条。
  final int previewLimit;

  /// 每个平台歌单列表一次拉多少条。
  final int collectionLimit;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with RemoteListLoading<HomePage> {
  bool _loaded = false;

  /// 记住实例以便在 dispose 时摘掉监听（`context.removeListener` 不存在）。
  PersonalOnlinePlaylistController? _personal;

  PersonalOnlinePlaylistSnapshot? _favorites;
  bool _favoritesLoading = false;
  bool _favoritesFailed = false;

  /// 有「歌单列表」能力的平台（服务层推导，未配置的平台不会出现在这里）。
  List<MusicPlatform> _collectionPlatforms = const [];
  final Set<MusicPlatform> _subscribing = {};

  /// 平台歌单按平台各自加载（单平台失败不影响其它平台）。
  final RemoteLoadState<MusicPlatform, RemotePlaylistSummary> remote =
      RemoteLoadState<MusicPlatform, RemotePlaylistSummary>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _personal = context.read<PersonalOnlinePlaylistController>();
      _personal!.addListener(_onPersonalChanged);
      unawaited(_load());
    });
  }

  @override
  void dispose() {
    _personal?.removeListener(_onPersonalChanged);
    super.dispose();
  }

  void _onPersonalChanged() {
    if (!mounted) return;
    // 收藏是异步读的，且读本身不会触发通知，因此这里直接刷新是安全的。
    unawaited(_loadFavorites());
  }

  Future<void> _load() async {
    if (_loaded) {
      await _refreshAll();
      return;
    }
    _loaded = true;
    final history = context.read<OnlineHistoryController>();
    final personal = context.read<PersonalOnlinePlaylistController>();
    unawaited(history.refresh());
    unawaited(personal.load());
    unawaited(_loadFavorites());
    unawaited(_loadCollections());
  }

  Future<void> _refreshAll() async {
    final history = context.read<OnlineHistoryController>();
    final personal = context.read<PersonalOnlinePlaylistController>();
    unawaited(history.refresh());
    unawaited(personal.load());
    await Future.wait([_loadFavorites(), _loadCollections()]);
  }

  Future<void> _loadFavorites() async {
    if (_favoritesLoading || !mounted) return;
    _favoritesLoading = true;
    try {
      final snapshot = await context
          .read<PersonalOnlinePlaylistController>()
          .readFavorites();
      if (!mounted) return;
      setState(() {
        _favorites = snapshot;
        _favoritesFailed = false;
      });
    } catch (_) {
      // 收藏读不出来时该区块显示**失败**态（不是"还没有收藏"），不影响主页其它区块。
      if (mounted) {
        setState(() {
          _favorites = null;
          _favoritesFailed = true;
        });
      }
    } finally {
      _favoritesLoading = false;
    }
  }

  Future<void> _loadCollections() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.playlistCollectionPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    setState(() => _collectionPlatforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms) _loadCollection(service, platform),
    ]);
  }

  Future<void> _loadCollection(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    remote,
    platform,
    () => service.fetchPlaylistCollection(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台歌单失败',
  );

  /// 把平台歌单**订阅到本机**（复用既有订阅链路），成功后打开详情。
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
      '已订阅「${saved.playlist.name}」',
      variant: ToastVariant.success,
    );
    await context.push(
      app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
      extra: saved.localId,
    );
  }

  /// 货架里卡片的宽度：**统一取自 `RemoteMediaCard.widthFor`**（与 ResponsiveBuilder 同阈值），
  /// 不在每个页面各写一个断点。
  double get _cardWidth =>
      RemoteMediaCard.widthFor(MediaQuery.sizeOf(context));

  @override
  Widget build(BuildContext context) {
    final service = context.read<OnlineMusicService?>();
    final history = context.watch<OnlineHistoryController>().snapshot;
    final personal = context.watch<PersonalOnlinePlaylistController>().snapshot;
    return PageScaffold(
      title: '主页',
      subtitle: '接着听、你的收藏与各平台内容，来源始终可见',
      actions: [
        IconButton.filledTonal(
          tooltip: '搜索在线音乐',
          onPressed: () => context.go(app_paths.ONLINE_MUSIC_PAGE),
          icon: const Icon(Symbols.search),
        ),
        IconButton.filledTonal(
          tooltip: '刷新主页',
          onPressed: _refreshAll,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav, right: 20),
        children: [
          _buildHistory(history),
          _buildFavorites(),
          _buildPersonalPlaylists(personal),
          _buildCollections(service),
          PlatformCapabilityView(
            capabilities: service?.capabilities,
            onConfigure: () => context.go(app_paths.SETTINGS_PAGE),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 继续听

  Widget _buildHistory(OnlineHistoryViewSnapshot history) {
    final entries = history.recent.take(widget.previewLimit).toList();
    return ContentSection(
      title: '继续听',
      subtitle: '来自在线播放历史（按曲目自己的来源标注）',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      child: entries.isEmpty
          ? InlineEmptyHint(
              icon: Symbols.history,
              message: history.status == OnlineHistoryLoadStatus.failed
                  ? '播放历史读取失败，可稍后重试。'
                  : '还没有在线播放记录：从探索或搜索进入任一平台曲目即可开始。',
            )
          : Column(
              children: [
                for (final entry in entries)
                  _buildTrackRow(
                    entry.track,
                    onTap: () => playOnlineHistoryEntry(
                      context,
                      entries: history.recent,
                      selectedRef: entry.track.ref,
                    ),
                  ),
              ],
            ),
    );
  }

  // ----------------------------------------------------------------- 收藏

  Widget _buildFavorites() {
    final tracks = _favorites?.tracks ?? const <MusicTrack>[];
    final preview = tracks.take(widget.previewLimit).toList();
    return ContentSection(
      title: '我的收藏',
      subtitle: '收藏是跨平台的，每行都标明来源',
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.FAVORITES_PAGE),
      child: switch (preview) {
        // 读取失败 ≠ 没有收藏：两者文案必须不同，否则一次网络抖动会被读成"收藏丢了"。
        _ when _favoritesFailed => InlineFailureHint(
          message: '收藏读取失败，可稍后重试。',
          onRetry: _loadFavorites,
        ),
        [] => const InlineEmptyHint(
          icon: Symbols.favorite,
          message: '还没有收藏：在在线曲目上点心形图标即可收藏。',
        ),
        _ => Column(
          children: [
            for (final track in preview)
              _buildTrackRow(
                track,
                onTap: () => playOnlineSearchResult(
                  context,
                  tracks: tracks,
                  selectedRef: track.ref,
                ),
              ),
          ],
        ),
      },
    );
  }

  /// 一行在线曲目：组装、来源标记、收藏与"加入歌单"都收敛在 [OnlineTrackEntry] 里
  /// （那段组装此前在四个页面各抄了一遍）。
  Widget _buildTrackRow(MusicTrack track, {required VoidCallback onTap}) =>
      OnlineTrackEntry(track: track, onTap: onTap);

  // ------------------------------------------------------------- 自建歌单

  Widget _buildPersonalPlaylists(PersonalOnlinePlaylistViewSnapshot snapshot) {
    final playlists = snapshot.playlists.take(widget.previewLimit).toList();
    return ContentSection(
      title: '我的在线歌单',
      subtitle: '应用自建的歌单，可以混放不同平台的曲目',
      actionLabel: '管理歌单',
      onAction: () => context.go(app_paths.PLAYLISTS_PAGE),
      child: playlists.isEmpty
          ? const InlineEmptyHint(
              icon: Symbols.playlist_add,
              message: '还没有自建歌单：在歌单页新建一个，就能把不同平台的曲目放在一起。',
            )
          : Column(
              children: [
                for (final playlist in playlists)
                  _PersonalPlaylistTile(
                    playlist: playlist,
                    onTap: () => context.push(
                      app_paths.PERSONAL_PLAYLIST_DETAIL_PAGE,
                      extra: playlist.localId,
                    ),
                  ),
              ],
            ),
    );
  }

  // --------------------------------------------------------- 平台歌单列表

  Widget _buildCollections(OnlineMusicService? service) {
    if (service == null || _collectionPlatforms.isEmpty) {
      return ContentSection(
        title: '来自平台的歌单',
        subtitle: '来自各平台自己的「歌单列表」能力',
        actionLabel: '去配置',
        onAction: () => context.go(app_paths.SETTINGS_PAGE),
        child: const InlineEmptyHint(
          icon: Symbols.info,
          message:
              '当前没有可用的「歌单列表」服务：先在「设置 → 在线音乐 → 服务提供商」里'
              '为某个条目配置并试跑「歌单列表」能力（保存后重启生效），'
              '再到平台卡里选它做该能力的来源。',
        ),
      );
    }
    return ContentSection(
      title: '来自平台的歌单',
      subtitle: '每个平台各自加载；一个平台失败不影响其它平台',
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.EXPLORE_PAGE),
      child: Column(
        children: [
          for (final platform in _collectionPlatforms)
            _buildPlatformCollection(platform),
        ],
      ),
    );
  }

  Widget _buildPlatformCollection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final items = remote.items(platform);
    final width = _cardWidth;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            musicPlatformLabel(platform),
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          HorizontalShelf(
            loading: remote.isLoading(platform),
            errorMessage: remote.error(platform),
            onRetry: () => _retryCollection(platform),
            emptyMessage: '该平台没有返回歌单。',
            emptyIcon: Symbols.queue_music,
            itemCount: items.length,
            itemWidth: width,
            // 高度取自卡片的同一份声明：卡片变高时货架跟着变，不会溢出。
            itemHeight: RemoteMediaCard.extentFor(
              width: width,
              hasFooter: true,
            ),
            itemBuilder: (context, index) {
              final summary = items[index];
              final busy = _subscribing.contains(platform);
              return RemoteMediaCard(
                width: width,
                title: summary.name,
                coverUri: summary.coverUri,
                details: _detailsOf(summary),
                sourceLabel: musicPlatformLabel(summary.platform),
                placeholderIcon: Symbols.queue_music,
                onTap: busy ? null : () => _subscribe(summary),
                semanticLabel:
                    '${summary.name}，来自${musicPlatformLabel(summary.platform)}，点击订阅并打开',
                footer: TextButton(
                  onPressed: busy ? null : () => _subscribe(summary),
                  child: const Text('订阅'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String _detailsOf(RemotePlaylistSummary summary) {
    final creator = summary.creator?.trim();
    return [
      if (creator != null && creator.isNotEmpty) creator,
      if (summary.trackCount != null) '${summary.trackCount} 首',
    ].join(' · ');
  }

  Future<void> _retryCollection(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadCollection(service, platform);
  }
}

class _PersonalPlaylistTile extends StatelessWidget {
  const _PersonalPlaylistTile({required this.playlist, required this.onTap});

  final PersonalOnlinePlaylistSnapshot playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      borderRadius: AppRadius.smCircular,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: 10,
          ),
          child: Row(
            children: [
              Icon(Symbols.queue_music, color: scheme.onSurfaceVariant),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurface),
                ),
              ),
              Text(
                '${playlist.tracks.length} 首',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
