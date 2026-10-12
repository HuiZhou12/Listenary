import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/horizontal_shelf.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **在线艺人页**（`artist` 能力，2026-10-12 新增）。
///
/// 与参考产品的 IA 对齐：头部是艺人（头像 + 名字 + 简介），下面是**热门歌曲**列表。
/// 参考产品的艺人页把「热门歌曲」放在「专辑」**之前** ✓（见 `docs/specs/`
/// 的参考分析 §3.1）；我们这一版先做热门歌曲 —— **专辑/单曲列表还没有对应能力**
/// （那需要"艺人作品列表"能力，属后续阶段 ✓），因此这里**不假装**有那一块 ✓。
///
/// 三态如实区分（与 Home/Explore 同一条纪律）：
/// - **未配置 / 不支持**：进入前就该被拦住（能力集合里没有该平台）⇒ 这里给中性说明 ✓；
/// - **失败**：错误文案 + 重试 ✓；
/// - **空**：该艺人**确实没有**热门曲目 ⇒ 中性提示、**不给重试** ✓。
class OnlineArtistPage extends StatefulWidget {
  const OnlineArtistPage({
    super.key,
    required this.platform,
    required this.artistId,
    this.initialName,
  });

  final MusicPlatform platform;

  /// 平台自己的艺人 id（**来自请求输入** ✓）。
  final String artistId;

  /// 从曲目行跳进来时已知的显示名：先渲染它，避免加载期间白屏 ✓。
  final String? initialName;

  @override
  State<OnlineArtistPage> createState() => _OnlineArtistPageState();
}

class _OnlineArtistPageState extends State<OnlineArtistPage> {
  OnlineArtist? _artist;
  String? _error;
  bool _loading = true;

  /// 首帧不在这里读 `context`（`initState` 里 `context.read` 会报错）⇒ 用这个开关
  /// 在 `didChangeDependencies` 里只启动一次 ✓。
  bool _started = false;

  OnlineMusicCancelToken? _token;

  /// **专辑区块**（`artistAlbums`，2026-10-12）：与热门歌曲**各算各的** ✓。
  ///
  /// `_albumsSupported` 为 false 时**整块不显示** ✓ —— 平台不支持还摆一个空区块，
  /// 只会让人以为"这个艺人没有专辑"（那是谎 ✓）。
  bool _albumsSupported = false;
  bool _albumsLoading = false;
  String? _albumsError;
  List<OnlineAlbumSummary> _albums = const [];
  OnlineMusicCancelToken? _albumsToken;

  /// **单曲区块**（`artistSongs`，2026-10-12）：参考里的「单曲和迷你专辑」✓。
  bool _songsSupported = false;
  bool _songsLoading = false;
  String? _songsError;
  List<MusicTrack> _songs = const [];
  OnlineMusicCancelToken? _songsToken;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  @override
  void dispose() {
    _token?.cancel();
    _albumsToken?.cancel();
    _songsToken?.cancel();
    super.dispose();
  }

