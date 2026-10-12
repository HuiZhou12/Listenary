import 'dart:math';

import 'package:pure_music/lyric/lyric.dart';

enum MusicPlatform {
  netease,
  qq,
  kugou,

  /// 自定义平台种类（P-39 / 用户 P0 裁定）：真实身份 = `custom` + **稳定 `platformId`**。
  ///
  /// - 内置平台身份 = 平台类型本身，稳定 ID 为空；
  /// - 自定义平台身份 = `custom` + 稳定 ID（标准 UUID v4，小写带连字符，创建后不变）；
  /// - **未取得有效稳定 ID** 的自定义配置**不得参与网络路由**（fail-closed）；
  /// - 历史数据里认不出的平台值归到这里，**绝不回落网易云**，且原样保留原始标识。
  custom,
}

/// 平台的**展示名**（只用于界面文案）。
///
/// 身份、路由、持久化一律使用枚举本身（D1）：这里返回的中文名不参与任何映射，
/// 也不得被当作请求参数或落库内容。
String musicPlatformLabel(MusicPlatform platform) => switch (platform) {
  MusicPlatform.netease => '网易云',
  MusicPlatform.qq => 'QQ音乐',
  MusicPlatform.kugou => '酷狗音乐',
  // 自定义平台的展示名由条目自己的 `platformName` 提供；这里只是兜底文案，
  // **不参与身份判定**（P0 裁定：不得用展示名推断身份）。
  MusicPlatform.custom => '自定义平台',
};

/// **内置平台**列表（不含"自定义平台"这一种类）。
///
/// 自定义平台**不是**"可启用的内置平台"：它由条目通过稳定 `platformId` 声明。
/// 凡是枚举"内置平台"的地方（平台卡、来源选择、能力视图、聚合分组、默认启用集合、
/// 诊断文案）都应使用本列表 —— 否则会出现"可点但没有实现"的平台项。
///
/// 注意：**身份/持久化解析**不要用本列表（那里必须能处理自定义平台值），见 `PlatformIdentity`。
List<MusicPlatform> get builtinMusicPlatforms => MusicPlatform.values
    .where((platform) => platform != MusicPlatform.custom)
    .toList(growable: false);

/// F5-P-39（P3）：平台**展示名**的统一出口（界面只用它，不要各自拼文案）。
///
/// 规则（P0）：
/// - 内置平台 ⇒ [musicPlatformLabel]（既有文案不变）；
/// - 自定义平台 ⇒ 条目配置的 `platformName`（缺失时回落「自定义平台」）；
/// - **身份无效 / 未知名** ⇒ 「未知平台」（**绝不回落到网易云**，也不用名称/URL 反推平台）。
String platformDisplayLabel(
  PlatformIdentity identity, {
  String? platformName,
}) {
  // ⚠️ 顺序很重要：**条目声明的展示名优先**（F4-S5 语义 —— 内置平台也可以自定义展示名，
  // 例如"自建网易云代理"）。展示名不参与身份判定（P0），只是文案。
  final declared = platformName?.trim();
  if (declared != null && declared.isNotEmpty) return declared;
  if (!identity.isCustom) return musicPlatformLabel(identity.platform);
  return identity.isValid ? '自定义平台' : '未知平台';
}

enum TrackAvailability { playable, paid, unavailable, unknown }

/// 在线歌曲音质档位；`level` 为网易云解析接口的请求参数，`label` 为展示文案。
enum MusicQuality {
  standard('standard', '标准'),
  exhigh('exhigh', '高品'),
  lossless('lossless', '无损'),
  hires('hires', 'Hi-Res'),
  jymaster('jymaster', '母带'),
  sky('sky', '沉浸声'),
  jyeffect('jyeffect', '全景声');

  const MusicQuality(this.level, this.label);

  final String level;
  final String label;
}

/// **统一的平台身份**（P-39 / 用户 P0 裁定）。
///
/// 为什么不能只用 [MusicPlatform]：所有自定义平台都共享 `MusicPlatform.custom`
/// ⇒ 拿枚举当唯一键时，两个不同的自定义平台会互相覆盖、串台。
final class PlatformIdentity {
  /// 内置平台身份（稳定 ID 必须为空）。
  const PlatformIdentity.builtin(this.platform) : platformId = null;

  /// 自定义平台身份：必须有**有效**稳定 ID 才可用于路由。
  const PlatformIdentity.custom(String this.platformId)
    : platform = MusicPlatform.custom;

