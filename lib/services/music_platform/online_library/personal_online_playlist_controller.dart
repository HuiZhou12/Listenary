import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

enum PersonalOnlinePlaylistStatus { idle, loading, ready, failed }

@immutable
final class PersonalOnlinePlaylistViewSnapshot {
  const PersonalOnlinePlaylistViewSnapshot({
    required this.status,
    required this.playlists,
    this.errorMessage,
  });

  const PersonalOnlinePlaylistViewSnapshot.idle()
    : status = PersonalOnlinePlaylistStatus.idle,
      playlists = const [],
      errorMessage = null;

  final PersonalOnlinePlaylistStatus status;
  final List<PersonalOnlinePlaylistSnapshot> playlists;
  final String? errorMessage;

  PersonalOnlinePlaylistViewSnapshot withStatus(
    PersonalOnlinePlaylistStatus value, {
    String? errorMessage,
  }) {
    return PersonalOnlinePlaylistViewSnapshot(
      status: value,
      playlists: playlists,
      errorMessage: errorMessage,
    );
  }
}

/// 我的在线歌单控制器：只读仓储层，不发网络请求，仓储异常转换为安全 UI 状态。
final class PersonalOnlinePlaylistController extends ChangeNotifier {
  PersonalOnlinePlaylistController({
    required Future<OnlineLibraryRepository> repository,
  }) : _repositoryFuture = repository;

  final Future<OnlineLibraryRepository> _repositoryFuture;
  OnlineLibraryRepository? _repository;
  PersonalOnlinePlaylistViewSnapshot _snapshot =
      const PersonalOnlinePlaylistViewSnapshot.idle();
  final Set<PlatformTrackRef> _favoriteRefs = {};
  bool _favoritesLoaded = false;
  int _operation = 0;
  bool _disposed = false;

  PersonalOnlinePlaylistViewSnapshot get snapshot => _snapshot;

  Future<void> load() async {
    if (_disposed) return;
    final operation = ++_operation;
    _setSnapshot(_snapshot.withStatus(PersonalOnlinePlaylistStatus.loading));
    try {
      final repository = await _resolveRepository();
      if (_disposed || operation != _operation) return;
      _setReady(repository.listPersonalPlaylists());
    } catch (_) {
      if (_disposed || operation != _operation) return;
      _fail('无法读取我的在线歌单');
    }
  }

  Future<int?> create(String name) async {
    if (_disposed) return null;
    final operation = ++_operation;
    try {
      final repository = await _resolveRepository();
      final localId = repository.createPersonalPlaylist(name);
      if (_disposed || operation != _operation) return null;
      _setReady(repository.listPersonalPlaylists());
      return localId;
    } catch (_) {
      if (_disposed || operation != _operation) return null;
      _fail('无法创建歌单');
      return null;
    }
  }

  Future<bool> rename(int localId, String name) async {
    if (_disposed) return false;
    final operation = ++_operation;
    try {
      final repository = await _resolveRepository();
      final renamed = repository.renamePersonalPlaylist(localId, name);
      if (_disposed || operation != _operation) return false;
      if (renamed) _setReady(repository.listPersonalPlaylists());
      return renamed;
    } catch (_) {
      if (_disposed || operation != _operation) return false;
      _fail('无法重命名歌单');
      return false;
    }
  }

  Future<bool> delete(int localId) async {
    if (_disposed) return false;
    final operation = ++_operation;
    try {
      final repository = await _resolveRepository();
      final deleted = repository.deletePersonalPlaylist(localId);
      if (_disposed || operation != _operation) return false;
      if (deleted) _setReady(repository.listPersonalPlaylists());
      return deleted;
    } catch (_) {
      if (_disposed || operation != _operation) return false;
      _fail('无法删除歌单');
      return false;
    }
  }

  Future<bool> addTrack(int localId, MusicTrack track) async {
    if (_disposed) return false;
    final operation = ++_operation;
    try {
      final repository = await _resolveRepository();
      final added = repository.addTrackToPersonalPlaylist(localId, track);
      if (_disposed || operation != _operation) return false;
      if (added) _setReady(repository.listPersonalPlaylists());
      return added;
    } catch (_) {
      if (_disposed || operation != _operation) return false;
      _fail('无法添加到歌单');
      return false;
    }
  }