  /// 艺人**单曲列表**（`artistSongs`）：与其它区块**互不影响** ✓。
  Future<void> _loadSongs(OnlineMusicService service) async {
    if (!service.capabilities.playableArtistSongPlatforms.contains(
      widget.platform,
    )) {
      if (!mounted) return;
      setState(() {
        _songsSupported = false;
        _songsLoading = false;
        _songs = const [];
      });
      return;
    }
    _songsToken?.cancel();
    final token = OnlineMusicCancelToken();
    _songsToken = token;
    setState(() {
      _songsSupported = true;
      _songsLoading = true;
      _songsError = null;
    });
    try {
      final songs = await service.fetchArtistSongs(
        platform: widget.platform,
        artistId: widget.artistId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _songs = songs;
        _songsLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _songsLoading = false;
        _songsError = error is OnlineMusicException
            ? error.safeMessage
            : '读取艺人单曲失败';
      });
    }
  }

  /// 艺人**专辑列表**（`artistAlbums`）：与热门歌曲**互不影响** ✓
  ///（热门歌曲失败不该把专辑区块也拖下水，反之亦然 ✓）。
  Future<void> _loadAlbums(OnlineMusicService service) async {
    if (!service.capabilities.openableArtistAlbumPlatforms.contains(
      widget.platform,
    )) {
      if (!mounted) return;
      setState(() {
        _albumsSupported = false;
        _albumsLoading = false;
        _albums = const [];
      });
      return;
    }
    _albumsToken?.cancel();
    final token = OnlineMusicCancelToken();
    _albumsToken = token;
    setState(() {
      _albumsSupported = true;
      _albumsLoading = true;
      _albumsError = null;
    });
    try {
      final albums = await service.fetchArtistAlbums(
        platform: widget.platform,
        artistId: widget.artistId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _albums = albums;
        _albumsLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _albumsLoading = false;
        _albumsError = error is OnlineMusicException
            ? error.safeMessage
            : '读取艺人专辑失败';
      });
    }
  }

  Future<void> _load() async {
    final service = context.read<OnlineMusicService?>();
    _token?.cancel();
    final token = OnlineMusicCancelToken();
    _token = token;
    if (service == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '在线音乐服务不可用：请先在设置里配置平台条目';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    // 专辑区块与热门歌曲**并行**加载 ✓（互不阻塞、互不牵连 ✓）。
    unawaited(_loadAlbums(service));
    unawaited(_loadSongs(service));
    try {
      final artist = await service.fetchArtist(
        platform: widget.platform,
        artistId: widget.artistId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _artist = artist;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        // 服务层给的是**可读且脱敏**的 `safeMessage`（与其它页面同一条纪律 ✓）。
        _error = error is OnlineMusicException
            ? error.safeMessage
            : '读取艺人详情失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final artist = _artist;
    final title = artist?.name ?? widget.initialName ?? '艺人';
    final subtitle = artist == null
        ? musicPlatformLabel(widget.platform)
        : '${musicPlatformLabel(widget.platform)} · ${artist.hotSongs.length} 首热门曲目';

    if (_error case final message?) {
      return PageScaffold(
        title: title,
        subtitle: '来源：${musicPlatformLabel(widget.platform)}',
        actions: [IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Symbols.refresh))],
        body: InlineFailureHint(message: message, onRetry: _load),
      );
    }
    if (_loading || artist == null) {
      return PageScaffold(
        title: title,
        subtitle: '来源：${musicPlatformLabel(widget.platform)}',
        actions: const [],
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return PageScaffold(
      title: title,
      subtitle: subtitle,
      actions: [
        IconButton(tooltip: '刷新', onPressed: _load, icon: const Icon(Symbols.refresh)),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
        children: [
          _ArtistHeader(artist: artist),
          const SizedBox(height: Spacing.lg),
          ContentSection(
            title: '热门歌曲',
            subtitle: '来自${musicPlatformLabel(artist.platform)}；点一行即从该艺人的热门歌曲开始播放',
            child: artist.hotSongs.isEmpty
                // **空是合法的**（艺人可能确实没有热门曲目）⇒ 中性提示、**不给重试** ✓。
                ? const InlineEmptyHint(
                    icon: Symbols.music_off,
                    message: '该艺人暂时没有热门曲目。',
                  )
                : Column(
                    children: [
                      for (final track in artist.hotSongs)
                        OnlineTrackEntry(
                          track: track,
                          onTap: () => _play(artist, track),
                        ),
                    ],
                  ),
          ),
          // **专辑区块**（`artistAlbums`）：参考艺人页里「热门歌曲」之后正是「专辑」✓。
          // 平台不支持时**整块不显示** ✓ —— 摆一个空区块会让人以为"这艺人没有专辑"（那是谎 ✗）。
          if (_albumsSupported) ...[
            const SizedBox(height: Spacing.lg),
            ContentSection(
              title: '专辑',
              subtitle: '来自${musicPlatformLabel(artist.platform)}；点一张打开专辑页',
              child: HorizontalShelf(
                itemCount: _albums.length,
                itemWidth: _albumCardWidth,
                itemHeight: RemoteMediaCard.extentFor(
                  width: _albumCardWidth,
                  hasFooter: false,
                ),
                loading: _albumsLoading,
                errorMessage: _albumsError,
                onRetry: _retryAlbums,
                emptyMessage: '这位艺人暂时没有公开专辑。',
                emptyIcon: Symbols.album,
                itemBuilder: (context, index) {
                  final album = _albums[index];
                  return RemoteMediaCard(
                    width: _albumCardWidth,
                    title: album.name,
                    coverUri: album.coverUri,
                    details: _albumDetailsOf(album),
                    sourceLabel: platformLabelForIdentityOnly(album.identity),
                    placeholderIcon: Symbols.album,
                    onTap: () => context.push(
                      app_paths.ONLINE_ALBUM_PAGE,
                      extra: (
                        platform: album.platform,
                        albumId: album.id,
                        name: album.name,
                      ),
                    ),
                    semanticLabel: '${album.name}，打开专辑',
                  );
                },
              ),
            ),
          ],
          // **单曲和迷你专辑区块**（`artistSongs`）：参考艺人页里「专辑」之后就是它 ✓。
          if (_songsSupported) ...[
            const SizedBox(height: Spacing.lg),
            ContentSection(
              title: '单曲和迷你专辑',
              subtitle: '来自${musicPlatformLabel(artist.platform)}；点一行即从这些单曲开始播放',
              child: _songsBody(),
            ),
          ],
        ],
      ),
    );
  }

  /// 专辑卡片的宽度（与 Explore 的货架同一种"能放下就固定宽"的朴素做法 ✓）。
  static const double _albumCardWidth = 168;

  /// 专辑卡片的元信息：**平台声明**的发行年份与曲目数（有什么说什么 ✓）。
  String _albumDetailsOf(OnlineAlbumSummary album) => [
    if (album.releaseTime case final time?) '${time.year} 年',
    if (album.trackCount case final count?) '$count 首',
  ].join(' · ');

  void _retryAlbums() {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    unawaited(_loadAlbums(service));
  }

  void _retrySongs() {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    unawaited(_loadSongs(service));
  }

  /// 单曲区块的三种状态（**空 ≠ 失败**：空给中性提示、失败才给重试 ✓）。
  Widget _songsBody() {
    if (_songsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _songsError;
    if (error != null) {
      return InlineFailureHint(message: error, onRetry: _retrySongs);
    }
    if (_songs.isEmpty) {
      return const InlineEmptyHint(
        icon: Symbols.music_off,
        message: '这位艺人暂时没有单曲。',
      );
    }
    return Column(
      children: [
        for (final song in _songs)
          OnlineTrackEntry(track: song, onTap: () => _playSongs(song)),
      ],
    );
  }

  Future<void> _playSongs(MusicTrack song) => playOnlineTrackSelection(
    context,
    OnlineTrackSelection.fromResultPage(tracks: _songs, selectedRef: song.ref),
  );

  Future<void> _play(OnlineArtist artist, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: artist.hotSongs,
          selectedRef: track.ref,
        ),
      );
}

/// 艺人头部：头像 + 名字 + 简介（简介为空时整块不占位 ✓）。
class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({required this.artist});

  final OnlineArtist artist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final description = artist.description?.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: AppRadius.mdCircular,
          child: SizedBox.square(
            dimension: 96,
            child: RemoteMediaCover(
              coverUri: artist.avatarUri,
              placeholder: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Icon(
                  Symbols.artist,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              cacheWidth: 192,
              cacheHeight: 192,
            ),
          ),
        ),
        const SizedBox(width: Spacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                artist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: AppType.hero,
                  fontWeight: AppType.weightSemibold,
                ),
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                musicPlatformLabel(artist.platform),
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: AppType.caption,
                ),
              ),
              if (description != null && description.isNotEmpty) ...[
                const SizedBox(height: Spacing.sm),
                Text(
                  description,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: AppType.body,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
