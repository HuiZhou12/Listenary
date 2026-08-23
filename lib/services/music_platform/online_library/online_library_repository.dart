import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:sqlite3/sqlite3.dart';

const defaultOnlineHistoryLimit = 1000;

/// 内置「收藏」在线歌单的保留名称；应用内禁止删除/重命名/创建同名歌单。
const personalFavoritesPlaylistName = '我的收藏';

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

final class OnlinePlaylistSnapshot {
  const OnlinePlaylistSnapshot({
    required this.localId,
    required this.playlist,
    required this.lastRefreshedAt,
  });

  final int localId;
  final RemotePlaylist playlist;
  final DateTime? lastRefreshedAt;
}

/// 我的在线歌单快照：混合平台个人歌单，含有序曲目。
final class PersonalOnlinePlaylistSnapshot {
  PersonalOnlinePlaylistSnapshot({
    required this.localId,
    required this.name,
    required this.updatedAt,
    required Iterable<MusicTrack> tracks,
  }) : tracks = List.unmodifiable(tracks);

  final int localId;
  final String name;
  final DateTime? updatedAt;
  final List<MusicTrack> tracks;
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

  OnlinePlaylistSnapshot? findSubscription({
    required MusicPlatform platform,
    required String remotePlaylistId,
  }) {
    final rows = _db.select(
      'SELECT id, platform, remote_playlist_id, name, cover_uri, creator, '
      'remote_track_count, last_refreshed_at FROM online_playlists '
      "WHERE kind = 'subscription' AND platform = ? AND remote_playlist_id = ?",
      [_platformValue(platform), _requiredRemotePlaylistId(remotePlaylistId)],
    );
    if (rows.isEmpty) return null;
    return _readPlaylistSnapshot(rows.single);
  }

  List<OnlinePlaylistSnapshot> listSubscriptions() {
    final rows = _db.select(
      'SELECT id, platform, remote_playlist_id, name, cover_uri, creator, '
      'remote_track_count, last_refreshed_at FROM online_playlists '
      "WHERE kind = 'subscription' ORDER BY updated_at DESC, id DESC",
    );
    return rows.map(_readPlaylistSnapshot).toList(growable: false);
  }

  OnlinePlaylistSnapshot? readSubscriptionSnapshot(int localId) {
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    final rows = _db.select(
      'SELECT id, platform, remote_playlist_id, name, cover_uri, creator, '
      'remote_track_count, last_refreshed_at FROM online_playlists '
      "WHERE id = ? AND kind = 'subscription'",
      [localId],
    );
    if (rows.isEmpty) return null;
    final base = _readPlaylistSnapshot(rows.single);
    final playlist = base.playlist;
    final itemRows = _db.select(
      'SELECT t.platform, t.track_id, t.title, t.album, t.cover_uri, '
      't.duration_ms, t.availability FROM online_playlist_items i '
      'JOIN online_tracks t ON t.platform = i.platform AND t.track_id = i.track_id '
      'WHERE i.playlist_id = ? ORDER BY i.sort_order, i.rowid',
      [localId],
    );
    final tracks = itemRows.map(_readTrack).toList(growable: false);
    return OnlinePlaylistSnapshot(
      localId: base.localId,
      playlist: RemotePlaylist(
        platform: playlist.platform,
        id: playlist.id,
        name: playlist.name,
        coverUri: playlist.coverUri,
        creator: playlist.creator,
        trackCount: playlist.trackCount,
        tracks: tracks,
      ),
      lastRefreshedAt: base.lastRefreshedAt,
    );
  }

