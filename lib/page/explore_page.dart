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
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

/// 歌单列表的请求键：**（平台，分类）**。
///
/// 用记录（record）当 key 是因为它天然按值相等：同一平台在"全部"（`categoryId == null`）
/// 与"某个分类"下是两份互不覆盖的结果。
typedef _CollectionKey = ({MusicPlatform platform, String? categoryId});

/// **探索**：目录式的多平台内容浏览入口。
///
/// 设计口径：
/// - **按能力分区，不按平台分区**：一个区块只在"至少一个已启用平台支持该能力"时出现；
///   不支持该能力的平台在该区块内**缺席**，而不是渲染成空；
/// - 平台原生内容由对应 Provider 提供，页面只负责组合与呈现；
/// - **单平台失败不影响整页**：每个平台的区块各自加载、各自报错、各自可重试；
/// - 不硬编码任何歌单/专辑/曲目，也不为没有接口依据的能力编造数据。
///
/// 本轮（P1）接通的是**今天就已经存在的能力**（歌单列表）。其余内容类型（推荐歌单 /
/// 榜单 / 新碟新歌 / 分类曲风）在对应 Provider 能力接入后，复用本页的
/// [ContentSection] + [HorizontalShelf] + [RemoteMediaCard] 组合逐块增加，
/// **不需要改动本页结构**。
class ExplorePage extends StatefulWidget {
  const ExplorePage({
    super.key,
    this.collectionLimit = 24,
    this.chartPreviewLimit = 12,
    this.categoryLimit = 200,
    this.newSongLimit = 30,
  });

  /// 每个平台一次拉多少条歌单。
  final int collectionLimit;

  /// 榜单货架上先露多少条（真实服务可能忽略 limit 并返回全部，因此这里再截一次）。
  final int chartPreviewLimit;

  /// 每个平台一次拉多少个分类（网易云实测 70 个；`limit` 只是建议值）。
  final int categoryLimit;

  /// 每个平台一次拉多少首新歌（网易云实测只认 `limit`、忽略 `offset`；`limit` 也只是建议值）。
  final int newSongLimit;

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage>
    with RemoteListLoading<ExplorePage> {
  /// 有「歌单列表」能力的平台（由服务层推导；未配置的平台不会出现在这里）。
  List<MusicPlatform> _platforms = const [];

  /// 歌单列表按 **(平台, 分类)** 分开存：同一平台在"全部"与"某个分类"下
  /// 是两份独立结果，混在一个 key 里会让切分类时显示上一个分类的内容。
  /// （记录当 key 天然按值相等。）
  final RemoteLoadState<_CollectionKey, RemotePlaylistSummary> _collectionState =
      RemoteLoadState<_CollectionKey, RemotePlaylistSummary>(
        // 分页去重：**分页路径由用户在设置里配置**，未必真的支持翻页；
        // 接口若忽略 offset，靠这个标识把重复项挡掉（否则同一批内容会出现两遍）。
        identity: (summary) => '${summary.platform.name}:${summary.id}',
      );
  final Set<MusicPlatform> _subscribing = {};

  /// 分类浏览：只取**既能列分类、又能按分类取歌单**的平台（否则 chip 点不动）。
  List<MusicPlatform> _categoryPlatforms = const [];
  final RemoteLoadState<MusicPlatform, RemotePlaylistCategory> _categoryState =
      RemoteLoadState<MusicPlatform, RemotePlaylistCategory>();

  /// 每个平台当前选中的分类（null = 全部）。
  final Map<MusicPlatform, String?> _selectedCategory = {};

  /// 榜单：只取**既能列榜、又能取歌单详情**的平台（否则点开是死链）。
  List<MusicPlatform> _chartPlatforms = const [];
  final RemoteLoadState<MusicPlatform, RemotePlaylistSummary> _chartState =
      RemoteLoadState<MusicPlatform, RemotePlaylistSummary>();

  /// 新歌：只取**能播放**的平台（列表里放点不响的曲目比不显示更糟）。
  List<MusicPlatform> _newSongPlatforms = const [];
  final RemoteLoadState<MusicPlatform, MusicTrack> _newSongState =
      RemoteLoadState<MusicPlatform, MusicTrack>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    // 刷新时先清掉旧错误：重试前不该继续挂着上一次的失败提示。
    //
    // 这段原先被一个 `if (_loaded)` 包着，而 `_load` 只在 initState 里调用过一次、
    // 刷新按钮接的是 `_reload` —— 于是这个分支**从来没执行过**，
    // "刷新会先清掉旧错误"只是注释里的说法。现在按钮改接 `_load`，说到做到。
    setState(() {
      _collectionState.clearErrors();
      _categoryState.clearErrors();
      _chartState.clearErrors();
    });
    await _reload();
  }