  /// 通用构造（兼容既有调用：内置平台不传 [platformId]）。
  const PlatformIdentity(this.platform, {this.platformId});

  /// **新建**一个自定义平台身份（P0 规则③：生成标准 UUID v4 作稳定 ID）。
  ///
  /// ⚠️ 只用于"用户新建自定义平台"这一条路径；读取既有配置时一律走 [tryParse]，
  /// **不得**用它重新生成 ID（那会改掉已有平台的身份）。
  factory PlatformIdentity.newCustom([Random? random]) =>
      PlatformIdentity.custom(generateCustomPlatformId(random));

  /// 从**持久化 / 配置里的平台值**解析（P0 裁定的读回规则）：
  ///
  /// - 已知内置平台名 ⇒ 对应内置身份（按原规则读取）；
  /// - 其他非空值 ⇒ `custom` + **该值作为稳定 ID**（原样保留，不猜测、不改写）；
  /// - `custom` 一词本身、或空值 ⇒ `null`（没有稳定 ID ⇒ 身份无效 ⇒ 调用方 fail-closed）。
  static PlatformIdentity? tryParse(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    for (final platform in builtinMusicPlatforms) {
      if (platform.name == trimmed) return PlatformIdentity.builtin(platform);
    }
    if (trimmed == MusicPlatform.custom.name) return null;
    return PlatformIdentity.custom(trimmed);
  }

  final MusicPlatform platform;

  /// 稳定平台 ID：内置平台恒为 `null`；`custom` 必须非空才构成有效身份。
  final String? platformId;

  bool get isCustom => platform == MusicPlatform.custom;

  /// 身份是否**可用于网络路由**（也决定"能否安全落库"）。
  bool get isValid => !isCustom || (platformId?.trim().isNotEmpty ?? false);

  /// 持久化 / 日志里的**平台值**：内置 = 枚举名；自定义 = 稳定 ID。
  /// （复用既有 `platform TEXT` 列 —— 无需迁移即可容纳自定义身份。）
  String get storageValue => isCustom ? (platformId ?? '') : platform.name;

  /// 仅用于诊断展示；**不参与身份比较**。
  String get debugLabel => isCustom ? 'custom:${platformId ?? ''}' : platform.name;

  @override
  bool operator ==(Object other) =>
      other is PlatformIdentity &&
      other.platform == platform &&
      other.platformId == platformId;

  @override
  int get hashCode => Object.hash(platform, platformId);

  @override
  String toString() => 'PlatformIdentity($debugLabel)';
}

final class PlatformTrackRef {
  const PlatformTrackRef({
    required this.platform,
    required this.trackId,
    this.platformId,
  });

  /// 以**平台身份**构造（新代码推荐路径）。
  PlatformTrackRef.of(PlatformIdentity identity, this.trackId)
    : platform = identity.platform,
      platformId = identity.platformId;

  final MusicPlatform platform;
  final String trackId;

  /// 稳定平台 ID（P-39）：内置平台为空；`custom` 必须非空才是有效身份。
  final String? platformId;

  /// 统一身份：**曲目身份的键是 `(identity, trackId)`**（P0 裁定第 5 条）。
  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);

  /// 该引用是否可用于播放路由（自定义平台缺稳定 ID ⇒ 不可用）。
  bool get hasValidIdentity => identity.isValid;

  @override
  bool operator ==(Object other) =>
      other is PlatformTrackRef &&
      other.platform == platform &&
      other.platformId == platformId &&
      other.trackId == trackId;

  @override
  int get hashCode => Object.hash(platform, platformId, trackId);
}

final class MusicTrack {
  MusicTrack({
    required this.ref,
    required this.title,
    required Iterable<String> artists,
    Iterable<String> artistIds = const [],
    Iterable<String> albumIds = const [],
    this.album = '',
    this.coverUri,
    this.duration = Duration.zero,
    this.availability = TrackAvailability.unknown,
    this.searchOrdinal,
    Map<String, String> rawQualityHints = const {},
  }) : artists = List.unmodifiable(artists),
       artistIds = List.unmodifiable(artistIds),
       albumIds = List.unmodifiable(albumIds),
       rawQualityHints = Map.unmodifiable(rawQualityHints);

  final PlatformTrackRef ref;
  final String title;
  final List<String> artists;

