import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/page/uni_detail_page.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

/// **远程歌单预览页**（2026-10-12 新增 ✓；同日改为**统一骨架** ✓）。
///
/// 为什么要有它：此前"看歌单"必须**先订阅** ✗ —— 因为详情页只读本地库 ✓。
/// 用户点封面于是要么被**偷偷订阅**（榜单卡片 ✗），要么**毫无反应**（平台歌单卡片 ✗）。
///
/// 现在的规则 ✓：
/// - **点封面 = 打开本页预览** ✓ —— **只读**，一个字节都不写库 ✗（`fetchPlaylist` 直接用 ✓）；
/// - 页内「**订阅**」= 只入库 ✓，**不跳转** ✗（订阅完还留在这页 ✓，按钮变成"已订阅"✓）；
/// - 想看自己订阅的那份（可同步 ✓）⇒ 从媒体库进订阅详情页 ✓。
///
/// **骨架统一**（用户要求 ✓）：与「本地歌单」那两页用**同一个** [UniDetailPage] ✓
///（主图 + 标题/副标题 + 动作区 + 曲目列表 ✓）。
/// 元素按这个接口**有什么放什么** ✓：
/// - 有：播放全部 ✓、订阅 ✓、刷新 ✓、列表/网格切换 ✓、搜索 ✓；
/// - 没有（因此不出现 ✗）：排序（这里没有"名次/添加时间"可排 ✓）、洗牌
///   （未订阅的临时列表，洗牌语义含糊 ✓ —— 本地歌单页也把洗牌关掉了 ✓）。
class RemotePlaylistPage extends StatefulWidget {
  const RemotePlaylistPage({
    super.key,
    required this.platform,
    required this.playlistId,
    required this.name,
    this.coverUri,
    this.creator,
    this.trackCount,
    this.ranked = false,
  });

  final MusicPlatform platform;
  final String playlistId;

  /// 列表页已经有的元信息：先渲染出来 ✓，曲目再慢慢来 ✓（不让整页等）。
  final String name;
  final Uri? coverUri;
  final String? creator;
  final int? trackCount;

  /// **名次集合**（榜单）才给行首序号 ✓ —— 与订阅详情页同一条规则 ✓。
  final bool ranked;

  @override
  State<RemotePlaylistPage> createState() => _RemotePlaylistPageState();
}

