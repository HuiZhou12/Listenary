import 'package:pure_music/lyric/lyric.dart';

enum MusicPlatform { netease, qq, kugou }

/// 平台的**展示名**（只用于界面文案）。
///
/// 身份、路由、持久化一律使用枚举本身（D1）：这里返回的中文名不参与任何映射，
/// 也不得被当作请求参数或落库内容。
String musicPlatformLabel(MusicPlatform platform) => switch (platform) {
  MusicPlatform.netease => '网易云',
  MusicPlatform.qq => 'QQ音乐',
  MusicPlatform.kugou => '酷狗音乐',
};

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

final class PlatformTrackRef {
  const PlatformTrackRef({required this.platform, required this.trackId});

  final MusicPlatform platform;
  final String trackId;

  @override
  bool operator ==(Object other) =>
      other is PlatformTrackRef &&
      other.platform == platform &&
      other.trackId == trackId;

  @override
  int get hashCode => Object.hash(platform, trackId);
}

final class MusicTrack {
  MusicTrack({
    required this.ref,
    required this.title,
    required Iterable<String> artists,
    this.album = '',
    this.coverUri,
    this.duration = Duration.zero,
    this.availability = TrackAvailability.unknown,
    this.searchOrdinal,
    Map<String, String> rawQualityHints = const {},
  }) : artists = List.unmodifiable(artists),
       rawQualityHints = Map.unmodifiable(rawQualityHints);

  final PlatformTrackRef ref;
  final String title;
  final List<String> artists;
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
    Iterable<MusicTrack> tracks = const [],
  }) : tracks = List.unmodifiable(tracks);

  final MusicPlatform platform;
  final String id;
  final String name;
  final Uri? coverUri;
  final String? creator;
  final int? trackCount;
  final List<MusicTrack> tracks;
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
    this.updateFrequency,
  });

  final MusicPlatform platform;
  final String id;
  final String name;
  final Uri? coverUri;
  final String? creator;
  final int? trackCount;

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
    this.count,
  });

  final MusicPlatform platform;
  final String id;
  final String name;

  /// 该分类下的歌单数量（平台给的时候才有）。
  final int? count;
}

final class MusicSearchPage {
  MusicSearchPage({
    required this.platform,
    required Iterable<MusicTrack> items,
    this.offset,
    this.limit,
    this.total,
    this.nextCursor,
  }) : items = List.unmodifiable(items);

  final MusicPlatform platform;
  final List<MusicTrack> items;
  final int? offset;
  final int? limit;
  final int? total;
  final String? nextCursor;
}
