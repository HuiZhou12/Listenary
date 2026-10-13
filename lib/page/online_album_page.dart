import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **在线专辑页**（`album` 能力，2026-10-12 新增；同日改为**统一骨架** ✓）。
///
/// **骨架统一**（用户要求 ✓）：与「本地歌单」两页、以及歌单预览页用**同一个**
/// [UniDetailPage] ✓（主图 + 标题/副标题 + 动作区 + 曲目列表 ✓）。
///
/// 元素按**专辑这个接口实际有什么**来定 ✓：
/// - **有**：封面/专辑名/专辑艺人/发行年份 ✓、曲目**带行首序号**（专辑曲目**有序** ✓，
///   与参考产品一致 ✓）、播放全部 ✓、刷新 ✓、列表/网格切换 ✓、搜索 ✓；
/// - **没有（因此不出现 ✗）**：排序（专辑顺序就是唱片顺序，不能被我们重排 ✓）、
///   洗牌（同上 ✓）、收藏（专辑本身不可收藏 ✓）。
///
/// 三态如实区分（与 Home/Explore/艺人页同一条纪律 ✓）：
/// - **失败** ⇒ 可读错误 + 重试 ✓；
/// - **空**（这张专辑确实没有曲目）⇒ 中性提示、**不给重试** ✓；
/// - 加载中先用调用方给的专辑名占位（不白屏 ✓）。
///
/// **两个"曲目数"不混为一谈** ✓：平台标注的 `size` 与**实际取到的条数**可能不同 ⇒
/// 默认显示实际条数 ✓，只有不一致时才把平台标注也说出来 ✓（写进副标题 ✓）。
class OnlineAlbumPage extends StatefulWidget {
  const OnlineAlbumPage({
    super.key,
    required this.platform,
    required this.albumId,
    this.initialName,
  });

  final MusicPlatform platform;

  /// 平台自己的专辑 id（**来自请求输入** ✓）。
  final String albumId;

  /// 从曲目行跳进来时已知的专辑名：先渲染它，避免加载期间白屏 ✓。
  final String? initialName;

  @override
  State<OnlineAlbumPage> createState() => _OnlineAlbumPageState();
}

