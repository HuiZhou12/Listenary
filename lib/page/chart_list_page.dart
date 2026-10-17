import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/component/remote_media_card.dart';
import 'package:pure_music/component/remote_playlist_launcher.dart';
import 'package:pure_music/component/remote_media_grid.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

/// **榜单全量页**：把探索页榜单货架上的「查看全部」落成一个网格。
///
/// 为什么需要它：真实平台的榜单可以很多（网易云 `/toplist` 实测 **63 个**），
/// 横向货架只适合做预览；全量列表必须是可换行的网格。
///
/// 只列出 [OnlineMusicCapabilities.openableChartPlatforms] —— 即"既能列榜、
/// 又能取到歌单详情"的平台。**缺歌单详情能力的平台会被排除**，否则用户点进去
/// 只会看到一次失败（实测 QQ 的榜单 id 不能当歌单用）。
class ChartListPage extends StatefulWidget {
  const ChartListPage({super.key, this.requestLimit = 200});

  /// 一次向平台要多少条榜单。
  ///
  /// 这是**"查看全部"的落地页**，因此不该用"预览条数"去要数据：网易云 `/toplist`
  /// 实测**不接受任何分页参数**、一次返回全部 63 个；而若某个平台真的认 `limit`，
  /// 传一个预览尺寸就会把其余榜单**静默藏掉**。取一个宽松上限（与分类索引同一个量级）。
  ///
  /// **不给分页**：`/toplist` 忽略 `offset`，翻页只会取回同一批 ⇒ 按"不可分页不给假分页"的
  /// 规则只做一次性加载，并如实显示实际取到的条数。
  final int requestLimit;

  @override
  State<ChartListPage> createState() => _ChartListPageState();
}

