import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:sqlite3/sqlite3.dart';

const defaultOnlineHistoryLimit = 1000;

final class OnlineHistoryEntry {
  const OnlineHistoryEntry({
    required this.track,
    required this.playCount,
    required this.lastPlayedAt,
    this.lastQuality,
  });

  final MusicTrack track;
  final int playCount;
  final DateTime lastPlayedAt;
  final String? lastQuality;
}

final class OnlineHistoryLibrarySnapshot {
  const OnlineHistoryLibrarySnapshot({
    required this.recent,
    required this.topPlayed,
    required this.totalPlayCount,
  });

  final List<OnlineHistoryEntry> recent;
  final List<OnlineHistoryEntry> topPlayed;
  final int totalPlayCount;

  int get trackCount => recent.length;
}

final class OnlineLibraryRepository {
  OnlineLibraryRepository(this._db);

  final Database _db;

  void upsertTrack(
    MusicTrack track, {
    String? lastQuality,
    DateTime? updatedAt,
  }) {
    _transaction(() {
      _upsertTrack(
        track,
        lastQuality: lastQuality,
        updatedAt: updatedAt ?? DateTime.now().toUtc(),
      );
    });
  }

  MusicTrack? findTrack(PlatformTrackRef ref) {
    final rows = _db.select(
      'SELECT platform, track_id, title, album, cover_uri, duration_ms, '
      'availability FROM online_tracks WHERE platform = ? AND track_id = ?',
      [_platformValue(ref.platform), _requiredTrackId(ref.trackId)],
    );
    if (rows.isEmpty) return null;
    return _readTrack(rows.single);
  }

  void recordPlaybackStarted(
    MusicTrack track, {
    String? lastQuality,
    DateTime? playedAt,
    int historyLimit = defaultOnlineHistoryLimit,
  }) {
    if (historyLimit <= 0) {
      throw ArgumentError.value(historyLimit, 'historyLimit');
    }
    final timestamp = (playedAt ?? DateTime.now()).toUtc();
    _transaction(() {
      _upsertTrack(track, lastQuality: lastQuality, updatedAt: timestamp);
      final platform = _platformValue(track.ref.platform);
      final trackId = _requiredTrackId(track.ref.trackId);
      _db.execute(
        'INSERT INTO online_play_history('
        'platform, track_id, play_count, last_played_at) VALUES(?, ?, 0, ?) '
        'ON CONFLICT(platform, track_id) DO UPDATE SET '
        'last_played_at = excluded.last_played_at',
        [platform, trackId, timestamp.toIso8601String()],
      );
      _trimHistory(historyLimit);
      _removeUnreferencedTracks();
    });
  }

  bool incrementPlayCount(PlatformTrackRef ref) {
    final changed = _db.select(
      'UPDATE online_play_history SET play_count = play_count + 1 '
      'WHERE platform = ? AND track_id = ? RETURNING play_count',
      [_platformValue(ref.platform), _requiredTrackId(ref.trackId)],
    );
    return changed.isNotEmpty;
  }

  List<OnlineHistoryEntry> recentHistory({
    int limit = defaultOnlineHistoryLimit,
  }) {
    if (limit <= 0) return const [];
    return _readHistory(
      orderBy: 'h.last_played_at DESC, h.rowid DESC',
      limit: limit,
    );
  }

  List<OnlineHistoryEntry> topPlayed({int limit = 100}) {
    if (limit <= 0) return const [];
    return _readHistory(
      orderBy: 'h.play_count DESC, h.last_played_at DESC, h.rowid DESC',
      limit: limit,
    );
  }

  OnlineHistoryLibrarySnapshot historySnapshot({
    int recentLimit = defaultOnlineHistoryLimit,
    int topLimit = 100,
  }) {
    final recent = recentHistory(limit: recentLimit);
    final ranked = List<OnlineHistoryEntry>.of(recent)
      ..sort((a, b) {
        final byCount = b.playCount.compareTo(a.playCount);
        if (byCount != 0) return byCount;
        return b.lastPlayedAt.compareTo(a.lastPlayedAt);
      });
    final top = topLimit <= 0
        ? const <OnlineHistoryEntry>[]
        : ranked.take(topLimit).toList(growable: false);
    return OnlineHistoryLibrarySnapshot(
      recent: recent,
      topPlayed: top,
      totalPlayCount: recent.fold(0, (total, entry) => total + entry.playCount),
    );
  }