  Future<void> _reload() async {
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
    final chartPlatforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.openableChartPlatforms.contains(platform))
                platform,
          ];
    final categoryPlatforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.browsableCategoryPlatforms.contains(
                platform,
              ))
                platform,
          ];
    final newSongPlatforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.playableNewSongPlatforms.contains(
                platform,
              ))
                platform,
          ];
    if (!mounted) return;
    setState(() {
      _platforms = platforms;
      _chartPlatforms = chartPlatforms;
      _categoryPlatforms = categoryPlatforms;
      _newSongPlatforms = newSongPlatforms;
    });
    if (service == null) return;
    await Future.wait([
      for (final platform in chartPlatforms) _loadCharts(service, platform),
      for (final platform in newSongPlatforms)
        _loadNewSongs(service, platform),
      for (final platform in categoryPlatforms)
        _loadCategories(service, platform),
      for (final platform in platforms)
        _loadCollection(service, platform, _selectedCategory[platform]),
    ]);
  }

  Future<void> _loadNewSongs(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _newSongState,
    platform,
    () => service.fetchNewSongs(
      platform: platform,
      limit: widget.newSongLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台新歌失败',
  );

  Future<void> _loadCategories(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _categoryState,
    platform,
    () => service.fetchPlaylistCategories(
      platform: platform,
      limit: widget.categoryLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台歌单分类失败',
  );

  /// 选中/清除某个平台的分类。
  ///
  /// 选中后**只为该平台的一个分类**发一次请求（已取过的分类直接复用缓存），
  /// 不会重刷其它平台的内容。
  Future<void> _selectCategory(
    MusicPlatform platform,
    String? categoryId,
  ) async {
    if (_selectedCategory[platform] == categoryId) return;
    setState(() => _selectedCategory[platform] = categoryId);
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    final key = (platform: platform, categoryId: categoryId);
    if (_collectionState.hasLoaded(key) || _collectionState.isLoading(key)) {
      return;
    }
    await _loadCollection(service, platform, categoryId);
  }

  Future<void> _loadCharts(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _chartState,
    platform,
    () => service.fetchChartList(
      platform: platform,
      limit: widget.chartPreviewLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台榜单失败',
  );

  Future<void> _loadCollection(
    OnlineMusicService service,
    MusicPlatform platform,
    String? categoryId,
  ) => loadRemoteList(
    _collectionState,
    (platform: platform, categoryId: categoryId),
    () => service.fetchPlaylistCollection(
      platform: platform,
      limit: widget.collectionLimit,
      offset: 0,
      categoryId: categoryId,
      cancelToken: newCancelToken(),
    ),
    fallback: categoryId == null ? '读取该平台歌单失败' : '读取该分类的歌单失败',
  );

  /// 把平台内容**订阅到本机**（复用既有订阅链路），成功后打开详情。
  ///
  /// 榜单与歌单共用这一条路径：榜单在榜单型平台上就是歌单（实测网易云的榜单 id
  /// 可直接用于歌单详情），因此"订阅后打开"对两者语义一致。
  Future<void> _subscribe(
    RemotePlaylistSummary summary, {
    String failureLabel = '订阅该歌单失败',
  }) async {
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
        controller.snapshot.errorMessage ?? failureLabel,
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
    return PageScaffold(
      title: '探索',
      subtitle: '按平台浏览内容，来源始终可见',
      actions: [
        IconButton.filledTonal(
          tooltip: '搜索在线音乐',
          onPressed: () => context.go(app_paths.ONLINE_MUSIC_PAGE),
          icon: const Icon(Symbols.search),
        ),
        IconButton.filledTonal(
          tooltip: '刷新',
          // 接 `_load` 而不是 `_reload`：先清掉旧错误再重新拉取（见 `_load` 的注释）。
          onPressed: _load,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav, right: 20),
        children: [
          _buildCharts(),
          _buildNewSongs(),
          _buildCategories(),
          _buildPlatformCollections(),
          PlatformCapabilityView(
            capabilities: service?.capabilities,
            onConfigure: () => context.go(app_paths.SETTINGS_PAGE),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- 榜单

  /// 榜单货架：**只对"点得开"的平台出现**。
  ///
  /// 一个平台都没有时整块不渲染（不是渲染成空）—— 这是三态原则的直接要求：
  /// "平台不支持"与"没有内容"必须长得不一样。
  Widget _buildCharts() {
    if (_chartPlatforms.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: '榜单',
      subtitle: '各平台的名次集合；打开后走歌单详情，曲目可播放',
      actionLabel: '查看全部',
      onAction: () => context.push(app_paths.EXPLORE_CHART_LIST_PAGE),
      child: Column(
        children: [
          for (final platform in _chartPlatforms) _buildChartShelf(platform),
        ],
      ),
    );
  }

  Widget _buildChartShelf(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final all = _chartState.items(platform);
    // 真实服务可能忽略 limit 并一次返回全部（网易云 `/toplist` 就是）⇒ 货架自己截断，
    // 全量交给「查看全部」的网格页。
    final preview = all.take(widget.chartPreviewLimit).toList(growable: false);
    final width = _cardWidth;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${musicPlatformLabel(platform)}'
            '${all.length > preview.length ? ' · ${all.length} 个榜单' : ''}',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: AppType.caption,
              fontWeight: AppType.weightSemibold,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          HorizontalShelf(
            loading: _chartState.isLoading(platform),
            errorMessage: _chartState.error(platform),
            onRetry: () => _retryCharts(platform),
            emptyMessage: '该平台没有返回榜单。',
            emptyIcon: Symbols.leaderboard,
            itemCount: preview.length,
            itemWidth: width,
            itemHeight: RemoteMediaCard.extentFor(
              width: width,
              hasFooter: true,
            ),
            itemBuilder: (context, index) {
              final summary = preview[index];
              return RemoteMediaCard(
                width: width,
                title: summary.name,
                coverUri: summary.coverUri,
                details: _chartDetailsOf(summary),
                sourceLabel: platformLabelForIdentityOnly(summary.identity),
                placeholderIcon: Symbols.leaderboard,
                onTap: _subscribing.contains(platform)
                    ? null
                    : () => _subscribe(summary, failureLabel: '打开该榜单失败'),
                semanticLabel:
                    '${summary.name}，来自${platformLabelForIdentityOnly(summary.identity)}，点击订阅并打开',
                footer: TextButton(
                  onPressed: _subscribing.contains(platform)
                      ? null
                      : () => _subscribe(summary, failureLabel: '打开该榜单失败'),
                  child: const Text('订阅'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 榜单卡片：元信息行统一为「**类型 · …**」两段式（参考产品的做法 —— 先在开头点名
  /// 内容类型，再跟最能区分它的信息）。榜单用**更新节奏**，最后是曲目数。
  String _chartDetailsOf(RemotePlaylistSummary summary) {
    final frequency = summary.updateFrequency?.trim();
    return [
      '榜单',
      if (frequency != null && frequency.isNotEmpty) frequency,
      if (summary.trackCount != null) '${summary.trackCount} 首',
    ].join(' · ');
  }

  Future<void> _retryCharts(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadCharts(service, platform);
  }

  // ----------------------------------------------------------------- 新歌

  /// 新歌：**曲目列表用行**（与榜单/歌单的卡片不同 —— 曲目要看清歌名与艺人）。
  ///
  /// 只对 [OnlineMusicCapabilities.playableNewSongPlatforms] 出现：列表里放一批点不响的
  /// 曲目比不显示更糟。
  Widget _buildNewSongs() {
    if (_newSongPlatforms.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: '新歌',
      subtitle: '各平台最近发布的曲目；点一行即从该平台的新歌开始播放',
      child: Column(
        children: [
          for (final platform in _newSongPlatforms)
            _buildNewSongSection(platform),
        ],
      ),
    );
  }

  Widget _buildNewSongSection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = _newSongState.items(platform);
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
          if (_newSongState.isLoading(platform))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Spacing.lg),
              child: Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_newSongState.error(platform) case final message?)
            InlineFailureHint(
              message: message,
              onRetry: () => _retryNewSongs(platform),
            )
          else if (tracks.isEmpty)
            const InlineEmptyHint(
              icon: Symbols.new_releases,
              message: '该平台没有返回新歌。',
            )
          else
            // 队列 = 该平台的新歌这一批（来源身份天然不混别的平台）。
            for (final track in tracks)
              OnlineTrackEntry(
                track: track,
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

  Future<void> _retryNewSongs(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadNewSongs(service, platform);
  }

  // ------------------------------------------------------------- 歌单分类

  /// 分类 chip 墙：**只对"能按分类取到歌单"的平台出现**。
  ///
  /// chip 墙放在「平台歌单」之前：它对下面那一块起**筛选**作用，位置本身就说明关系。
  /// 一个平台都没有时整块不渲染（三态原则：不支持 ≠ 没有内容）。
  Widget _buildCategories() {
    if (_categoryPlatforms.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: '歌单分类',
      subtitle: '点分类筛选下面的平台歌单；再点一次取消',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final platform in _categoryPlatforms)
            _buildCategoryWall(platform),
        ],
      ),
    );
  }

  Widget _buildCategoryWall(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final categories = _categoryState.items(platform);
    final selected = _selectedCategory[platform];
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
          if (_categoryState.isLoading(platform))
            const SizedBox(
              height: 32,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_categoryState.error(platform) case final message?)
            InlineFailureHint(
              message: message,
              onRetry: () => _retryCategories(platform),
            )
          else if (categories.isEmpty)
            const InlineEmptyHint(
              icon: Symbols.category,
              message: '该平台没有返回歌单分类。',
            )
          else
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                _CategoryChip(
                  label: '全部',
                  selected: selected == null,
                  onTap: () => _selectCategory(platform, null),
                ),
                for (final category in categories)
                  _CategoryChip(
                    label: category.count == null
                        ? category.name
                        : '${category.name} · ${category.count}',
                    selected: selected == category.id,
                    onTap: () => _selectCategory(
                      platform,
                      selected == category.id ? null : category.id,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _retryCategories(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadCategories(service, platform);
  }

  Widget _buildPlatformCollections() {
    final scheme = Theme.of(context).colorScheme;
    if (_platforms.isEmpty) {
      return ContentSection(
        title: '平台歌单',
        subtitle: '来自各平台自己的「歌单列表」能力',
        actionLabel: '去配置',
        onAction: () => context.go(app_paths.SETTINGS_PAGE),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Symbols.info, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                '当前没有可用的「歌单列表」服务：先在「设置 → 在线音乐 → 服务提供商」里'
                '为某个条目配置并试跑「歌单列表」能力（保存后重启生效），'
                '再到平台卡里选它做该能力的来源。',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }
    return ContentSection(
      title: '平台歌单',
      subtitle: '每个平台各自加载；一个平台失败不影响其它平台',
      child: Column(
        children: [
          for (final platform in _platforms) _buildPlatformSection(platform),
        ],
      ),
    );
  }

  Widget _buildPlatformSection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final categoryId = _selectedCategory[platform];
    final key = (platform: platform, categoryId: categoryId);
    final items = _collectionState.items(key);
    final width = _cardWidth;
    // 选中分类时把分类名写进小标题：否则用户只看到"网易云"，不知道这排是筛过的。
    final categoryName = categoryId == null
        ? null
        : _categoryState
              .items(platform)
              .where((category) => category.id == categoryId)
              .map((category) => category.name)
              .firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                categoryId == null
                    ? musicPlatformLabel(platform)
                    : '${musicPlatformLabel(platform)} · '
                          '${categoryName ?? categoryId}',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              if (categoryId != null)
                TextButton(
                  onPressed: () => _selectCategory(platform, null),
                  child: const Text('取消筛选'),
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          HorizontalShelf(
            // 只有**首次加载**才显示占位：分页时若也切成占位，用户已经看到的内容会整排消失。
            loading: _collectionState.isLoading(key) && items.isEmpty,
            // 同理：有内容时把失败留给下面的分页区展示，不要因为"加载更多"失败而把列表整个盖掉。
            errorMessage: items.isEmpty ? _collectionState.error(key) : null,
            onRetry: () => _retry(platform, categoryId),
            emptyMessage: categoryId == null
                ? '该平台没有返回歌单。'
                : '该分类下没有歌单。',
            emptyIcon: Symbols.queue_music,
            itemCount: items.length,
            itemWidth: width,
            itemHeight: RemoteMediaCard.extentFor(
              width: width,
              hasFooter: true,
            ),
            itemBuilder: (context, index) {
              final summary = items[index];
              return RemoteMediaCard(
                width: width,
                title: summary.name,
                coverUri: summary.coverUri,
                details: _detailsOf(summary),
                sourceLabel: platformLabelForIdentityOnly(summary.identity),
                placeholderIcon: Symbols.queue_music,
                onTap: () => _subscribe(summary),
                semanticLabel: '${summary.name}，来自'
                    '${platformLabelForIdentityOnly(summary.identity)}，点击订阅并打开',
                footer: TextButton(
                  onPressed: _subscribing.contains(platform)
                      ? null
                      : () => _subscribe(summary),
                  child: const Text('订阅'),
                ),
              );
            },
          ),
          if (items.isNotEmpty)
            _buildCollectionPager(platform, categoryId, key),
        ],
      ),
    );
  }

  /// 平台歌单的**分页区**：真实服务确实能翻页（网易云 `/top/playlist` 实测
  /// `offset` 有效、`total=683`），因此不给"加载更多"就等于把大部分歌单藏起来。
  ///
  /// ⚠️ 能力层的返回值是**裸列表**，平台的 `total` / `more` 没有传上来，
  /// 所以"还有没有更多"只能按**上一页是否取满**推断（与搜索页 `hasMore` 的第二重判定同源）。
  /// 推断错也不会误导：取回一页后发现不满就直接显示"没有更多了"。
  Widget _buildCollectionPager(
    MusicPlatform platform,
    String? categoryId,
    _CollectionKey key,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final loading = _collectionState.isLoading(key);
    if (loading) {
      return const Padding(
        padding: EdgeInsets.only(top: Spacing.sm),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_collectionState.error(key) case final message?) {
      return Padding(
        padding: const EdgeInsets.only(top: Spacing.sm),
        child: InlineFailureHint(
          message: message,
          onRetry: () => _loadMoreCollection(platform, categoryId),
        ),
      );
    }
    final hasMore =
        _collectionState.lastPageCount(key) >= widget.collectionLimit;
    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.only(top: Spacing.sm),
        child: Text(
          '没有更多了',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: AppType.caption,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          key: ValueKey(
            'explore-collection-more-${platform.name}-${categoryId ?? 'all'}',
          ),
          onPressed: () => _loadMoreCollection(platform, categoryId),
          icon: const Icon(Symbols.expand_more, size: 20),
          label: const Text('加载更多'),
        ),
      ),
    );
  }

  Future<void> _loadMoreCollection(
    MusicPlatform platform,
    String? categoryId,
  ) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    final key = (platform: platform, categoryId: categoryId);
    final offset = _collectionState.items(key).length;
    await loadRemoteList(
      _collectionState,
      key,
      () => service.fetchPlaylistCollection(
        platform: platform,
        limit: widget.collectionLimit,
        offset: offset,
        categoryId: categoryId,
        cancelToken: newCancelToken(),
      ),
      fallback: '加载更多失败',
      append: true,
    );
  }

  /// 平台歌单卡片：元信息行统一为「**类型 · …**」，类型是「歌单」。
  String _detailsOf(RemotePlaylistSummary summary) {
    final creator = summary.creator?.trim();
    return [
      '歌单',
      if (creator != null && creator.isNotEmpty) creator,
      if (summary.trackCount != null) '${summary.trackCount} 首',
    ].join(' · ');
  }

  Future<void> _retry(MusicPlatform platform, String? categoryId) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadCollection(service, platform, categoryId);
  }
}

/// 分类 chip：选中态用主色容器，与既有 chip 语言一致（不引入新配色）。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primaryContainer
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: AppRadius.smCircular,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: 6,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppType.caption,
              color: selected
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
              fontWeight: selected ? AppType.weightMedium : null,
            ),
          ),
        ),
      ),
    );
  }
}
