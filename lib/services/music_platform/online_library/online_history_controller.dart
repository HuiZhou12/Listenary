import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';

enum OnlineHistoryLoadStatus { idle, loading, ready, failed }

@immutable
final class OnlineHistoryViewSnapshot {
  const OnlineHistoryViewSnapshot({
    required this.status,
    required this.recent,
    required this.topPlayed,
    required this.totalPlayCount,
  });

  const OnlineHistoryViewSnapshot.idle()
    : status = OnlineHistoryLoadStatus.idle,
      recent = const [],
      topPlayed = const [],
      totalPlayCount = 0;

  final OnlineHistoryLoadStatus status;
  final List<OnlineHistoryEntry> recent;
  final List<OnlineHistoryEntry> topPlayed;
  final int totalPlayCount;

  int get trackCount => recent.length;
  bool get hasData => recent.isNotEmpty;

  OnlineHistoryViewSnapshot withStatus(OnlineHistoryLoadStatus value) {
    return OnlineHistoryViewSnapshot(
      status: value,
      recent: recent,
      topPlayed: topPlayed,
      totalPlayCount: totalPlayCount,
    );
  }
}

final class OnlineHistoryController extends ChangeNotifier {
  OnlineHistoryController({required Future<OnlineLibraryRepository> repository})
    : _repositoryFuture = repository;

  final Future<OnlineLibraryRepository> _repositoryFuture;
  OnlineLibraryRepository? _repository;
  OnlineHistoryViewSnapshot _snapshot = const OnlineHistoryViewSnapshot.idle();
  int _loadRequest = 0;
  int _revision = 0;
  bool _disposed = false;

  OnlineHistoryViewSnapshot get snapshot => _snapshot;
  int get revision => _revision;

  Future<void> refresh() async {
    if (_disposed) return;
    final request = ++_loadRequest;
    _setSnapshot(_snapshot.withStatus(OnlineHistoryLoadStatus.loading));
    try {
      final repository = await _resolveRepository();
      await Future<void>.delayed(Duration.zero);
      final data = repository.historySnapshot();
      if (_disposed || request != _loadRequest) return;
      _setSnapshot(
        OnlineHistoryViewSnapshot(
          status: OnlineHistoryLoadStatus.ready,
          recent: data.recent,
          topPlayed: data.topPlayed,
          totalPlayCount: data.totalPlayCount,
        ),
      );
    } catch (_) {
      if (_disposed || request != _loadRequest) return;
      _setSnapshot(_snapshot.withStatus(OnlineHistoryLoadStatus.failed));
    }
  }

  Future<void> recordPlaybackStarted(MusicTrack track, {String? lastQuality}) {
    final repository = _repository;
    if (repository != null) {
      if (!_disposed) {
        repository.recordPlaybackStarted(track, lastQuality: lastQuality);
        _markChanged();
      }
      return Future.value();
    }
    return _recordPlaybackStartedAfterOpen(track, lastQuality: lastQuality);
  }

  Future<void> _recordPlaybackStartedAfterOpen(
    MusicTrack track, {
    required String? lastQuality,
  }) async {
    if (_disposed) return;
    final repository = await _resolveRepository();
    if (_disposed) return;
    repository.recordPlaybackStarted(track, lastQuality: lastQuality);
    _markChanged();
  }

  Future<bool> incrementPlayCount(PlatformTrackRef ref) {
    final repository = _repository;
    if (repository != null) {
      if (_disposed) return Future.value(false);
      final changed = repository.incrementPlayCount(ref);
      if (changed) _markChanged();
      return Future.value(changed);
    }
    return _incrementPlayCountAfterOpen(ref);
  }

  Future<void> updateTrackMetadata(MusicTrack track, {String? lastQuality}) {
    final repository = _repository;
    if (repository != null) {
      if (!_disposed) {
        repository.upsertTrack(track, lastQuality: lastQuality);
        _markChanged();
      }
      return Future.value();
    }
    return _updateTrackMetadataAfterOpen(track, lastQuality: lastQuality);
  }

  Future<void> _updateTrackMetadataAfterOpen(
    MusicTrack track, {
    required String? lastQuality,
  }) async {
    if (_disposed) return;
    final repository = await _resolveRepository();
    if (_disposed) return;
    repository.upsertTrack(track, lastQuality: lastQuality);
    _markChanged();
  }

  Future<bool> _incrementPlayCountAfterOpen(PlatformTrackRef ref) async {
    if (_disposed) return false;
    final repository = await _resolveRepository();
    if (_disposed) return false;
    final changed = repository.incrementPlayCount(ref);
    if (changed) _markChanged();
    return changed;
  }

  Future<void> clearHistory() {
    final repository = _repository;
    if (repository != null) {
      if (!_disposed) _clearHistory(repository);
      return Future.value();
    }
    return _clearHistoryAfterOpen();
  }

  Future<void> _clearHistoryAfterOpen() async {
    if (_disposed) return;
    final repository = await _resolveRepository();
    if (_disposed) return;
    _clearHistory(repository);
  }

  void _clearHistory(OnlineLibraryRepository repository) {
    repository.clearHistory();
    _loadRequest++;
    _revision++;
    _setSnapshot(
      const OnlineHistoryViewSnapshot(
        status: OnlineHistoryLoadStatus.ready,
        recent: [],
        topPlayed: [],
        totalPlayCount: 0,
      ),
    );
  }

  Future<OnlineLibraryRepository> _resolveRepository() async {
    final existing = _repository;
    if (existing != null) return existing;
    final repository = await _repositoryFuture;
    _repository = repository;
    return repository;
  }

  void _markChanged() {
    if (_disposed) return;
    _revision++;
    notifyListeners();
    if (hasListeners) unawaited(refresh());
  }

  void _setSnapshot(OnlineHistoryViewSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _loadRequest++;
    super.dispose();
  }
}
