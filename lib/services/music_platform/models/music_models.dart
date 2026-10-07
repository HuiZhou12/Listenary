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
