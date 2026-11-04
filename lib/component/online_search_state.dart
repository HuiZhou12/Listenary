import 'package:pure_music/services/music_platform/index.dart';

/// 在线搜索的**纯类型与纯函数**（2026-11-03 从 `page/online_music_page.dart` 抽出）。
///
/// 为什么单独一个文件：搜索弹窗的「在线」分支要把这些类型与摊平顺序**当纯逻辑测**
/// （见 `test/component/online_search_state_test.dart`，不需要 pump 任何 widget）；
/// 面板只负责把它们渲染出来。
///
/// 分层：本文件在 `component/` ⇒ L3（表现层），只 import `services/`（L2）与纯模型 ⇒ 向下，合法。
/// 边界合规：本文件只经公开端口 `services/music_platform/index.dart` 取类型，
/// 不深引任何 Provider 层配置契约（`online_music_dependency_boundary_test.dart` 守着）。

/// 每页条数（各平台都用同一个页大小，但**各自维护自己的 offset**，D6c:a）。
const int onlineSearchPageSize = 30;

/// 单平台的搜索状态。
///
/// 多平台聚合下每个平台都有自己的一份：自己的累计结果、自己的分页游标、
/// 自己的错误（D6 / D6c:a）。一个平台失败不会动到另一个平台的状态。
///
/// 2.2（R4/G3）：分组的键是**平台身份**而不是枚举 —— 所有自定义平台共用
/// `MusicPlatform.custom`，用枚举当键会让它们互相覆盖、统一显示「自定义平台」。
final class OnlineSearchPlatformState {
  OnlineSearchPlatformState({required this.identity, required this.label});

  final PlatformIdentity identity;

  /// 该分组的展示名（内置平台中文名 / 自定义平台自己的 `platformName`）。
  final String label;

  MusicPlatform get platform => identity.platform;

  /// 分组/分页 key 里的稳定后缀（自定义平台要带稳定 ID，否则两个分组会撞 key）。
  String get keySuffix => identity.isCustom
      ? 'custom-${identity.platformId}'
      : identity.platform.name;

  /// 该平台**累计**的结果页（`items` 即"已加载的全部结果"）。
  ///
  /// 首请求且未合并过分页时，这里仍是服务返回的**同一个对象** —— 选中某一行时把它
  /// 交给播放链路的既有语义（含对象身份）因此保持不变。
  MusicSearchPage? page;

  /// 该平台整体失败时的错误（D6：单平台失败不影响其它平台）。
  OnlineMusicException? error;

  /// 该平台在途的"加载更多"取消令牌（按平台各自取消，不牵连其它平台）。
  OnlineMusicCancelToken? token;

  OnlineMusicException? loadMoreError;
  bool loadingMore = false;

  /// 该平台"加载更多"自身的代次：同一平台重复触发时丢弃过期响应，
  /// 但**不会**影响别的平台的在途分页。
  int loadMoreRevision = 0;

  /// 上一次分页（含首请求）**原始**返回条数，用于 `hasMore` 的第二重判定。
  int lastPageCount = 0;

  List<MusicTrack> get items => page?.items ?? const <MusicTrack>[];

  int get total => page?.total ?? 0;

  /// `hasMore` 双重判定：已加载数量 < total **且** 上一页原始返回条数 == limit。
  ///
  /// 只信 `total` 不可靠（部分第三方接口不裁剪、或 total 与实际条数不一致），
  /// 沿用 `lyric_source_view.dart:436,443` 的既有先例。
  bool get hasMore {
    if (page == null) return false;
    final loaded = items;
    if (loaded.isEmpty) return false;
    if (lastPageCount < onlineSearchPageSize) return false;
    return loaded.length < total;
  }
}

/// 结果列表的一行（表头 / 曲目 / 平台失败 / 该平台无结果 / 分页页脚）。
sealed class OnlineSearchEntry {
  const OnlineSearchEntry();
}

final class OnlineSearchGroupHeaderEntry extends OnlineSearchEntry {
  const OnlineSearchGroupHeaderEntry(this.group);

  final OnlineSearchPlatformState group;
}

final class OnlineSearchTrackEntry extends OnlineSearchEntry {
  const OnlineSearchTrackEntry(this.group, this.track);

  final OnlineSearchPlatformState group;
  final MusicTrack track;
}

final class OnlineSearchFailureEntry extends OnlineSearchEntry {
  const OnlineSearchFailureEntry(this.group);

  final OnlineSearchPlatformState group;
}

final class OnlineSearchEmptyGroupEntry extends OnlineSearchEntry {
  const OnlineSearchEmptyGroupEntry(this.group);

  final OnlineSearchPlatformState group;
}

/// **专辑结果行**（2026-10-12 ✓）：与曲目行**混在同一个列表**里 ✓，
/// 靠行首的「**专辑 · …**」类型前缀自报家门 ✓ —— 与参考产品"混合结果 + 类型前缀"的做法一致 ✓。
final class OnlineSearchAlbumEntry extends OnlineSearchEntry {
  const OnlineSearchAlbumEntry(this.album);