  Future<bool> removeTrack(int localId, PlatformTrackRef ref) async {
    if (_disposed) return false;
    final operation = ++_operation;
    try {
      final repository = await _resolveRepository();
      final removed = repository.removeTrackFromPersonalPlaylist(localId, ref);
      if (_disposed || operation != _operation) return false;
      if (removed) _setReady(repository.listPersonalPlaylists());
      return removed;
    } catch (_) {
      if (_disposed || operation != _operation) return false;
      _fail('无法移除曲目');
      return false;
    }
  }

  Future<bool> reorder(int localId, List<PlatformTrackRef> ordered) async {
    if (_disposed) return false;
    final operation = ++_operation;
    try {
      final repository = await _resolveRepository();
      final reordered = repository.reorderPersonalPlaylist(localId, ordered);
      if (_disposed || operation != _operation) return false;
      if (reordered) _setReady(repository.listPersonalPlaylists());
      return reordered;
    } catch (_) {
      if (_disposed || operation != _operation) return false;
      _fail('无法调整排序');
      return false;
    }
  }

  Future<PersonalOnlinePlaylistSnapshot?> readSnapshot(int localId) async {
    if (_disposed) return null;
    final repository = await _resolveRepository();
    return repository.readPersonalPlaylist(localId);
  }

  Future<OnlinePlaylistPlaybackSelection?> playbackSelection({
    required int localId,
    required PlatformTrackRef selectedRef,
  }) async {
    final snapshot = await readSnapshot(localId);
    if (snapshot == null) return null;
    final tracks = snapshot.tracks
        .where(
          (track) =>
              track.availability != TrackAvailability.unavailable &&
              track.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    final selectedIndex = tracks.indexWhere(
      (track) => track.ref == selectedRef,
    );
    if (selectedIndex < 0) {
      throw ArgumentError.value(selectedRef, 'selectedRef');
    }
    return OnlinePlaylistPlaybackSelection(
      tracks: tracks,
      selectedIndex: selectedIndex,
    );
  }

  Future<void> loadFavorites() async {
    if (_disposed) return;
    try {
      final repository = await _resolveRepository();
      final favorites = repository.readFavorites();
      if (_disposed) return;
      _favoriteRefs
        ..clear()
        ..addAll(
          (favorites?.tracks ?? const <MusicTrack>[]).map((track) => track.ref),
        );
      _favoritesLoaded = true;
      notifyListeners();
    } catch (_) {
      // 收藏不可读时保持空集合，不阻断页面。
    }
  }

  bool isFavorite(PlatformTrackRef ref) => _favoriteRefs.contains(ref);

  Future<bool> toggleFavorite(MusicTrack track) async {
    if (_disposed) return false;
    if (!_favoritesLoaded) await loadFavorites();
    if (_disposed) return false;
    try {
      final repository = await _resolveRepository();
      final favorite = repository.toggleFavorite(track);
      if (_disposed) return favorite;
      if (favorite) {
        _favoriteRefs.add(track.ref);
      } else {
        _favoriteRefs.remove(track.ref);
      }
      notifyListeners();
      return favorite;
    } catch (_) {
      return false;
    }
  }

  Future<PersonalOnlinePlaylistSnapshot?> readFavorites() async {
    if (_disposed) return null;
    final repository = await _resolveRepository();
    return repository.readFavorites();
  }

  Future<OnlineLibraryRepository> _resolveRepository() async {
    final existing = _repository;
    if (existing != null) return existing;
    final repository = await _repositoryFuture;
    _repository = repository;
    return repository;
  }

  void _setReady(List<PersonalOnlinePlaylistSnapshot> playlists) {
    if (_disposed) return;
    _snapshot = PersonalOnlinePlaylistViewSnapshot(
      status: PersonalOnlinePlaylistStatus.ready,
      playlists: playlists,
    );
    notifyListeners();
  }

  void _fail(String message) {
    if (_disposed) return;
    _snapshot = _snapshot.withStatus(
      PersonalOnlinePlaylistStatus.failed,
      errorMessage: message,
    );
    notifyListeners();
  }

  void _setSnapshot(PersonalOnlinePlaylistViewSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_operation;
    super.dispose();
  }
}