  /// **艺人 id**（与 [artists] **同序**，2026-10-12 新增）：曲目行里的艺人名可以据此打开艺人页 ✓。
  ///
  /// 真实服务通常把两者放在同一个数组里（网易云 `ar[*].name` 与 `ar[*].id`），
  /// 所以映射时取两条**同序**路径；某一平台缺 id 时这里为空 ⇒ 界面**不显示可点**（不猜 ✓）。
  final List<String> artistIds;

  /// **专辑 id**（2026-10-12 新增）：曲目行里的专辑名可以据此打开专辑页 ✓。
  final List<String> albumIds;
  final String album;
  final Uri? coverUri;
  final Duration duration;
  final TrackAvailability availability;
  final int? searchOrdinal;
  final Map<String, String> rawQualityHints;

  String get artistDisplay => artists.join('、');
}

final class ResolvedStream {
  const ResolvedStream({
    required this.ref,
    required this.uri,
    required this.requestedQuality,
    this.coverUri,
    this.actualQuality,
    this.bitrate,
    this.format,
    required this.resolvedAt,
    this.expiresAt,
    this.servedByProviderId,
  });

  final PlatformTrackRef ref;
  final Uri uri;
  final String requestedQuality;
  final Uri? coverUri;
  final String? actualQuality;
  final int? bitrate;
  final String? format;
  final DateTime resolvedAt;
  final DateTime? expiresAt;

  /// 实际解析出这个播放地址的 Provider id。
  ///
  /// **仅用于诊断与调试**（D5b:B：回退静默但可观测），**不参与内容身份、不落库**
  /// （D1：Provider 不是内容事实）。
  final String? servedByProviderId;

  ResolvedStream withServedByProvider(String providerId) => ResolvedStream(
    ref: ref,
    uri: uri,
    requestedQuality: requestedQuality,
    coverUri: coverUri,
    actualQuality: actualQuality,
    bitrate: bitrate,
    format: format,
    resolvedAt: resolvedAt,
    expiresAt: expiresAt,
    servedByProviderId: providerId,
  );

  bool isExpiredAt(DateTime time) =>
      expiresAt != null && !time.isBefore(expiresAt!);
}

final class MusicLyrics {
  const MusicLyrics({
    this.original,
    this.translation,
    this.romanization,
    this.parsed,
    this.ref,
  });

  final String? original;
  final String? translation;
  final String? romanization;
  final Lyric? parsed;

  /// 这份歌词**属于哪条在线曲目**（platform + remoteId）。
  ///
  /// 由服务层在成功取词后按请求回填（D9 / 不变量 I1）：在线歌词必须始终能回答
  /// "它来自哪个平台的哪首歌"，不允许出现来源不明的歌词对象。
  final PlatformTrackRef? ref;

  MusicLyrics withRef(PlatformTrackRef ref) => MusicLyrics(
    original: original,
    translation: translation,
    romanization: romanization,
    parsed: parsed,
    ref: ref,
  );

  bool get isEmpty =>
      (original == null || original!.isEmpty) &&
      (translation == null || translation!.isEmpty) &&
      (romanization == null || romanization!.isEmpty) &&
      (parsed == null || parsed!.isEmpty);
}

final class RemotePlaylist {
  RemotePlaylist({
    required this.platform,
    required this.id,
    required this.name,
    this.coverUri,
    this.creator,
    this.trackCount,
    this.platformId,
    Iterable<MusicTrack> tracks = const [],
  }) : tracks = List.unmodifiable(tracks);

  final MusicPlatform platform;
  final String id;
  final String name;
  final Uri? coverUri;
  final String? creator;
  final int? trackCount;
  final List<MusicTrack> tracks;

  /// F5-P-39（P3）：稳定平台 ID（自定义平台用；内置为 null ⇒ identity = builtin）。
  /// 由产出方（provider 映射器）透传；缺省 null 时身份等价于内置平台（兼容旧构造点）。
  final String? platformId;

  /// F5-P-39（P3）：统一平台身份（与曲目/歌单/歌词共用同一类型）。
  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);
}

/// 一个**在线艺人**（`artist` 能力，2026-10-12 新增）：标量信息 + **热门曲目**。
///
/// 形状与 [RemotePlaylist] 同构（"元数据 + 曲目列表"），因为真实服务就是这样：
/// 网易云实测 `/artists?id=` 一次返回艺人信息与 `hotSongs`。
final class OnlineArtist {
  OnlineArtist({
    required this.platform,
    required this.id,
    required this.name,
    this.avatarUri,
    this.description,
    this.platformId,
    Iterable<MusicTrack> hotSongs = const [],
  }) : hotSongs = List.unmodifiable(hotSongs);