class _RemotePlaylistPageState extends State<RemotePlaylistPage>
    with RemoteListLoading<RemotePlaylistPage> {
  static const _key = 0;

  final RemoteLoadState<int, MusicTrack> _tracks =
      RemoteLoadState<int, MusicTrack>();
  RemotePlaylist? _detail;
  Future<ImageProvider?> _primaryPic = Future.value(null);
  String _searchQuery = '';
  bool _subscribed = false;
  bool _subscribing = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() => loadRemoteList(
    _tracks,
    _key,
    () async {
      final service = context.read<OnlineMusicService?>();
      if (service == null) {
        throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.unavailable,
          safeMessage: '当前没有可用的在线音乐服务',
        );
      }
      final detail = await service.fetchPlaylist(
        platform: widget.platform,
        playlistId: widget.playlistId,
        cancelToken: newCancelToken(),
      );
      if (mounted) {
        setState(() {
          _detail = detail;
          _primaryPic = _coverProvider(detail.coverUri);
        });
      }
      return detail.tracks;
    },
    fallback: '读取该歌单失败',
  );

  Future<ImageProvider?> _coverProvider(Uri? uri) async {
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return null;
    }
    return CachedRemoteImageProvider(uri.toString());
  }

  /// 「订阅」= 只入库 ✓，**不跳转** ✗（用户问过"点订阅为啥会自动进详情" ✓ —— 现在不会了 ✓）。
  Future<void> _subscribe() async {
    if (_subscribing || _subscribed) return;
    setState(() => _subscribing = true);
    final controller = context.read<OnlinePlaylistController>();
    final saved = await controller.addOrRefresh(
      platform: widget.platform,
      remotePlaylistId: widget.playlistId,
    );
    if (!mounted) return;
    setState(() {
      _subscribing = false;
      _subscribed = saved != null;
    });
    if (saved == null) {
      showTextOnSnackBar(
        controller.snapshot.errorMessage ?? '订阅该歌单失败',
        variant: ToastVariant.error,
      );
      return;
    }
    if (widget.ranked) {
      // 榜单是**名次集合** ⇒ 记下这一点，订阅详情页据此显示行首序号 ✓（不动 DB schema ✓）。
      AppPreference.instance.markRankedSubscription(saved.localId);
      AppPreference.instance.save().ignore();
    }
    showTextOnSnackBar(
      '已订阅「${saved.playlist.name}」，可在媒体库查看',
      variant: ToastVariant.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final tracks = _tracks.items(_key);
    final name = detail?.name ?? widget.name;
    final creator = (detail?.creator ?? widget.creator)?.trim();
    final count = detail?.trackCount ?? widget.trackCount;
    final coverUri = detail?.coverUri ?? widget.coverUri;
    final subtitle = [
      musicPlatformLabel(widget.platform),
      if (creator != null && creator.isNotEmpty) creator,
      if (count != null) '$count 首歌曲',
      '预览（未订阅，不会写进媒体库）',
    ].join(' · ');

    // **加载 / 失败 / 空** 这三种"还没有内容"的状态仍走页壳 ✓ —— 与本地歌单页一致
    //（它们也是先 PageScaffold 报错、有内容了才用 UniDetailPage ✓）。
    //
    // ⚠️ 2026-10-17（F4）修正 ✓：这三态此前用的是**区块级**的 `Inline*Hint` 与默认尺寸的
    // 转圈 ✗ —— 但它们占的是**整页**，于是同一个"在线歌单"在预览页是一行小字、在订阅详情页
    // 是居中空态（同一族两种观感 ✗）。现在按既有分工统一：
    // **页面级 ⇒ [PageLoadingIndicator] + [QuietEmptyState]**，
    // **区块级 ⇒ `Inline*Hint`**（区块级的用法见 `horizontal_shelf` / `explore_page`）。
    if (_tracks.isLoading(_key) && tracks.isEmpty) {
      return PageScaffold(
        title: name,
        subtitle: subtitle,
        body: const PageLoadingIndicator(),
      );
    }
    final error = _tracks.error(_key);
    if (tracks.isEmpty && error != null) {
      return PageScaffold(
        title: name,
        subtitle: subtitle,
        body: QuietEmptyState(
          icon: Symbols.cloud_off,
          title: '歌单读取失败',
          message: error,
          action: FilledButton.tonalIcon(
            onPressed: () => unawaited(_load()),
            icon: const Icon(Symbols.refresh),
            label: const Text('重试'),
          ),
        ),
      );
    }
    if (tracks.isEmpty) {
      return PageScaffold(
        title: name,
        subtitle: subtitle,
        // **空 ≠ 失败**：这是"歌单确实没有可播曲目"⇒ 中性提示、**不给重试** ✓
        //（给了重试就等于说"刚才那次读取失败了"，那是谎 ✓）。
        body: const QuietEmptyState(
          icon: Symbols.music_off,
          title: '这个歌单没有可播放的曲目',
          message: '换一个歌单，或稍后再看这个歌单。',
        ),
      );
    }

    final query = _searchQuery.trim().toLowerCase();
    final visible = query.isEmpty
        ? tracks
        : [
            for (final track in tracks)
              if (track.title.toLowerCase().contains(query) ||
                  track.artistDisplay.toLowerCase().contains(query))
                track,
          ];
    // **"能不能播"与行用同一套判据**（2026-10-17 统一 ✓，用户裁定 W6/F1）：
    // 此前这里只问"解析侧有没有人能处理这条身份"✗，而行（`OnlineTrackEntry`）另按
    // 内容平台的 `availability` 判 ⇒ 同一页里**行灰掉、但「播放全部」把它算进了队列** ✗。
    // 现在两处都走 [OnlineTrackEntry.playableOf]，而它就是
    // `capabilities.canPlayTrack`（解析侧身份 **且** 平台未声明 paid/unavailable，
    // `unknown` 放行 ✓ —— 这正是 F1 定下的唯一语义 ✓）。
    final service = context.read<OnlineMusicService?>();
    final playableTracks = [
      for (final track in visible)
        if (OnlineTrackEntry.playableOf(
          track: track,
          providerCapabilities: service?.capabilities,
        ))
          track,
    ];

    // **每个动作按钮都给同一套显式样式**（用户指出高度不齐 ✗）：
    // 只给「播放全部」加样式、其它按钮走默认高度 ⇒ 一排按钮高矮不一 ✗（本地歌单页是都给 ✓）。
    // 注意：`AppRadius.smCircular` 不是编译期常量 ⇒ 这里**不能**加 `const` ✗。
    final actionStyle = ButtonStyle(
      fixedSize: const WidgetStatePropertyAll(Size.fromHeight(40)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: AppRadius.smCircular),
      ),
    );

    // **统一骨架** ✓：与「本地歌单」两页同一个 [UniDetailPage] ✓。
    return UniDetailPage<RemotePlaylist, MusicTrack, Object>(
      pref: AppPreference.instance.onlinePlaylistDetailPagePref,
      primaryContent:
          detail ??
          RemotePlaylist(
            platform: widget.platform,
            id: widget.playlistId,
            name: name,
            coverUri: coverUri,
            creator: creator,
            trackCount: count,
          ),
      primaryPic: _primaryPic,
      backgroundPic: Future.value(null),
      picShape: PicShape.rrect,
      title: name,
      subtitle: subtitle,
      secondaryContent: visible,
      secondaryContentBuilder: (context, track, index, msc, view) =>
          OnlineTrackEntry(
            track: track,
            // 行与「播放全部」共用页面上算好的同一份结论 ✓（不再各判各的 ✓）。
            playable: OnlineTrackEntry.playableOf(
              track: track,
              providerCapabilities: service?.capabilities,
            ),
            onTap: () => playOnlineTrackSelection(
              context,
              OnlineTrackSelection.fromResultPage(
                tracks: visible,
                selectedRef: track.ref,
              ),
            ),
            // **不标序号**（2026-10-12 用户裁定 ✓）：歌单里每首歌都带"1、2、3"只会让列表显得吵 ✗
            //（组件仍保留这个能力 ✓，留给将来真需要的地方 ✓）。
          ),
      // 洗牌 / 排序在这个页面上**不成立**（没有名次或添加时间可排 ✓）⇒ 两个开关都关掉 ✓，
      // 「骨架」仍是同一套 ✓（用户要求：骨架统一、元素按接口定 ✓）。
      enableShufflePlay: false,
      enableSortMethod: false,
      enableSortOrder: false,
      enableSecondaryContentViewSwitch: true,
      enableSearch: true,
      searchQuery: _searchQuery,
      onSearchChanged: (value) => setState(() => _searchQuery = value),
      extraActions: [
        // **灰色 = 真的按不了**（用户问过 ✓）：这一批曲目若**全部不可播**（待解锁/需会员 ✓）
        // 就禁用 ✓（不给按了没反应的按钮 ✓）；但**必须说明理由** ✗ ⇒ 悬停提示讲清楚 ✓。
        Tooltip(
          message: playableTracks.isEmpty
              ? '这批曲目当前都不可播（平台未放行，或没有任何平台握有解析权限）⇒ 所以按不了'
              : '从这批曲目开始播放（由握有解析权限的平台解析）',
          child: FilledButton.icon(
            onPressed: playableTracks.isEmpty
                ? null
                : () => playOnlineTrackSelection(
                    context,
                    OnlineTrackSelection.fromResultPage(
                      tracks: playableTracks,
                      selectedRef: playableTracks.first.ref,
                      // 队列已经按**统一判据**筛过了 ⇒ 不要再让旧的内容平台标记过滤一遍 ✗
                      //（那会把可播曲目又被 `paid` 标记踢掉，与行上的结论再次分叉）。
                      onlyPlayable: false,
                    ),
                  ),
            icon: const Icon(Symbols.play_arrow, size: 20),
            label: const Text('播放全部'),
            style: actionStyle,
          ),
        ),
        if (_subscribed)
          FilledButton.tonalIcon(
            onPressed: null,
            icon: const Icon(Symbols.check, size: 20),
            label: const Text('已订阅'),
            style: actionStyle,
          )
        else
          FilledButton.tonalIcon(
            onPressed: _subscribing ? null : () => unawaited(_subscribe()),
            icon: const Icon(Symbols.add, size: 20),
            label: const Text('订阅'),
            style: actionStyle,
          ),
        FilledButton.tonalIcon(
          onPressed: () => unawaited(_load()),
          icon: const Icon(Symbols.refresh, size: 20),
          label: const Text('刷新'),
          style: actionStyle,
        ),
      ],
    );
  }
}