  OnlinePlaylistSnapshot replaceSubscriptionSnapshot(
    RemotePlaylist playlist, {
    DateTime? refreshedAt,
  }) {
    _validatePlaylistSnapshot(playlist);
    final timestamp = (refreshedAt ?? DateTime.now()).toUtc();
    late OnlinePlaylistSnapshot result;
    _transaction(() {
      final platform = _platformValue(playlist.platform);
      final remoteId = _requiredRemotePlaylistId(playlist.id);
      final existing = _db.select(
        'SELECT id FROM online_playlists '
        "WHERE kind = 'subscription' AND platform = ? AND remote_playlist_id = ?",
        [platform, remoteId],
      );
      late final int localId;
      if (existing.isEmpty) {
        _db.execute(
          'INSERT INTO online_playlists('
          'kind, name, platform, remote_playlist_id, cover_uri, creator, '
          'remote_track_count, last_refreshed_at, created_at, updated_at) '
          "VALUES('subscription', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            playlist.name.trim(),
            platform,
            remoteId,
            _safeCoverUri(playlist.coverUri),
            _optionalText(playlist.creator),
            playlist.trackCount,
            timestamp.toIso8601String(),
            timestamp.toIso8601String(),
            timestamp.toIso8601String(),
          ],
        );
        localId = _db.lastInsertRowId;
      } else {
        localId = existing.single['id'] as int;
        _db.execute(
          'UPDATE online_playlists SET name = ?, cover_uri = ?, creator = ?, '
          'remote_track_count = ?, last_refreshed_at = ?, updated_at = ? '
          'WHERE id = ?',
          [
            playlist.name.trim(),
            _safeCoverUri(playlist.coverUri),
            _optionalText(playlist.creator),
            playlist.trackCount,
            timestamp.toIso8601String(),
            timestamp.toIso8601String(),
            localId,
          ],
        );
      }

      _db.execute('DELETE FROM online_playlist_items WHERE playlist_id = ?', [
        localId,
      ]);
      final addedAt = timestamp.toIso8601String();
      final statement = _db.prepare(
        'INSERT INTO online_playlist_items('
        'playlist_id, platform, track_id, sort_order, added_at) '
        'VALUES(?, ?, ?, ?, ?)',
      );
      try {
        for (var index = 0; index < playlist.tracks.length; index++) {
          final track = playlist.tracks[index];
          _upsertTrack(track, lastQuality: null, updatedAt: timestamp);
          statement.execute([
            localId,
            platform,
            _requiredTrackId(track.ref.trackId),
            index,
            addedAt,
          ]);
        }
      } finally {
        statement.dispose();
      }
      _removeUnreferencedTracks();
      result = readSubscriptionSnapshot(localId)!;
    });
    return result;
  }

  bool deleteSubscription({
    required MusicPlatform platform,
    required String remotePlaylistId,
  }) {
    var deleted = false;
    _transaction(() {
      final rows = _db.select(
        'SELECT id FROM online_playlists '
        "WHERE kind = 'subscription' AND platform = ? AND remote_playlist_id = ?",
        [_platformValue(platform), _requiredRemotePlaylistId(remotePlaylistId)],
      );
      if (rows.isEmpty) return;
      _db.execute('DELETE FROM online_playlists WHERE id = ?', [
        rows.single['id'],
      ]);
      _removeUnreferencedTracks();
      deleted = true;
    });
    return deleted;
  }

  /// 创建我的在线歌单；名称在同类型内大小写不敏感唯一，冲突抛 ArgumentError。
  int createPersonalPlaylist(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name');
    if (trimmed == personalFavoritesPlaylistName) {
      throw ArgumentError.value(name, 'name', 'reserved favorites name');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    late int localId;
    _transaction(() {
      final existing = _db.select(
        'SELECT id FROM online_playlists '
        "WHERE kind = 'personal' AND name = ? COLLATE NOCASE",
        [trimmed],
      );
      if (existing.isNotEmpty) {
        throw ArgumentError.value(
          name,
          'name',
          'duplicate personal playlist name',
        );
      }
      _db.execute(
        'INSERT INTO online_playlists(kind, name, created_at, updated_at) '
        "VALUES('personal', ?, ?, ?)",
        [trimmed, now, now],
      );
      localId = _db.lastInsertRowId;
    });
    return localId;
  }

  List<PersonalOnlinePlaylistSnapshot> listPersonalPlaylists() {
    final rows = _db.select(
      'SELECT id, name, updated_at FROM online_playlists '
      "WHERE kind = 'personal' AND name <> ? ORDER BY updated_at DESC, id DESC",
      [personalFavoritesPlaylistName],
    );
    return rows.map(_readPersonalPlaylistFromRow).toList(growable: false);
  }

  PersonalOnlinePlaylistSnapshot? readPersonalPlaylist(int localId) {
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    final rows = _db.select(
      'SELECT id, name, updated_at FROM online_playlists '
      "WHERE id = ? AND kind = 'personal'",
      [localId],
    );
    if (rows.isEmpty) return null;
    return _readPersonalPlaylistFromRow(rows.single);
  }

  /// 重命名；同名冲突或写入失败返回 false 并保持旧名称。
  bool renamePersonalPlaylist(int localId, String name) {
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name');
    if (trimmed == personalFavoritesPlaylistName) {
      throw ArgumentError.value(name, 'name', 'reserved favorites name');
    }
    var renamed = false;
    _transaction(() {
      final playlist = _db.select(
        "SELECT name FROM online_playlists WHERE id = ? AND kind = 'personal'",
        [localId],
      );
      if (playlist.isEmpty) return;
      if (playlist.single['name'] == personalFavoritesPlaylistName) {
        throw ArgumentError.value(localId, 'localId', 'favorites is read-only');
      }
      final duplicate = _db.select(
        'SELECT 1 FROM online_playlists '
        "WHERE kind = 'personal' AND name = ? COLLATE NOCASE AND id <> ?",
        [trimmed, localId],
      );
      if (duplicate.isNotEmpty) return;
      _db.execute(
        "UPDATE online_playlists SET name = ?, updated_at = ? WHERE id = ? AND kind = 'personal'",
        [trimmed, DateTime.now().toUtc().toIso8601String(), localId],
      );
      renamed = true;
    });
    return renamed;
  }

  bool deletePersonalPlaylist(int localId) {
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    var deleted = false;
    _transaction(() {
      final playlist = _db.select(
        "SELECT name FROM online_playlists WHERE id = ? AND kind = 'personal'",
        [localId],
      );
      if (playlist.isEmpty) return;
      if (playlist.single['name'] == personalFavoritesPlaylistName) {
        throw ArgumentError.value(localId, 'localId', 'favorites is read-only');
      }
      _db.execute(
        "DELETE FROM online_playlists WHERE id = ? AND kind = 'personal'",
        [localId],
      );
      _removeUnreferencedTracks();
      deleted = true;
    });
    return deleted;
  }

  /// 查找或创建内置收藏歌单，返回其 localId。
  int ensureFavoritesPlaylist() {
    var localId = -1;
    _transaction(() {
      final rows = _db.select(
        'SELECT id FROM online_playlists '
        "WHERE kind = 'personal' AND name = ?",
        [personalFavoritesPlaylistName],
      );
      if (rows.isNotEmpty) {
        localId = rows.single['id'] as int;
        return;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      _db.execute(
        'INSERT INTO online_playlists(kind, name, created_at, updated_at) '
        "VALUES('personal', ?, ?, ?)",
        [personalFavoritesPlaylistName, now, now],
      );
      localId = _db.lastInsertRowId;
    });
    return localId;
  }

  PersonalOnlinePlaylistSnapshot? readFavorites() {
    final localId = ensureFavoritesPlaylist();
    return readPersonalPlaylist(localId);
  }

  /// 曲目是否在收藏歌单中。
  bool isFavorite(PlatformTrackRef ref) {
    final rows = _db.select(
      'SELECT 1 FROM online_playlist_items i '
      'JOIN online_playlists p ON p.id = i.playlist_id '
      "WHERE p.kind = 'personal' AND p.name = ? "
      'AND i.platform = ? AND i.track_id = ?',
      [
        personalFavoritesPlaylistName,
        _platformValue(ref.platform),
        _requiredTrackId(ref.trackId),
      ],
    );
    return rows.isNotEmpty;
  }

  /// 切换收藏；返回操作后是否处于收藏状态。
  bool toggleFavorite(MusicTrack track) {
    final localId = ensureFavoritesPlaylist();
    if (isFavorite(track.ref)) {
      removeTrackFromPersonalPlaylist(localId, track.ref);
      return false;
    }
    addTrackToPersonalPlaylist(localId, track);
    return true;
  }

  /// 追加曲目到 personal 歌单末尾；重复添加幂等成功且不改变排序位置。
  bool addTrackToPersonalPlaylist(int localId, MusicTrack track) {
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    if (track.title.trim().isEmpty) {
      throw ArgumentError.value(track.title, 'track.title');
    }
    var added = false;
    _transaction(() {
      final playlist = _db.select(
        "SELECT 1 FROM online_playlists WHERE id = ? AND kind = 'personal'",
        [localId],
      );
      if (playlist.isEmpty) return;
      final platform = _platformValue(track.ref.platform);
      final trackId = _requiredTrackId(track.ref.trackId);
      final already = _db.select(
        'SELECT 1 FROM online_playlist_items '
        'WHERE playlist_id = ? AND platform = ? AND track_id = ?',
        [localId, platform, trackId],
      );
      if (already.isNotEmpty) {
        added = true;
        return;
      }
      _upsertTrack(track, lastQuality: null, updatedAt: DateTime.now().toUtc());
      final order = _db.select(
        'SELECT COALESCE(MAX(sort_order), -1) + 1 AS next '
        'FROM online_playlist_items WHERE playlist_id = ?',
        [localId],
      );
      final next = order.single['next'] as int;
      _db.execute(
        'INSERT INTO online_playlist_items('
        'playlist_id, platform, track_id, sort_order, added_at) '
        'VALUES(?, ?, ?, ?, ?)',
        [
          localId,
          platform,
          trackId,
          next,
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      _db.execute('UPDATE online_playlists SET updated_at = ? WHERE id = ?', [
        DateTime.now().toUtc().toIso8601String(),
        localId,
      ]);
      added = true;
    });
    return added;
  }

  bool removeTrackFromPersonalPlaylist(int localId, PlatformTrackRef ref) {
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    var removed = false;
    _transaction(() {
      final item = _db.select(
        'SELECT 1 FROM online_playlist_items '
        'WHERE playlist_id = ? AND platform = ? AND track_id = ?',
        [localId, _platformValue(ref.platform), _requiredTrackId(ref.trackId)],
      );
      if (item.isEmpty) return;
      _db.execute(
        'DELETE FROM online_playlist_items '
        'WHERE playlist_id = ? AND platform = ? AND track_id = ?',
        [localId, _platformValue(ref.platform), _requiredTrackId(ref.trackId)],
      );
      _db.execute('UPDATE online_playlists SET updated_at = ? WHERE id = ?', [
        DateTime.now().toUtc().toIso8601String(),
        localId,
      ]);
      _removeUnreferencedTracks();
      removed = true;
    });
    return removed;
  }

  /// 重写 personal 歌单排序；ordered 必须与当前曲目集合一致，失败回滚不写入。
  bool reorderPersonalPlaylist(int localId, List<PlatformTrackRef> ordered) {
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    var reordered = false;
    _transaction(() {
      final items = _db.select(
        'SELECT platform, track_id FROM online_playlist_items WHERE playlist_id = ?',
        [localId],
      );
      final current = items
          .map((row) => '${row['platform']}:${row['track_id']}')
          .toSet();
      final target = ordered
          .map(
            (ref) =>
                '${_platformValue(ref.platform)}:${_requiredTrackId(ref.trackId)}',
          )
          .toSet();
      if (current.length != ordered.length || !current.containsAll(target)) {
        return;
      }
      // 先整体加条目数偏移，避免逐行写入时撞上 UNIQUE(playlist_id, sort_order)。
      _db.execute(
        'UPDATE online_playlist_items SET sort_order = sort_order + ? '
        'WHERE playlist_id = ?',
        [current.length, localId],
      );
      final statement = _db.prepare(
        'UPDATE online_playlist_items SET sort_order = ? '
        'WHERE playlist_id = ? AND platform = ? AND track_id = ?',
      );
      try {
        for (var index = 0; index < ordered.length; index++) {
          statement.execute([
            index,
            localId,
            _platformValue(ordered[index].platform),
            _requiredTrackId(ordered[index].trackId),
          ]);
        }
      } finally {
        statement.dispose();
      }
      _db.execute('UPDATE online_playlists SET updated_at = ? WHERE id = ?', [
        DateTime.now().toUtc().toIso8601String(),
        localId,
      ]);
      reordered = true;
    });
    return reordered;
  }

  PersonalOnlinePlaylistSnapshot _readPersonalPlaylistFromRow(Row row) {
    final localId = row['id'] as int;
    final trackRows = _db.select(
      'SELECT t.platform, t.track_id, t.title, t.album, t.cover_uri, '
      't.duration_ms, t.availability '
      'FROM online_playlist_items i JOIN online_tracks t '
      'ON t.platform = i.platform AND t.track_id = i.track_id '
      'WHERE i.playlist_id = ? ORDER BY i.sort_order, i.rowid',
      [localId],
    );
    final tracks = trackRows.map(_readTrack).toList(growable: false);
    final updated = row['updated_at'] as String?;
    return PersonalOnlinePlaylistSnapshot(
      localId: localId,
      name: row['name'] as String,
      updatedAt: updated == null ? null : DateTime.parse(updated).toUtc(),
      tracks: tracks,
    );
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

  OnlinePlaylistSnapshot _readPlaylistSnapshot(Row row) {
    final platform = _parsePlatform(row['platform'] as String);
    final remoteId = row['remote_playlist_id'] as String;
    final cover = row['cover_uri'] as String?;
    final refreshed = row['last_refreshed_at'] as String?;
    return OnlinePlaylistSnapshot(
      localId: row['id'] as int,
      playlist: RemotePlaylist(
        platform: platform,
        id: remoteId,
        name: row['name'] as String,
        coverUri: cover == null ? null : Uri.tryParse(cover),
        creator: row['creator'] as String?,
        trackCount: row['remote_track_count'] as int?,
      ),
      lastRefreshedAt: refreshed == null
          ? null
          : DateTime.parse(refreshed).toUtc(),
    );
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

String _requiredRemotePlaylistId(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[1-9][0-9]*$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'remotePlaylistId');
  }
  return normalized;
}

String? _optionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

void _validatePlaylistSnapshot(RemotePlaylist playlist) {
  _requiredRemotePlaylistId(playlist.id);
  if (playlist.name.trim().isEmpty) {
    throw ArgumentError.value(playlist.name, 'playlist.name');
  }
  final count = playlist.trackCount;
  if (count != null && (count < 0 || count != playlist.tracks.length)) {
    throw ArgumentError.value(count, 'playlist.trackCount');
  }
  final ids = <String>{};
  for (final track in playlist.tracks) {
    if (track.ref.platform != playlist.platform ||
        !ids.add(_requiredTrackId(track.ref.trackId))) {
      throw ArgumentError.value(track.ref, 'playlist.tracks');
    }
  }
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