  void clearHistory() {
    _transaction(() {
      _db.execute('DELETE FROM online_play_history');
      _removeUnreferencedTracks();
    });
  }

  void _upsertTrack(
    MusicTrack track, {
    required String? lastQuality,
    required DateTime updatedAt,
  }) {
    final platform = _platformValue(track.ref.platform);
    final trackId = _requiredTrackId(track.ref.trackId);
    final title = track.title.trim();
    if (title.isEmpty) throw ArgumentError.value(track.title, 'track.title');
    if (track.duration.isNegative) {
      throw ArgumentError.value(track.duration, 'track.duration');
    }

    final coverUri = _safeCoverUri(track.coverUri);
    final quality = _optionalQuality(lastQuality);
    final timestamp = updatedAt.toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO online_tracks('
      'platform, track_id, title, album, cover_uri, duration_ms, availability, '
      'last_quality, created_at, updated_at) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(platform, track_id) DO UPDATE SET '
      'title = excluded.title, '
      "album = CASE WHEN excluded.album <> '' THEN excluded.album "
      'ELSE online_tracks.album END, '
      'cover_uri = COALESCE(excluded.cover_uri, online_tracks.cover_uri), '
      'duration_ms = CASE WHEN excluded.duration_ms > 0 '
      'THEN excluded.duration_ms ELSE online_tracks.duration_ms END, '
      "availability = CASE WHEN excluded.availability <> 'unknown' "
      'THEN excluded.availability ELSE online_tracks.availability END, '
      'last_quality = COALESCE(excluded.last_quality, online_tracks.last_quality), '
      'updated_at = excluded.updated_at',
      [
        platform,
        trackId,
        title,
        track.album.trim(),
        coverUri,
        track.duration.inMilliseconds,
        track.availability.name,
        quality,
        timestamp,
        timestamp,
      ],
    );

    final artists = track.artists
        .map((artist) => artist.trim())
        .where((artist) => artist.isNotEmpty)
        .toList(growable: false);
    if (artists.isEmpty) return;
    _db.execute(
      'DELETE FROM online_track_artists '
      'WHERE platform = ? AND track_id = ?',
      [platform, trackId],
    );
    final statement = _db.prepare(
      'INSERT INTO online_track_artists(platform, track_id, ordinal, name) '
      'VALUES(?, ?, ?, ?)',
    );
    try {
      for (var index = 0; index < artists.length; index++) {
        statement.execute([platform, trackId, index, artists[index]]);
      }
    } finally {
      statement.dispose();
    }
  }

  MusicTrack _readTrack(Row row, {List<String>? artists}) {
    final platform = _parsePlatform(row['platform'] as String);
    final trackId = row['track_id'] as String;
    final resolvedArtists =
        artists ??
        _db
            .select(
              'SELECT name FROM online_track_artists '
              'WHERE platform = ? AND track_id = ? ORDER BY ordinal',
              [row['platform'], trackId],
            )
            .map((artist) => artist['name'] as String)
            .toList(growable: false);
    final rawCoverUri = row['cover_uri'] as String?;
    return MusicTrack(
      ref: PlatformTrackRef(platform: platform, trackId: trackId),
      title: row['title'] as String,
      artists: resolvedArtists,
      album: row['album'] as String,
      coverUri: rawCoverUri == null ? null : Uri.tryParse(rawCoverUri),
      duration: Duration(milliseconds: row['duration_ms'] as int),
      availability: _parseAvailability(row['availability'] as String),
    );
  }

