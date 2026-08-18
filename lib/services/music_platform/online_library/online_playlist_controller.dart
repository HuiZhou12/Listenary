import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';

enum OnlinePlaylistLoadStatus { idle, loading, ready, failed }

@immutable
final class OnlinePlaylistViewSnapshot {
  const OnlinePlaylistViewSnapshot({
    required this.status,
    required this.subscriptions,
    this.errorMessage,
  });

  const OnlinePlaylistViewSnapshot.idle()
    : status = OnlinePlaylistLoadStatus.idle,
      subscriptions = const [],
      errorMessage = null;

  final OnlinePlaylistLoadStatus status;
  final List<OnlinePlaylistSnapshot> subscriptions;
  final String? errorMessage;

  OnlinePlaylistViewSnapshot withStatus(
    OnlinePlaylistLoadStatus value, {
    String? errorMessage,
  }) {
    return OnlinePlaylistViewSnapshot(
      status: value,
      subscriptions: subscriptions,
      errorMessage: errorMessage,
    );
  }
}

@immutable
final class OnlinePlaylistPlaybackSelection {
  OnlinePlaylistPlaybackSelection({
    required Iterable<MusicTrack> tracks,
    required this.selectedIndex,
  }) : tracks = List.unmodifiable(tracks);

  final List<MusicTrack> tracks;
  final int selectedIndex;

  MusicTrack get selectedTrack => tracks[selectedIndex];
}

final class OnlinePlaylistController extends ChangeNotifier {
  OnlinePlaylistController({
    required Future<OnlineLibraryRepository> repository,
    required OnlineMusicService service,
  }) : _repositoryFuture = repository,
       _service = service;

  final Future<OnlineLibraryRepository> _repositoryFuture;
  final OnlineMusicService _service;
  OnlineLibraryRepository? _repository;
  OnlineMusicCancelToken? _activeToken;
  OnlinePlaylistViewSnapshot _snapshot =
      const OnlinePlaylistViewSnapshot.idle();
  int _operation = 0;
  bool _disposed = false;

  OnlinePlaylistViewSnapshot get snapshot => _snapshot;

  Future<void> loadSubscriptions() async {
    if (_disposed) return;
    final operation = ++_operation;
    _setSnapshot(_snapshot.withStatus(OnlinePlaylistLoadStatus.loading));
    try {
      final repository = await _resolveRepository();
      if (_disposed || operation != _operation) return;
      _setSnapshot(
        OnlinePlaylistViewSnapshot(
          status: OnlinePlaylistLoadStatus.ready,
          subscriptions: repository.listSubscriptions(),
        ),
      );
    } catch (_) {
      if (_disposed || operation != _operation) return;
      _setSnapshot(
        _snapshot.withStatus(
          OnlinePlaylistLoadStatus.failed,
          errorMessage: '无法读取在线歌单',
        ),
      );
    }
  }

  Future<OnlinePlaylistSnapshot?> addOrRefresh({
    required MusicPlatform platform,
    required String remotePlaylistId,
  }) =>
      _fetchAndReplace(
        platform: platform,
        remotePlaylistId: remotePlaylistId,
      );

  Future<OnlinePlaylistSnapshot?> refresh(int localId) async {
    if (_disposed) return null;
    if (localId <= 0) throw ArgumentError.value(localId, 'localId');
    final repository = await _resolveRepository();
    OnlinePlaylistSnapshot? subscription;
    for (final item in repository.listSubscriptions()) {
      if (item.localId == localId) {
        subscription = item;
        break;
      }
    }
    if (subscription == null) return null;
    return _fetchAndReplace(
      platform: subscription.playlist.platform,
      remotePlaylistId: subscription.playlist.id,
    );
  }

  Future<bool> delete({
    required MusicPlatform platform,
    required String remotePlaylistId,
  }) async {
    if (_disposed) return false;
    ++_operation;
    _activeToken?.cancel();
    _activeToken = null;
    try {
      final repository = await _resolveRepository();
      final deleted = repository.deleteSubscription(
        platform: platform,
        remotePlaylistId: remotePlaylistId,
      );
      if (!_disposed) {
        _setSnapshot(
          OnlinePlaylistViewSnapshot(
            status: OnlinePlaylistLoadStatus.ready,
            subscriptions: repository.listSubscriptions(),
          ),
        );
      }
      return deleted;
    } catch (_) {
      if (!_disposed) {
        _setSnapshot(
          _snapshot.withStatus(
            OnlinePlaylistLoadStatus.failed,
            errorMessage: '无法删除在线歌单',
          ),
        );
      }
      return false;
    }
  }

  Future<OnlinePlaylistSnapshot?> readSnapshot(int localId) async {
    if (_disposed) return null;
    final repository = await _resolveRepository();
    return repository.readSubscriptionSnapshot(localId);
  }

  Future<OnlinePlaylistPlaybackSelection?> playbackSelection({
    required int localId,
    required PlatformTrackRef selectedRef,
  }) async {
    final snapshot = await readSnapshot(localId);
    if (snapshot == null) return null;
    final tracks = snapshot.playlist.tracks
        .where(
          (track) =>
              track.availability != TrackAvailability.unavailable &&
              track.availability != TrackAvailability.paid,
        )
        .toList(growable: false);
    final selectedIndex = tracks.indexWhere((track) => track.ref == selectedRef);
    if (selectedIndex < 0) throw ArgumentError.value(selectedRef, 'selectedRef');
    return OnlinePlaylistPlaybackSelection(
      tracks: tracks,
      selectedIndex: selectedIndex,
    );
  }

  Future<OnlinePlaylistSnapshot?> _fetchAndReplace({
    required MusicPlatform platform,
    required String remotePlaylistId,
  }) async {
    if (_disposed) return null;
    final normalizedId = remotePlaylistId.trim();
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(normalizedId)) {
      throw ArgumentError.value(remotePlaylistId, 'remotePlaylistId');
    }
    final operation = ++_operation;
    _activeToken?.cancel();
    final token = OnlineMusicCancelToken();
    _activeToken = token;
    _setSnapshot(_snapshot.withStatus(OnlinePlaylistLoadStatus.loading));
    try {
      final repository = await _resolveRepository();
      final playlist = await _service.fetchPlaylist(
        platform: platform,
        playlistId: normalizedId,
        cancelToken: token,
      );
      if (_disposed || token.isCancelled || operation != _operation) {
        return null;
      }
      final saved = repository.replaceSubscriptionSnapshot(playlist);
      _setSnapshot(
        OnlinePlaylistViewSnapshot(
          status: OnlinePlaylistLoadStatus.ready,
          subscriptions: repository.listSubscriptions(),
        ),
      );
      return saved;
    } catch (error) {
      if (_disposed || token.isCancelled || operation != _operation) {
        return null;
      }
      _setSnapshot(
        _snapshot.withStatus(
          OnlinePlaylistLoadStatus.failed,
          errorMessage: _safeErrorMessage(error),
        ),
      );
      return null;
    } finally {
      if (identical(_activeToken, token)) _activeToken = null;
    }
  }

  String _safeErrorMessage(Object error) {
    if (error is OnlineMusicException) return error.safeMessage;
    return '无法刷新在线歌单';
  }

  Future<OnlineLibraryRepository> _resolveRepository() async {
    final existing = _repository;
    if (existing != null) return existing;
    final repository = await _repositoryFuture;
    _repository = repository;
    return repository;
  }

  void _setSnapshot(OnlinePlaylistViewSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_operation;
    _activeToken?.cancel();
    _activeToken = null;
    super.dispose();
  }
}
