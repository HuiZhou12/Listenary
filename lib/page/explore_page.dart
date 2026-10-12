import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/platform_capability_view.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
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

  /// 新专辑（2026-10-12）：只取**既列得出、又打得开专辑详情**的平台
  ///（列出一批打不开的专辑，比不显示更糟 ✗ —— 与榜单「能列 vs 能开」同一条判据 ✓）。
  List<MusicPlatform> _newAlbumPlatforms = const [];
  final RemoteLoadState<MusicPlatform, OnlineAlbumSummary> _newAlbumState =
      RemoteLoadState<MusicPlatform, OnlineAlbumSummary>();

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
    final newAlbumPlatforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.openableNewAlbumPlatforms.contains(
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
      _newAlbumPlatforms = newAlbumPlatforms;
    });
    if (service == null) return;
    await Future.wait([
      for (final platform in chartPlatforms) _loadCharts(service, platform),
      for (final platform in newSongPlatforms)
        _loadNewSongs(service, platform),
      for (final platform in newAlbumPlatforms)
        _loadNewAlbums(service, platform),
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
    bool isRanked = false,
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
    if (isRanked) {
      // 从榜单订阅进来的 ⇒ 记下"这是名次集合"，详情页据此显示行首序号 ✓。
      // 记在偏好里（新增键值，**不动 DB schema** ✓）。
      // 落盘火焰式（`.ignore()`）：内存已标记；落盘失败只影响"重启后是否还显示序号"，
      // **不能**打断"订阅成功 → 进详情页"的主流程。
      AppPreference.instance.markRankedSubscription(saved.localId);
      AppPreference.instance.save().ignore();
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
          // 用户要求（2026-10-12）：**新专辑紧跟在榜单下方** ✓ —— 参考里它和「新歌」同属
          // 第一个区块「新专辑与单曲」✓，而榜单在前 ✓ ⇒ 现在顺序是 榜单 → 新专辑 → 新歌 ✓。
          _buildNewAlbums(),
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
    // 榜单封面**放大 15%**（2026-10-12 用户要求 ✓）：一屏里卡片太多会"眼花缭乱"✗，
    // 放大后一屏看到更少、但每张更清楚 ✓。只动**榜单**这一块，其余货架保持原尺寸 ✓。
    final width = _cardWidth * 1.15;
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
                    : () => _subscribe(summary, failureLabel: '打开该榜单失败', isRanked: true),
                semanticLabel:
                    '${summary.name}，来自${platformLabelForIdentityOnly(summary.identity)}，点击订阅并打开',
                footer: TextButton(
                  onPressed: _subscribing.contains(platform)
                      ? null
                      : () => _subscribe(summary, failureLabel: '打开该榜单失败', isRanked: true),
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

  Future<void> _loadNewAlbums(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    _newAlbumState,
    platform,
    () => service.fetchNewAlbums(
      platform: platform,
      limit: widget.newSongLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台新专辑失败',
  );

  Future<void> _retryNewAlbums(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadNewAlbums(service, platform);
  }

  // ----------------------------------------------------------------- 新专辑

  /// 新专辑：**卡片货架**（专辑是集合类内容 ⇒ 与榜单/歌单一样用卡片 ✓）。
  ///
  /// 只对 [OnlineMusicCapabilities.openableNewAlbumPlatforms] 出现：列出一批**打不开**的专辑
  /// 比不显示更糟 ✗（与榜单「能列 vs 能开」同一条判据 ✓）。
  /// 与「新歌」并列 ⇒ 合起来正是参考 Explore 的第一个区块「**新专辑与单曲**」✓。
  Widget _buildNewAlbums() {
    if (_newAlbumPlatforms.isEmpty) return const SizedBox.shrink();
    return ContentSection(
      title: '新专辑',
      subtitle: '各平台最近发布的专辑；点一张打开专辑页',
      // 「查看全部」→「新发行」页 ✓（与「新歌」一致 ✓）。
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.NEW_RELEASES_PAGE),
      child: Column(
        children: [
          for (final platform in _newAlbumPlatforms)
            _buildNewAlbumSection(platform),
        ],
      ),
    );
  }

  Widget _buildNewAlbumSection(MusicPlatform platform) {
    final scheme = Theme.of(context).colorScheme;
    final albums = _newAlbumState.items(platform);
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
            loading: _newAlbumState.isLoading(platform),
            errorMessage: _newAlbumState.error(platform),
            onRetry: () => _retryNewAlbums(platform),
            emptyMessage: '该平台没有返回新专辑。',
            emptyIcon: Symbols.album,
            itemCount: albums.length,
            itemWidth: width,
            itemHeight: RemoteMediaCard.extentFor(
              width: width,
              hasFooter: false,
            ),
            itemBuilder: (context, index) {
              final album = albums[index];
              return RemoteMediaCard(
                width: width,
                title: album.name,
                coverUri: album.coverUri,
                details: _newAlbumDetailsOf(album),
                sourceLabel: platformLabelForIdentityOnly(album.identity),
                placeholderIcon: Symbols.album,
                // 点开专辑页：专辑曲目**有序号**、整张可播 ✓（R83 已有页面 ✓）。
                onTap: () => _openAlbum(album),
                semanticLabel:
                    '${album.name}，来自${platformLabelForIdentityOnly(album.identity)}，点击打开专辑',
              );
            },
          ),
        ],
      ),
    );
  }

  /// 新专辑卡片：元信息沿用既有的「**类型 · …**」两段式 ✓（发行年份 + 曲目数都是平台声明的 ✓）。
  String _newAlbumDetailsOf(OnlineAlbumSummary album) => [
    '专辑',
    if (album.releaseTime case final time?) '${time.year} 年',
    if (album.trackCount case final count?) '$count 首',
  ].join(' · ');

  void _openAlbum(OnlineAlbumSummary album) {
    context.push(
      app_paths.ONLINE_ALBUM_PAGE,
      extra: (
        platform: album.platform,
        albumId: album.id,
        name: album.name,
      ),
    );
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
      // 「查看全部」→「新发行」页 ✓（等价于参考第一个区块的「更多」✓）。
      actionLabel: '查看全部',
      onAction: () => context.go(app_paths.NEW_RELEASES_PAGE),
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
            // **横向货架**（2026-10-12 用户要求 ✓）：此前每个平台一长列曲目 ⇒
            // 多平台时要往下翻很久才看得到后面的区块 ✗；改成货架后高度固定、
            // 用左右箭头**横向浏览** ✓（箭头只在能滚的一侧出现 ✓，与其它货架同一条规则 ✓）。
            HorizontalShelf(
              itemCount: tracks.length,
              itemWidth: _cardWidth,
              itemHeight: RemoteMediaCard.extentFor(
                width: _cardWidth,
                hasFooter: false,
              ),
              itemBuilder: (context, index) {
                final track = tracks[index];
                return RemoteMediaCard(
                  width: _cardWidth,
                  title: track.title,
                  coverUri: track.coverUri,
                  details: track.artistDisplay,
                  sourceLabel: platformLabelForRef(track.ref),
                  placeholderIcon: Symbols.music_note,
                  onTap: () => playOnlineSearchResult(
                    context,
                    tracks: tracks,
                    selectedRef: track.ref,
                  ),
                  semanticLabel: '播放"${track.title} - ${track.artistDisplay}"',
                );
              },
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
            // **分类 tag 墙**（2026-10-12 重做 ✓）：照参考的"左侧色条 + 圆角块"排布 ✓，
            // 但颜色**从主题色派生**（同饱和/亮度，只转色相 ✓）⇒ 像本应用的配色，不是贴图 ✓。
            // 点任何一个 tag 都**进子页面** ✓（不再原地筛选 ✗ —— 那条路会改状态，
            // 用户报告一点就崩 ✗；改成导航后每次都是干净的一次跳转 ✓）。
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (var i = 0; i < categories.length; i++)
                  _CategoryTile(
                    label: categories[i].name,
                    count: categories[i].count,
                    accent: _categoryAccent(scheme, i),
                    onTap: () => _openPlatformPlaylists(
                      platform,
                      categoryId: categories[i].id,
                      title:
                          '${musicPlatformLabel(platform)} · '
                          '${categories[i].name}',
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
              // 「查看全部」→ **平台歌单列表页** ✓（用户要求：这里不要在横向货架里追加，
              // 改成进子页、由子页**滑到底自动加载** ✓ —— 那才感觉得到"内容更多了" ✓）。
              TextButton(
                onPressed: () => _openPlatformPlaylists(
                  platform,
                  categoryId: categoryId,
                  title: categoryId == null
                      ? '${musicPlatformLabel(platform)} · 歌单'
                      : '${musicPlatformLabel(platform)} · '
                            '${categoryName ?? categoryId}',
                ),
                child: const Text('查看全部'),
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
                // **点卡片本体不再自动订阅**（2026-10-12 用户报告 ✓）：
                // 此前点一下就会把这张歌单**加进媒体库** ✗（用户没点订阅却订阅了 ✓）。
                // 现在只有下面的「订阅」按钮会订阅 ✓；卡片本体不做事 ✓
                //（我们还没有"不进库只看"的预览页 ✗ ⇒ 宁可不做，也不替用户做决定 ✓）。
                onTap: null,
                semanticLabel: '${summary.name}，来自'
                    '${platformLabelForIdentityOnly(summary.identity)}，'
                    '用下方的「订阅」按钮订阅',
                footer: TextButton(
                  onPressed: _subscribing.contains(platform)
                      ? null
                      : () => _subscribe(summary),
                  child: const Text('订阅'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 打开「平台歌单列表页」（分类 tag 与「查看全部」都走这里 ✓）。
  Future<void> _openPlatformPlaylists(
    MusicPlatform platform, {
    required String title,
    String? categoryId,
  }) => context.push(
    app_paths.PLATFORM_PLAYLISTS_PAGE,
    extra: (platform: platform, categoryId: categoryId, title: title),
  );


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

/// 分类 tag 的**左侧色条**颜色：从主题色派生（保持同饱和/亮度，只错开色相 ✓）⇒
/// 一屏里颜色有层次、又不会跑出本应用的配色体系 ✓。
Color _categoryAccent(ColorScheme scheme, int index) {
  final base = HSLColor.fromColor(scheme.primary);
  return base.withHue((base.hue + index * 47) % 360).toColor();
}

/// **分类 tag**（2026-10-12 新样式 ✓）：参考的是"左侧一条彩条 + 圆角方块 + 名字"✓；
/// 这是本应用的版本 —— 高度统一 44 ✓、圆角用 `AppRadius.sm` ✓、
/// 名称后面跟一个**淡色的数量**（平台给了才显示 ✓ —— 不编造 ✓）。
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.label,
    required this.accent,
    required this.onTap,
    this.count,
  });

  final String label;
  final int? count;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: AppRadius.smCircular,
      child: InkWell(
        borderRadius: AppRadius.smCircular,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 132, minHeight: 44),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 左侧彩条：贴住左边、上圆下圆对齐容器 ⇒ 参考里那种"色标"✓。
              Container(
                width: 4,
                height: 44,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(AppRadius.sm),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 超长分类名（真实数据里就有很长的那种 ✓）不能把方块撑破 ⇒ 限宽 + 省略 ✓。
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.onSurface,
                          fontWeight: AppType.weightMedium,
                        ),
                      ),
                    ),
                    if (count case final value?) ...[
                      const SizedBox(width: Spacing.sm),
                      Text(
                        '$value',
                        style: TextStyle(
                          fontSize: AppType.caption,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
