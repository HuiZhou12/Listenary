import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

/// **远程歌单预览页**（2026-10-12 新增 ✓）。
///
/// 为什么要有它：此前"看歌单"必须**先订阅** ✗ —— 因为详情页只读本地库
/// （`OnlinePlaylistDetailPage({required localId})` ✗）。用户点封面于是要么被
/// **偷偷订阅**（榜单卡片 ✗），要么**毫无反应**（平台歌单卡片 ✗），两条都不对 ✓。
///
/// 现在的规则（用户确认的直觉 ✓）：
/// - **点封面 = 打开本页预览** ✓ —— **只读**，一个字节都不写库 ✗（`fetchPlaylist` 直接用 ✓）；
/// - 页内「**订阅**」= 只入库 ✓，**不跳转** ✗（订阅完还留在这一页 ✓，按钮变成"已订阅"✓）；
/// - 想看自己订阅的那份（可同步、带收藏态）⇒ 从媒体库进订阅详情页 ✓。
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
      if (mounted) setState(() => _detail = detail);
      return detail.tracks;
    },
    fallback: '读取该歌单失败',
  );

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

  Future<void> _play(Iterable<MusicTrack> tracks, MusicTrack track) =>
      playOnlineTrackSelection(
        context,
        OnlineTrackSelection.fromResultPage(
          tracks: tracks,
          selectedRef: track.ref,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tracks = _tracks.items(_key);
    final detail = _detail;
    final creator = detail?.creator ?? widget.creator;
    final count = detail?.trackCount ?? widget.trackCount;
    final details = [
      '歌单',
      if (creator != null && creator.isNotEmpty) creator,
      if (count != null) '$count 首',
    ].join(' · ');

    return PageScaffold(
      title: detail?.name ?? widget.name,
      subtitle: '${musicPlatformLabel(widget.platform)} · 预览（未订阅，不会写进媒体库）',
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () => unawaited(_load()),
          icon: const Icon(Symbols.refresh),
        ),
        if (_subscribed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: Center(
              child: Text(
                '已订阅',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: FilledButton.tonalIcon(
              onPressed: _subscribing ? null : () => unawaited(_subscribe()),
              icon: const Icon(Symbols.add, size: 18),
              label: const Text('订阅'),
            ),
          ),
      ],
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav, right: 20),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: AppRadius.mdCircular,
                child: SizedBox.square(
                  dimension: 140,
                  child: RemoteMediaCover(
                    coverUri: detail?.coverUri ?? widget.coverUri,
                    placeholder: ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(
                        Symbols.queue_music,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    cacheWidth: 280,
                    cacheHeight: 280,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail?.name ?? widget.name,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: AppType.hero,
                        fontWeight: AppType.weightBold,
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      details,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: Spacing.md),
                    if (tracks.isNotEmpty)
                      FilledButton.icon(
                        onPressed: () => _play(tracks, tracks.first),
                        icon: const Icon(Symbols.play_arrow),
                        label: const Text('播放全部'),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          if (_tracks.isLoading(_key) && tracks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Spacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_tracks.error(_key) case final message? when tracks.isEmpty)
            InlineFailureHint(
              message: message,
              onRetry: () => unawaited(_load()),
            )
          else if (tracks.isEmpty)
            const InlineEmptyHint(
              icon: Symbols.music_off,
              message: '这个歌单没有可播放的曲目。',
            )
          else
            for (var index = 0; index < tracks.length; index++)
              OnlineTrackEntry(
                track: tracks[index],
                onTap: () => _play(tracks, tracks[index]),
                // 只有**名次集合**（榜单）才给序号 ✓ —— 普通歌单给了就是编排名 ✗。
                leadingIndex: widget.ranked ? index + 1 : null,
              ),
        ],
      ),
    );
  }
}