class _OnlineAlbumPageState extends State<OnlineAlbumPage> {
  OnlineAlbum? _album;
  String? _error;
  bool _loading = true;
  bool _started = false;
  String _searchQuery = '';
  OnlineMusicCancelToken? _token;
  Future<ImageProvider?> _primaryPic = Future.value(null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
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
    try {
      final album = await service.fetchAlbum(
        platform: widget.platform,
        albumId: widget.albumId,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _album = album;
        _loading = false;
        _primaryPic = _coverProvider(album.coverUri);
      });
    } on Object catch (error) {
      if (!mounted || token.isCancelled) return;
      setState(() {
        _loading = false;
        _error = error is OnlineMusicException
            ? error.safeMessage
            : '读取专辑详情失败';
      });
    }
  }

  Future<ImageProvider?> _coverProvider(Uri? uri) async {
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return null;
    }
    return CachedRemoteImageProvider(uri.toString());
  }

  void _openArtist(OnlineAlbum album) {
    final artistId = album.artistId;
    if (artistId == null || artistId.isEmpty) return;
    context.push(
      app_paths.ONLINE_ARTIST_PAGE,
      extra: (
        platform: album.platform,
        artistId: artistId,
        name: album.artist,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    final title = album?.name ?? widget.initialName ?? '专辑';
    final platformName = musicPlatformLabel(widget.platform);
    // 平台标注的曲目数只在**与实际条数不一致**时说，避免把两个数混成一个 ✓。
    final declared = album?.trackCount;
    final actual = album?.tracks.length ?? 0;
    final mismatch = declared != null && declared != actual;
    final releaseYear = album?.releaseTime?.year;
    final artist = album?.artist?.trim();
    final subtitle = [
      '来源：$platformName',
      if (artist != null && artist.isNotEmpty) artist,
      if (releaseYear != null) '$releaseYear 年',
      if (album != null) '$actual 首曲目',
      // 不一致时**明说差异** ✓（以实际为准 ✓）—— 沿用既有措辞 ✓。
      if (mismatch)
        '平台标注这张专辑有 $declared 首，本次实际取到 $actual 首（以实际为准）',
    ].join(' · ');

    // 失败 / 加载中仍走页壳 ✓（与本地歌单页、预览页一致 ✓）。
    if (_error case final message?) {
      return PageScaffold(
        title: title,
        subtitle: '来源：$platformName',
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => unawaited(_load()),
            icon: const Icon(Symbols.refresh),
          ),
        ],
        body: InlineFailureHint(
          message: message,
          onRetry: () => unawaited(_load()),
        ),
      );
    }
    if (_loading || album == null) {
      return PageScaffold(
        title: title,
        subtitle: '来源：$platformName',
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    // **空（这张专辑确实没有曲目）** ⇒ 中性提示、**不给重试** ✓ —— 与歌单预览页同一条做法 ✓
    //（空 ≠ 失败：空态出现"重试"会让人以为读取出错了 ✗）。
    if (album.tracks.isEmpty) {
      return PageScaffold(
        title: album.name,
        subtitle: subtitle,
        body: const InlineEmptyHint(
          icon: Symbols.music_off,
          message: '这张专辑暂时没有曲目。',
        ),
      );
    }

    final query = _searchQuery.trim().toLowerCase();
    final tracks = query.isEmpty
        ? album.tracks
        : [
            for (final track in album.tracks)
              if (track.title.toLowerCase().contains(query) ||
                  track.artistDisplay.toLowerCase().contains(query))
                track,
          ];
    final playable = [
      for (final track in tracks)
        if (track.availability == TrackAvailability.playable) track,
    ];

    // 与本地歌单两页**同一个**主按钮样式 ✓。
    const primaryActionStyle = ButtonStyle(
      fixedSize: WidgetStatePropertyAll(Size.fromHeight(40)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
    );

    // **统一骨架** ✓。
    return UniDetailPage<OnlineAlbum, MusicTrack, Object>(
      pref: AppPreference.instance.albumDetailPagePref,
      primaryContent: album,
      primaryPic: _primaryPic,
      backgroundPic: Future.value(null),
      picShape: PicShape.rrect,
      title: album.name,
      subtitle: subtitle,
      // 专辑里这一块叫「曲目」（唱片语境 ✓）；骨架允许改这个标题 ✓（默认是「歌曲」✓）。
      secondaryContentTitle: '曲目',
      secondaryContent: tracks,
      secondaryContentBuilder: (context, track, index, msc, view) =>
          OnlineTrackEntry(
            track: track,
            // 专辑曲目是**有序集合** ⇒ 给出序号 ✓（与参考产品一致 ✓）。
            leadingIndex: index + 1,
            onTap: () => playOnlineTrackSelection(
              context,
              OnlineTrackSelection.fromResultPage(
                tracks: tracks,
                selectedRef: track.ref,
              ),
            ),
          ),
      // 排序与洗牌都关掉 ✓：专辑顺序**就是唱片顺序**，不该被我们重排 ✓。
      enableShufflePlay: false,
      enableSortMethod: false,
      enableSortOrder: false,
      enableSecondaryContentViewSwitch: true,
      enableSearch: true,
      searchQuery: _searchQuery,
      onSearchChanged: (value) => setState(() => _searchQuery = value),
      extraActions: [
        FilledButton.icon(
          onPressed: playable.isEmpty
              ? null
              : () => playOnlineTrackSelection(
                  context,
                  OnlineTrackSelection.fromResultPage(
                    tracks: playable,
                    selectedRef: playable.first.ref,
                  ),
                ),
          icon: const Icon(Symbols.play_arrow, size: 20),
          label: const Text('播放全部'),
          style: primaryActionStyle,
        ),
        if (artist != null && artist.isNotEmpty)
          FilledButton.tonalIcon(
            onPressed: (album.artistId ?? '').isEmpty
                ? null
                : () => _openArtist(album),
            icon: const Icon(Symbols.artist, size: 20),
            label: const Text('查看艺人'),
          ),
        FilledButton.tonalIcon(
          onPressed: () => unawaited(_load()),
          icon: const Icon(Symbols.refresh, size: 20),
          label: const Text('刷新'),
        ),
      ],
    );
  }
}