  final OnlineAlbumSummary album;
}

/// **艺人结果行**（2026-10-12 ✓）：与曲目/专辑行**混在同一个列表** ✓，
/// 以「**艺人 · …**」自报家门 ✓（参考的混合结果 + 类型前缀 ✓）。
final class OnlineSearchArtistEntry extends OnlineSearchEntry {
  const OnlineSearchArtistEntry(this.artist);

  final OnlineArtistSummary artist;
}

/// **艺人搜索失败的提示行**（只属于该平台 ✓，不静默 ✓）。
final class OnlineSearchArtistFailureEntry extends OnlineSearchEntry {
  const OnlineSearchArtistFailureEntry(this.group);

  final OnlineSearchPlatformState group;
}

/// **专辑搜索失败的提示行**（只属于该平台 ✓）：不静默 ✓ ——
/// 否则"没有专辑"与"专辑搜索失败"看起来一模一样 ✗。
final class OnlineSearchAlbumFailureEntry extends OnlineSearchEntry {
  const OnlineSearchAlbumFailureEntry(this.group);

  final OnlineSearchPlatformState group;
}

final class OnlineSearchFooterEntry extends OnlineSearchEntry {
  const OnlineSearchFooterEntry(this.group);

  final OnlineSearchPlatformState group;
}

/// 某个身份在**这一处并列显示**时的展示名（2.2 / R4 / G6）。
///
/// 基础文案统一走 `platformLabelForIdentityOnly`（自定义平台 ⇒ 条目自己的
/// `platformName`，缺失 ⇒「自定义平台」）。**同名**（基础文案相同）的自定义平台在
/// [universe] 里出现 **>1** 次时附**短 ID**，否则不加噪声 —— 与设置页同一条规则
/// （`online_music_settings.dart` 的 `_providerTitle` / `_platformCardLabel`），
/// 否则两个同名的自定义平台在筛选与分组里完全无法分辨。
String disambiguatedPlatformLabel(
  PlatformIdentity identity,
  Iterable<PlatformIdentity> universe,
) {
  final label = platformLabelForIdentityOnly(identity);
  final shortId = identity.shortId;
  if (shortId == null || !identity.isValid) return label;
  var sameName = 0;
  for (final other in universe) {
    final normalized = other.normalized;
    if (!normalized.isCustom || !normalized.isValid) continue;
    if (platformLabelForIdentityOnly(normalized) == label) sameName++;
  }
  return sameName > 1 ? '$label（$shortId）' : label;
}

/// 把各平台分组摊平成一维行列表（面板交给 `ListView.builder` 保持懒构建）。
///
/// 摊平顺序**固定**（逐字沿用原搜索页）：分组头 → 曲目 → 专辑 → 艺人 →
/// 三类失败行 → 加载更多页脚。（失败行与空组行是**互斥**的两条分支：
/// 某平台整体失败时不再摆它的曲目/专辑/艺人行。）
///
/// [showHeaders]：多平台聚合才摆分组表头（单平台不摆，沿用单平台观感）。
List<OnlineSearchEntry> flattenOnlineSearchEntries({
  required List<OnlineSearchPlatformState> groups,
  required Map<PlatformIdentity, List<OnlineAlbumSummary>> albums,
  required Set<PlatformIdentity> albumsFailed,
  required Map<PlatformIdentity, List<OnlineArtistSummary>> artists,
  required Set<PlatformIdentity> artistsFailed,
  bool showHeaders = false,
}) {
  final entries = <OnlineSearchEntry>[];
  for (final group in groups) {
    if (showHeaders) entries.add(OnlineSearchGroupHeaderEntry(group));
    if (group.error != null) {
      entries.add(OnlineSearchFailureEntry(group));
      continue;
    }
    if (group.items.isEmpty) {
      entries.add(OnlineSearchEmptyGroupEntry(group));
      continue;
    }
    for (final track in group.items) {
      entries.add(OnlineSearchTrackEntry(group, track));
    }
    // **专辑结果与曲目混排** ✓（同一平台内：曲目之后接专辑 ✓）——
    // 每行以「专辑 · …」自报家门 ✓，与参考"混合结果 + 类型前缀"一致 ✓。
    final groupAlbums = albums[group.identity];
    if (groupAlbums != null) {
      for (final album in groupAlbums) {
        entries.add(OnlineSearchAlbumEntry(album));
      }
    }
    if (albumsFailed.contains(group.identity)) {
      entries.add(OnlineSearchAlbumFailureEntry(group));
    }
    // **艺人结果同样混排** ✓（曲目 → 专辑 → 艺人 ✓；每行自报类型 ✓）。
    final groupArtists = artists[group.identity];
    if (groupArtists != null) {
      for (final artist in groupArtists) {
        entries.add(OnlineSearchArtistEntry(artist));
      }
    }
    if (artistsFailed.contains(group.identity)) {
      entries.add(OnlineSearchArtistFailureEntry(group));
    }
    entries.add(OnlineSearchFooterEntry(group));
  }
  return entries;
}