class _ChartListPageState extends State<ChartListPage>
    with RemoteListLoading<ChartListPage> {
  bool _loaded = false;
  List<MusicPlatform> _platforms = const [];
  final Set<MusicPlatform> _subscribing = {};

  /// 榜单按平台各自加载（单平台失败不影响其它平台）。
  final RemoteLoadState<MusicPlatform, RemotePlaylistSummary> remote =
      RemoteLoadState<MusicPlatform, RemotePlaylistSummary>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    // 刷新时先清掉旧错误：重试前不该继续挂着上一次的失败提示。
    if (_loaded) setState(remote.clearErrors);
    _loaded = true;
    final service = context.read<OnlineMusicService?>();
    final platforms = service == null
        ? const <MusicPlatform>[]
        : [
            for (final platform in builtinMusicPlatforms)
              if (service.capabilities.openableChartPlatforms.contains(platform))
                platform,
          ];
    if (!mounted) return;
    setState(() => _platforms = platforms);
    if (service == null) return;
    await Future.wait([
      for (final platform in platforms) _loadPlatform(service, platform),
    ]);
  }

  Future<void> _loadPlatform(
    OnlineMusicService service,
    MusicPlatform platform,
  ) => loadRemoteList(
    remote,
    platform,
    () => service.fetchChartList(
      platform: platform,
      limit: widget.requestLimit,
      offset: 0,
      cancelToken: newCancelToken(),
    ),
    fallback: '读取该平台榜单失败',
  );

  /// **点封面 = 打开只读预览**（不订阅 ✓）。
  ///
  /// 与探索页、平台歌单列表页同一条规则：榜单在榜单型平台上就是歌单，因此预览直接取
  /// 远端歌单详情、**一个字节都不写库**（见 `remote_playlist_page.dart`）。
  /// 订阅只由卡片下方的「订阅」按钮触发 —— 此前这一页点封面会**直接入库并跳详情**，
  /// 与探索页"点封面只预览"的做法相反，同一个动作在两个页面给出不同结论。
  ///
  /// 跳转本身走共享入口 ✓（2026-10-17 / F2 收口）：本页每一项都是**名次集合**（榜单）
  /// ⇒ `ranked: true` ⇒ 预览页据此显示行首序号 ✓。
  Future<void> _preview(RemotePlaylistSummary summary) =>
      openRemotePlaylistSummaryPreview(context, summary, ranked: true);

  /// **订阅入库**（**不跳转** ✓）：只把这份榜单放进媒体库。
  ///
  /// 与探索页同一条规则：订阅后**留在原地**；想细看就点封面走预览。
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
        controller.snapshot.errorMessage ?? '订阅该榜单失败',
        variant: ToastVariant.error,
      );
      return;
    }
    // 本页每一项都是**名次集合**（榜单）⇒ 记下"这是榜单订阅"，详情页据此显示行首序号。
    // 记在偏好里（新增键值，**不动 DB schema** ✓）。
    // 落盘用 `.ignore()` **火焰式**：内存里已经标记；落盘失败只影响"重启后是否还显示序号"，
    // **不能**因为落盘失败就打断"订阅成功"这个主流程（曾因此让一条测试变红）。
    AppPreference.instance.markRankedSubscription(saved.localId);
    AppPreference.instance.save().ignore();
    showTextOnSnackBar(
      '已订阅「${saved.playlist.name}」，可在媒体库查看',
      variant: ToastVariant.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: '榜单',
      subtitle: '各平台榜单；每个平台分开显示',
      actions: [
        IconButton.filledTonal(
          tooltip: '刷新',
          onPressed: _reload,
          icon: const Icon(Symbols.refresh),
        ),
      ],
      body: _loaded && _platforms.isEmpty
          ? const QuietEmptyState(
              icon: Symbols.leaderboard,
              title: '暂无可打开的榜单',
              message:
                  '榜单需要平台同时提供「榜单」与「歌单详情」能力：'
                  '只列榜、取不到曲目的平台会被排除，以免点进去只看到失败。',
            )
          : ListView(
              padding: const EdgeInsets.only(
                bottom: Spacing.bottomNav,
                right: 20,
              ),
              children: [
                for (final platform in _platforms)
                  _buildPlatformGrid(platform),
              ],
            ),
    );
  }

  Widget _buildPlatformGrid(MusicPlatform platform) {
    final items = remote.items(platform);
    return ContentSection(
      title: musicPlatformLabel(platform),
      subtitle: items.isEmpty ? null : '${items.length} 个榜单',
      child: switch ((remote.isLoading(platform), remote.error(platform))) {
        (true, _) => const SizedBox(
          height: 96,
          child: Center(
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        (_, final String message) => InlineFailureHint(
          message: message,
          onRetry: () => _retry(platform),
        ),
        _ when items.isEmpty => const InlineEmptyHint(
          icon: Symbols.leaderboard,
          message: '该平台今天没有榜单',
        ),
        _ => RemoteMediaGrid(
          itemCount: items.length,
          itemBuilder: (context, index, cardWidth) {
            final summary = items[index];
            final busy = _subscribing.contains(platform);
            return RemoteMediaCard(
              width: cardWidth,
              title: summary.name,
              coverUri: summary.coverUri,
              details: _detailsOf(summary),
              sourceLabel: platformLabelForIdentityOnly(summary.identity),
              placeholderIcon: Symbols.leaderboard,
              // **点封面 = 打开只读预览**（与探索页同一条规则 ✓）：此前是"点一下就订阅并
              // 跳进详情" ✗ —— 同一个动作在两个页面结论不同。
              onTap: () => _preview(summary),
              semanticLabel:
                  '${summary.name}，来自${platformLabelForIdentityOnly(summary.identity)}，点击预览（不会订阅）',
              onSubscribe: () => _subscribe(summary),
              subscribeEnabled: !busy,
            );
          },
        ),
      },
    );
  }

  /// 榜单卡片：元信息行统一为「**类型 · …**」，本页全是榜单 ⇒ 类型固定为「榜单」。
  String _detailsOf(RemotePlaylistSummary summary) {
    final frequency = summary.updateFrequency?.trim();
    return [
      '榜单',
      if (frequency != null && frequency.isNotEmpty) frequency,
      if (summary.trackCount != null) '${summary.trackCount} 首',
    ].join(' · ');
  }

  Future<void> _retry(MusicPlatform platform) async {
    final service = context.read<OnlineMusicService?>();
    if (service == null) return;
    await _loadPlatform(service, platform);
  }
}