  final MusicPlatform platform;

  /// 平台自己的艺人标识（**来自请求输入**，不是响应字段 ✓）。
  final String id;
  final String name;
  final Uri? avatarUri;
  final String? description;
  final List<MusicTrack> hotSongs;

  /// 自定义平台的稳定 ID（内置平台为 null ⇒ identity = builtin）。
  final String? platformId;

  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);
}

/// **艺人列表里的一项**（`searchArtists` 能力，2026-10-12 新增）：只有元数据 ✓。
///
/// 与 [OnlineArtist]（艺人详情，**带热门曲目**）刻意分开：搜索结果里本来就没有热门曲目 ✓
/// ⇒ 不为"统一"塞空列表 ✓（同 [OnlineAlbumSummary] 与 [OnlineAlbum] 的关系 ✓）。
final class OnlineArtistSummary {
  OnlineArtistSummary({
    required this.platform,
    required this.id,
    required this.name,
    this.avatarUri,
    this.platformId,
  });

  final MusicPlatform platform;

  /// 平台自己的艺人标识。
  final String id;
  final String name;
  final Uri? avatarUri;

  /// 自定义平台的稳定 ID（内置平台为 null ⇒ identity = builtin）。
  final String? platformId;

  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);
}

/// **专辑列表里的一项**（`artistAlbums` 能力，2026-10-12 新增）：只有元数据，**没有曲目** ✓。
///
/// 与 [OnlineAlbum]（专辑详情，**带曲目**）刻意分开：列表项本来就没有曲目，
/// 真实服务（网易云 `/artist/album`）也只给元数据 ✓ ⇒ 不为了"统一"而塞空列表 ✓。
final class OnlineAlbumSummary {
  OnlineAlbumSummary({
    required this.platform,
    required this.id,
    required this.name,
    this.coverUri,
    this.trackCount,
    this.releaseTime,
    this.platformId,
  });

  final MusicPlatform platform;

  /// 平台自己的专辑标识。
  final String id;
  final String name;
  final Uri? coverUri;

  /// 平台声明的曲目数（`size`）。
  final int? trackCount;

  /// 发行时间（**UTC**；平台给的是**毫秒**时间戳 ✓）。
  final DateTime? releaseTime;

  /// 自定义平台的稳定 ID（内置平台为 null ⇒ identity = builtin）。
  final String? platformId;

  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);
}

/// 一张**在线专辑**（`album` 能力，2026-10-12 新增）：标量信息 + **曲目**。
///
/// 形状与 [RemotePlaylist]/[OnlineArtist] 同构（"元数据 + 曲目列表"），因为真实服务就是这样：
/// 网易云实测 `/album?id=` 返回 `{code, album, songs}` —— 元数据在 `album`、曲目在顶层 `songs` ✓。
final class OnlineAlbum {
  OnlineAlbum({
    required this.platform,
    required this.id,
    required this.name,
    this.coverUri,
    this.artist,
    this.artistId,
    this.trackCount,
    this.releaseTime,
    this.platformId,
    Iterable<MusicTrack> tracks = const [],
  }) : tracks = List.unmodifiable(tracks);

  final MusicPlatform platform;

  /// 平台自己的专辑标识（**来自请求输入**，不是响应字段 ✓）。
  final String id;
  final String name;
  final Uri? coverUri;

  /// 专辑艺人（平台自己的文案；可为空 ✓）。
  final String? artist;

  /// **专辑艺人 id**（2026-10-12）：参考产品的专辑页把艺人名做成**链接** ✓
  /// ⇒ 有 id 时我们也让那行可点（没 id 就是纯文本 ✓，不假装可点 ✓）。
  final String? artistId;

  /// 平台声明的曲目数（`size`）；**与 [tracks] 的实际条数不必相等** ✓。
  final int? trackCount;

  /// 发行时间（**UTC**；平台给的是**毫秒**时间戳，由映射层换算 ✓）。
  ///
  /// ⚠️ 只有**年份**是可靠展示粒度：跨年边界按 UTC 判定，可能与"当地发行日"差一天 ✓
  /// ⇒ 界面只显示年份、不显示具体日期 ✓（不把不确定的东西说得很确定 ✓）。
  final DateTime? releaseTime;
  final List<MusicTrack> tracks;

