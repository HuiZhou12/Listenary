import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_row.dart';
import 'package:pure_music/component/personal_playlist_picker.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_history_controller.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_library/personal_online_playlist_controller.dart';

/// 平台状态里展示的能力清单。
///
/// 刻意**不引用配置层的能力枚举符号**（连注释里都不写出它的名字：依赖边界测试
/// 是纯文本扫描，见 `online_music_dependency_boundary_test`）。应用层不得依赖 Provider 层，
/// 而这里只需要"展示名 + 可用性判定"这两件事。
typedef _CapabilityProbe =
    bool Function(OnlineMusicCapabilities capabilities, MusicPlatform platform);

const _platformCapabilityRows = <({String label, _CapabilityProbe available})>[
  (label: '搜索', available: _searchable),
  (label: '歌单详情', available: _playlistDetail),
  (label: '歌单列表', available: _playlistCollection),
  (label: '歌词', available: _lyrics),
  (label: '播放解析', available: _resolvable),
];

bool _searchable(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.searchablePlatforms.contains(p);

bool _playlistDetail(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playlistPlatforms.contains(p);

bool _playlistCollection(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.playlistCollectionPlatforms.contains(p);

bool _lyrics(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.lyricPlatforms.contains(p);

bool _resolvable(OnlineMusicCapabilities c, MusicPlatform p) =>
    c.resolvablePlatforms.contains(p);

/// 聚合主页：把**已启用平台**的真实内容与应用内部数据汇到一页。
///
/// 设计口径（Spec 第三段）：
/// - 数据按**已启用平台 + 真实可用能力**动态生成，能力不足的平台如实显示"未配置/不可用"；
/// - 平台原生内容（平台歌单列表）由对应 Provider 提供，应用内部数据（最近播放、收藏、
///   自建歌单）走应用自己的数据层，主页只负责组合与呈现；
/// - **单平台失败不影响整页**：每个平台的歌单列表各自加载、各自报错；
/// - 不硬编码任何歌曲/歌单，也不为没有接口依据的数据源编造 API。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.previewLimit = 6, this.collectionLimit = 12});

  /// 每个"最近播放 / 收藏"区块最多展示多少条。
  final int previewLimit;

  /// 每个平台歌单列表一次拉多少条。
  final int collectionLimit;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loaded = false;

  /// 记住实例以便在 dispose 时摘掉监听（`context.removeListener` 不存在）。
  PersonalOnlinePlaylistController? _personal;

  PersonalOnlinePlaylistSnapshot? _favorites;
  bool _favoritesLoading = false;

  /// 有「歌单列表」能力的平台（服务层推导，未配置的平台不会出现在这里）。
  List<MusicPlatform> _collectionPlatforms = const [];
  final Map<MusicPlatform, List<RemotePlaylistSummary>> _collections = {};
  final Map<MusicPlatform, String> _collectionErrors = {};
  final Set<MusicPlatform> _collectionLoading = {};
  final Set<MusicPlatform> _subscribing = {};

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
    if (_loaded) return;
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
      setState(() => _favorites = snapshot);
    } catch (_) {
      // 收藏读不出来时该区块显示失败态，不影响主页其它区块（单点失败隔离）。
      if (mounted) setState(() => _favorites = null);
    } finally {
      _favoritesLoading = false;
    }
  }

  Future<void> _loadCollections() async {
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in MusicPlatform.values)
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
  ) async {
    setState(() => _collectionLoading.add(platform));
    try {
      final items = await service.fetchPlaylistCollection(
        platform: platform,
        limit: widget.collectionLimit,
        offset: 0,
        cancelToken: OnlineMusicCancelToken(),
      );
      if (!mounted) return;
      setState(() {
        _collections[platform] = items;
        _collectionErrors.remove(platform);
        _collectionLoading.remove(platform);
      });
    } on OnlineMusicException catch (error) {
      if (!mounted) return;
      setState(() {
        _collectionErrors[platform] = error.safeMessage;
        _collectionLoading.remove(platform);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _collectionErrors[platform] = '读取该平台歌单失败';
        _collectionLoading.remove(platform);
      });
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final service = context.read<OnlineMusicService?>();
    final history = context.watch<OnlineHistoryController>().snapshot;
    final personal = context.watch<PersonalOnlinePlaylistController>().snapshot;
    return PageScaffold(
      title: '主页',
      subtitle: '各平台内容汇在一页，来源始终可见',
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
        padding: const EdgeInsets.only(bottom: 96.0, right: 20),
        children: [
          _buildPlatformStatus(service),
          _buildHistory(history),
          _buildFavorites(),
          _buildPersonalPlaylists(personal),
          _buildCollections(service),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 平台状态

  Widget _buildPlatformStatus(OnlineMusicService? service) {
    final scheme = Theme.of(context).colorScheme;
    final capabilities = service?.capabilities;
    return _HomeSection(
      title: '平台状态',
      subtitle: '每个平台能做什么，一目了然；未配置的能力不会假装可用',
      child: Column(
        children: [
          for (final platform in MusicPlatform.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _PlatformStatusTile(
                platform: platform,
                capabilities: capabilities,
                onTap: () => context.go(app_paths.SETTINGS_PAGE),
              ),
            ),
          if (capabilities == null)
            Row(
              children: [
                Icon(Symbols.info, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '在线音乐服务尚未就绪，平台状态暂时不可用。',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 最近播放

  Widget _buildHistory(OnlineHistoryViewSnapshot history) {
    final entries = history.recent.take(widget.previewLimit).toList();
    return _HomeSection(
      title: '最近播放',
      subtitle: '来自在线播放历史（按曲目自己的来源标注）',
      actionLabel: '查看全部',
      onAction: () => context.go('${app_paths.STATS_PAGE}?source=online'),
      child: entries.isEmpty
          ? _EmptyHint(
              icon: Symbols.history,
              message: history.status == OnlineHistoryLoadStatus.failed
                  ? '播放历史读取失败，可稍后重试。'
                  : '还没有在线播放记录：从主页或搜索进入任一平台曲目即可开始。',
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
    return _HomeSection(
      title: '我的收藏',
      subtitle: '收藏是跨平台的，每行都标明来源',
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.FAVORITES_PAGE),
      child: preview.isEmpty
          ? const _EmptyHint(
              icon: Symbols.favorite,
              message: '还没有收藏：在在线曲目上点心形图标即可收藏。',
            )
          : Column(
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
    );
  }

  Widget _buildTrackRow(MusicTrack track, {required VoidCallback onTap}) {
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
        sourceLabel: musicPlatformLabel(track.ref.platform),
        onTap: playable ? onTap : null,
        onAddToPlaylist: () =>
            showPersonalPlaylistPicker(context, track: track),
        showFavorite: true,
        favorite: context.watch<PersonalOnlinePlaylistController>().isFavorite(
          track.ref,
        ),
        onToggleFavorite: () => context
            .read<PersonalOnlinePlaylistController>()
            .toggleFavorite(track),
        isNowPlaying: isOnlineTrackNowPlaying(context, track.ref),
      ),
    );
  }

  // ------------------------------------------------------------- 自建歌单

  Widget _buildPersonalPlaylists(PersonalOnlinePlaylistViewSnapshot snapshot) {
    final playlists = snapshot.playlists.take(widget.previewLimit).toList();
    return _HomeSection(
      title: '我的在线歌单',
      subtitle: '应用自建的歌单，可以混放不同平台的曲目',
      actionLabel: '管理歌单',
      onAction: () => context.go(app_paths.PLAYLISTS_PAGE),
      child: playlists.isEmpty
          ? const _EmptyHint(
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
    final scheme = Theme.of(context).colorScheme;
    if (service == null || _collectionPlatforms.isEmpty) {
      return _HomeSection(
        title: '平台歌单',
        subtitle: '来自各平台自己的「歌单列表」能力',
        actionLabel: '去配置',
        onAction: () => context.go(app_paths.SETTINGS_PAGE),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Symbols.info, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '当前没有可用的「歌单列表」服务：在设置的平台卡里，'
                '为某个条目配置「歌单列表」能力后，这里会显示它的平台歌单。',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }
    return _HomeSection(
      title: '平台歌单',
      subtitle: '每个平台各自加载；一个平台失败不影响其它平台',
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
    final error = _collectionErrors[platform];
    final items = _collections[platform];
    final loading = _collectionLoading.contains(platform);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                musicPlatformLabel(platform),
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              const SizedBox(width: 8),
              if (loading)
                const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (error != null)
            Text(error, style: TextStyle(color: scheme.error))
          else if (items == null)
            Text('正在加载…', style: TextStyle(color: scheme.onSurfaceVariant))
          else if (items.isEmpty)
            Text('该平台没有返回歌单', style: TextStyle(color: scheme.onSurfaceVariant))
          else
            SizedBox(
              // 高度要容得下封面 + 标题 + 副标题 + 「订阅」按钮，否则会溢出。
              height: 216,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final summary = items[index];
                  return _PlatformPlaylistCard(
                    summary: summary,
                    busy: _subscribing.contains(platform),
                    onSubscribe: () => _subscribe(summary),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 小组件

class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.child,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: AppType.body,
                        fontWeight: AppType.weightSemibold,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: AppType.caption,
                        ),
                      ),
                  ],
                ),
              ),
              if (actionLabel != null && onAction != null)
                TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// 平台状态：平台自己的名字 + 五项能力的可用情况 + 不可用原因。
class _PlatformStatusTile extends StatelessWidget {
  const _PlatformStatusTile({
    required this.platform,
    required this.capabilities,
    required this.onTap,
  });

  final MusicPlatform platform;
  final OnlineMusicCapabilities? capabilities;
  final VoidCallback onTap;

  bool _has(({String label, _CapabilityProbe available}) row) {
    final value = capabilities;
    if (value == null) return false;
    return row.available(value, platform);
  }

  bool get _anyAvailable =>
      _platformCapabilityRows.any(_has) ||
      (capabilities?.unavailableSearchReasonFor(platform) != null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reason = capabilities?.unavailableSearchReasonFor(platform);
    return Material(
      type: MaterialType.transparency,
      borderRadius: AppRadius.smCircular,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    musicPlatformLabel(platform),
                    style: TextStyle(
                      fontWeight: AppType.weightMedium,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!_anyAvailable)
                    Text(
                      '未配置',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: AppType.caption,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final row in _platformCapabilityRows)
                    _CapabilityChip(label: row.label, available: _has(row)),
                ],
              ),
              if (reason != null) ...[
                const SizedBox(height: 6),
                Text(
                  reason,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.caption,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.available});

  final String label;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: available
            ? scheme.primaryContainer.withValues(alpha: 0.7)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.xsCircular,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppType.caption,
          color: available
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
    );
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Icon(Symbols.queue_music, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
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

class _PlatformPlaylistCard extends StatelessWidget {
  const _PlatformPlaylistCard({
    required this.summary,
    required this.busy,
    required this.onSubscribe,
  });

  final RemotePlaylistSummary summary;
  final bool busy;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      if (summary.creator?.isNotEmpty == true) summary.creator!,
      if (summary.trackCount != null) '${summary.trackCount} 首',
    ].join(' · ');
    return SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: AppRadius.smCircular,
            child: SizedBox.square(
              dimension: 132,
              child: RemoteMediaCover(
                coverUri: summary.coverUri,
                placeholder: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Symbols.queue_music,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                cacheWidth: 256,
                cacheHeight: 256,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            summary.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: AppType.body),
          ),
          Text(
            details.isEmpty
                ? musicPlatformLabel(summary.platform)
                : '${musicPlatformLabel(summary.platform)} · $details',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
            ),
          ),
          TextButton(
            onPressed: busy ? null : onSubscribe,
            child: const Text('订阅'),
          ),
        ],
      ),
    );
  }
}