  List<OnlineHistoryEntry> _readHistory({
    required String orderBy,
    required int limit,
  }) {
    final rows = _db
        .select(
          'SELECT t.platform, t.track_id, t.title, t.album, t.cover_uri, '
          't.duration_ms, t.availability, t.last_quality, h.play_count, '
          'h.last_played_at FROM online_play_history h '
          'JOIN online_tracks t ON t.platform = h.platform '
          'AND t.track_id = h.track_id ORDER BY $orderBy LIMIT ?',
          [limit],
        )
        .toList(growable: false);
    final artists = _readArtistsForTracks(rows);
    return rows
        .map(
          (row) => OnlineHistoryEntry(
            track: _readTrack(
              row,
              artists:
                  artists[_trackKey(
                    row['platform'] as String,
                    row['track_id'] as String,
                  )] ??
                  const [],
            ),
            playCount: row['play_count'] as int,
            lastPlayedAt: DateTime.parse(
              row['last_played_at'] as String,
            ).toUtc(),
            lastQuality: row['last_quality'] as String?,
          ),
        )
        .toList(growable: false);
  }

  Map<String, List<String>> _readArtistsForTracks(List<Row> tracks) {
    if (tracks.isEmpty) return const {};
    final refs = <(String, String)>[];
    final seen = <String>{};
    for (final track in tracks) {
      final platform = track['platform'] as String;
      final trackId = track['track_id'] as String;
      if (seen.add(_trackKey(platform, trackId))) {
        refs.add((platform, trackId));
      }
    }

    final artists = <String, List<String>>{};
    const batchSize = 250;
    for (var offset = 0; offset < refs.length; offset += batchSize) {
      final end = offset + batchSize < refs.length
          ? offset + batchSize
          : refs.length;
      final batch = refs.sublist(offset, end);
      final conditions = List.filled(
        batch.length,
        '(platform = ? AND track_id = ?)',
      ).join(' OR ');
      final parameters = <Object?>[];
      for (final ref in batch) {
        parameters
          ..add(ref.$1)
          ..add(ref.$2);
      }
      final rows = _db.select(
        'SELECT platform, track_id, name FROM online_track_artists '
        'WHERE $conditions ORDER BY platform, track_id, ordinal',
        parameters,
      );
      for (final row in rows) {
        final key = _trackKey(
          row['platform'] as String,
          row['track_id'] as String,
        );
        artists.putIfAbsent(key, () => []).add(row['name'] as String);
      }
    }
    return artists;
  }

  void _trimHistory(int limit) {
    _db.execute(
      'DELETE FROM online_play_history WHERE rowid IN ('
      'SELECT rowid FROM online_play_history '
      'ORDER BY last_played_at DESC, rowid DESC LIMIT -1 OFFSET ?)',
      [limit],
    );
  }

  void _removeUnreferencedTracks() {
    _db.execute(
      'DELETE FROM online_tracks WHERE NOT EXISTS ('
      'SELECT 1 FROM online_play_history h '
      'WHERE h.platform = online_tracks.platform '
      'AND h.track_id = online_tracks.track_id) AND NOT EXISTS ('
      'SELECT 1 FROM online_playlist_items i '
      'WHERE i.platform = online_tracks.platform '
      'AND i.track_id = online_tracks.track_id)',
    );
  }

  void _transaction(void Function() action) {
    _db.execute('BEGIN');
    try {
      action();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}

String _platformValue(MusicPlatform platform) => platform.name;

MusicPlatform _parsePlatform(String value) => MusicPlatform.values.firstWhere(
  (platform) => platform.name == value,
  orElse: () => throw FormatException('Unknown music platform: $value'),
);

TrackAvailability _parseAvailability(String value) =>
    TrackAvailability.values.firstWhere(
      (availability) => availability.name == value,
      orElse: () => TrackAvailability.unknown,
    );

String _requiredTrackId(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, 'trackId');
  return normalized;
}

String? _optionalQuality(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'lastQuality');
  }
  return normalized;
}

String? _safeCoverUri(Uri? uri) {
  if (uri == null) return null;
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.queryParameters.keys.any(_isSensitiveQueryKey)) {
    throw ArgumentError.value(uri, 'track.coverUri');
  }
  return uri.toString();
}

bool _isSensitiveQueryKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  return normalized == 'apikey' ||
      normalized == 'token' ||
      normalized == 'authorization' ||
      normalized == 'auth' ||
      normalized == 'cookie' ||
      normalized == 'signature' ||
      normalized == 'sign';
}

String _trackKey(String platform, String trackId) => '$platform\u0000$trackId';