  /// 自定义平台的稳定 ID（内置平台为 null ⇒ identity = builtin）。
  final String? platformId;

  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);
}

/// 一个**歌单摘要**（歌单集合里的一项）：只有元数据，**没有曲目**。
///
/// 与 [RemotePlaylist]（歌单详情 + `tracks`）是两个业务语义：
/// 「浏览有哪些歌单」与「打开某个歌单看它的曲目」是两条独立的请求链路，
/// 因此是两个能力（`playlistCollection` / `playlist`），不是同一个能力的两个形态。
/// 这也与 D12 不冲突：D12 说的是"歌单详情与其曲目列表不拆"。
///
/// 来源身份照旧：`(platform, id)`（I1）。
final class RemotePlaylistSummary {
  const RemotePlaylistSummary({
    required this.platform,
    required this.id,
    required this.name,
    this.coverUri,
    this.creator,
    this.trackCount,
    this.platformId,
    this.updateFrequency,
  });

  final MusicPlatform platform;
  final String id;
  final String name;
  final Uri? coverUri;
  final String? creator;
  final int? trackCount;

  /// F5-P-39（P3）：稳定平台 ID（自定义平台用；内置为 null ⇒ identity = builtin）。
  /// 由产出方（provider 映射器）透传；缺省 null 时身份等价于内置平台（兼容旧构造点）。
  final String? platformId;

  /// F5-P-39（P3）：统一平台身份（与曲目/歌单/歌词共用同一类型）。
  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);

  /// 该集合的**更新节奏**（平台自己的文案，例如"每天更新"）；null 表示平台没有给。
  ///
  /// 用途：榜单这类"给人看的名次集合"必须能说明它多久变一次。它是纯展示元信息，
  /// **不参与身份、不落库**（摘要本身只存在于内存里）。
  final String? updateFrequency;
}

/// 一个**分类**（歌单分类 / 曲风 / 场景）：用于"按分类浏览歌单"。
///
/// 来源身份照旧：`(platform, id)`（I1）。注意 `id` 是**给该平台自己用的取值** ——
/// 网易云实测分类是以**名字**作为请求值（`/top/playlist?cat=华语`），因此那里
/// `id == name`。界面不要假设它是数字。
final class RemotePlaylistCategory {
  const RemotePlaylistCategory({
    required this.platform,
    required this.id,
    required this.name,
    this.platformId,
    this.count,
  });

  final MusicPlatform platform;
  final String id;
  final String name;

  /// F5-P-39（P3）：稳定平台 ID（自定义平台用；内置为 null ⇒ identity = builtin）。
  /// 由产出方（provider 映射器）透传；缺省 null 时身份等价于内置平台（兼容旧构造点）。
  final String? platformId;

  /// F5-P-39（P3）：统一平台身份（与曲目/歌单/歌词共用同一类型）。
  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);

  /// 该分类下的歌单数量（平台给的时候才有）。
  final int? count;
}

final class MusicSearchPage {
  MusicSearchPage({
    required this.platform,
    this.platformId,
    required Iterable<MusicTrack> items,
    this.offset,
    this.limit,
    this.total,
    this.nextCursor,
  }) : items = List.unmodifiable(items);

  final MusicPlatform platform;

  /// F5-P-39（P3）：稳定平台 ID（自定义平台用；内置为 null ⇒ identity = builtin）。
  /// 由产出方（provider 映射器）透传；缺省 null 时身份等价于内置平台（兼容旧构造点）。
  final String? platformId;

  /// F5-P-39（P3）：统一平台身份（与曲目/歌单/歌词共用同一类型）。
  PlatformIdentity get identity =>
      PlatformIdentity(platform, platformId: platformId);
  final List<MusicTrack> items;
  final int? offset;
  final int? limit;
  final int? total;
  final String? nextCursor;
}


/// 生成标准 **UUID v4**（小写带连字符）——P0 规则③：**新建**自定义平台时用它作稳定 ID。
///
/// ⚠️ 只用于新建：已有配置里的非空 `platformId` 必须**兼容读取、不得重写**（规则④）；
/// 也不得在每次加载时随机生成（那会让身份不稳定）。
///
/// [random] 仅用于测试注入（默认 `Random.secure()`）。
String generateCustomPlatformId([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version = 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant = 10xx
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}