import 'dart:async';

import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/remote_stream_coordinator.dart';

abstract interface class LocalPlaybackResumePoint {}

final class PlaybackServiceResumePoint implements LocalPlaybackResumePoint {
  PlaybackServiceResumePoint({
    required Iterable<Audio> playlist,
    required this.playlistIndex,
    required this.position,
    required this.playerState,
  }) : playlist = List.unmodifiable(playlist);

  final List<Audio> playlist;
  final int playlistIndex;
  final double position;
  final PlayerState playerState;
}

abstract interface class LocalPlaybackSessionBridge {
  LocalPlaybackResumePoint? capture();

  void pause();

  void restore(LocalPlaybackResumePoint resumePoint);

  void addLocalPlaybackRequestListener(void Function() listener);

  void removeLocalPlaybackRequestListener(void Function() listener);
}

final class PlaybackServiceLocalPlaybackSessionBridge
    implements LocalPlaybackSessionBridge {
  const PlaybackServiceLocalPlaybackSessionBridge({
    required PlayService playService,
  }) : _playService = playService;

  final PlayService _playService;

  @override
  LocalPlaybackResumePoint? capture() {
    if (!_playService.hasPlaybackSession) return null;
    final playback = _playService.playbackService;
    final nowPlaying = playback.nowPlaying;
    final playlist = playback.playlist.value;
    if (nowPlaying == null || playlist.isEmpty) return null;

    var index = playback.playlistIndex;
    if (index >= playlist.length || playlist[index].path != nowPlaying.path) {
      index = playlist.indexWhere((audio) => audio.path == nowPlaying.path);
    }
    if (index < 0) return null;

    return PlaybackServiceResumePoint(
      playlist: playlist,
      playlistIndex: index,
      position: playback.position,
      playerState: playback.playerState,
    );
  }

  @override
  void pause() => _playService.playbackService.pause();

  @override
  void restore(LocalPlaybackResumePoint resumePoint) {
    if (resumePoint is! PlaybackServiceResumePoint) {
      throw ArgumentError.value(resumePoint, 'resumePoint');
    }
    final playback = _playService.playbackService;
    final currentPlaylist = playback.playlist.value;
    if (currentPlaylist.length != resumePoint.playlist.length) {
      throw StateError('The local playlist changed during remote playback');
    }
    for (var index = 0; index < currentPlaylist.length; index++) {
      if (currentPlaylist[index].path != resumePoint.playlist[index].path) {
        throw StateError('The local playlist changed during remote playback');
      }
    }

    if (!playback.playIndexOfPlaylist(resumePoint.playlistIndex)) {
      throw StateError('The local playback context could not be restored');
    }
    final expectedPath = resumePoint.playlist[resumePoint.playlistIndex].path;
    if (playback.nowPlaying?.path != expectedPath) {
      throw StateError('The local playback context could not be restored');
    }
    if (resumePoint.position > 0) {
      playback.seek(resumePoint.position);
    }
    if (resumePoint.playerState != PlayerState.playing) {
      playback.pause();
    }
  }

  @override
  void addLocalPlaybackRequestListener(void Function() listener) {
    _playService.addLocalPlaybackRequestListener(listener);
  }

  @override
  void removeLocalPlaybackRequestListener(void Function() listener) {
    _playService.removeLocalPlaybackRequestListener(listener);
  }
}

enum RemotePlaybackSessionFailure {
  nextTrack,
  navigation,
  control,
  localRestore,
  remoteStop,
}

final class RemotePlaybackControlSnapshot
    implements RemotePlaybackControlState {
  const RemotePlaybackControlSnapshot({
    required this.state,
    required this.controlInFlight,
  });

  static const inactive = RemotePlaybackControlSnapshot(
    state: null,
    controlInFlight: false,
  );

  @override
  final PlaybackBackendState? state;
  @override
  final bool controlInFlight;

  @override
  bool get isActive => state != null;
}

final class RemotePlaybackSessionController {
  RemotePlaybackSessionController({
    required RemotePlaybackQueue queue,
    required RemotePlaybackQueueController remoteController,
    required LocalPlaybackSessionBridge localBridge,
    required ControllablePlaybackBackend backend,
    void Function(RemotePlaybackSessionFailure failure)? onFailure,
    void Function(String quality)? onQualityDowngraded,

    /// **方案 B** 的降权判定入口：把"平台实际返回的取值"判成**要展示的档位名**；
    /// 没降权 / 认不出该取值时返回 null。由组合根注入（见 `entry.dart`）。
    ///
    /// 签名**只用核心类型**：`lib/play_service` 不得依赖 provider 层类型
    /// （`online_music_dependency_boundary_test` 守住这条边界）。
    /// 真正的判定是 `resolveQualityDowngrade`（档位模块里的纯函数，有独立测试）。
    String? Function({
      required MusicPlatform platform,
      required String requested,
      required String actual,
      String? previousActual,
    })?
    qualityDowngradeLabelFor,
  }) : _queue = queue,
       _remoteController = remoteController,
       _localBridge = localBridge,
       _backend = backend,
       _onFailure = onFailure,
       _onQualityDowngraded = onQualityDowngraded,
       _qualityDowngradeLabelFor = qualityDowngradeLabelFor {
    _backendStateSubscription = backend.stateStream.listen(_onBackendState);
    _localBridge.addLocalPlaybackRequestListener(_onLocalPlaybackRequested);
  }

  final RemotePlaybackQueue _queue;
  final RemotePlaybackQueueController _remoteController;
  final LocalPlaybackSessionBridge _localBridge;
  final ControllablePlaybackBackend _backend;
  final void Function(RemotePlaybackSessionFailure failure)? _onFailure;

  /// 收到的是**要展示的档位名**（平台自己的文案；平台没声明档位时是内部档位的中文文案）。
  final void Function(String quality)? _onQualityDowngraded;

  /// 降权判定（**方案 B**）：返回要展示的档位名；null = 不提示。
  final String? Function({
    required MusicPlatform platform,
    required String requested,
    required String actual,
    String? previousActual,
  })?
  _qualityDowngradeLabelFor;
  final _controlStateController =
      StreamController<RemotePlaybackControlSnapshot>.broadcast(sync: true);
  late final StreamSubscription<PlaybackBackendState> _backendStateSubscription;
  RemotePlaybackControlSnapshot _controlState =
      RemotePlaybackControlSnapshot.inactive;
  LocalPlaybackResumePoint? _localResumePoint;
  String? _requestedQuality;

  /// 平台实际返回的档位，用于降权提示与切歌时保持可用档位。
  ///
  /// ⚠️ 它不是 `MusicQuality.level`（内部偏好），而是**平台自己的请求值**
  /// （`queue_controller` 把平台返回值原样带回来），因此它**只对产生它的那个平台有效**
  /// —— 见 [_currentQualityPlatform] 与 P-57 的携带条件。
  String? _currentQuality;

  /// [_currentQuality] 所属的平台。
  ///
  /// P-57：`fallbackQuality` **只在同一平台内携带** —— 档位取值域是平台专属的
  /// （`flac`/`sq`/`320` 之类），把上一首所在平台的取值当成下一首（可能换平台）的
  /// "下限"，会去新平台的档位表里反查出一个**毫无意义**的下限、压掉本该可用的档位。
  /// 因此必须**连同平台一起记住**，携带前比较。
  MusicPlatform? _currentQualityPlatform;
  int _revision = 0;
  int _controlRevision = 0;
  int? _activeRemoteRevision;
  int? _stopTransitionRevision;
  bool _sessionStarted = false;
  bool _disposed = false;

  LocalPlaybackResumePoint? get localResumePoint => _localResumePoint;
  int get playbackRevision => _revision;
  String? get requestedQuality => _requestedQuality;
  RemotePlaybackControlSnapshot get controlState => _controlState;
  Stream<RemotePlaybackControlSnapshot> get controlStateStream =>
      _controlStateController.stream;

  RemotePlaybackMode get mode => _queue.value.mode;

  /// 当前实际播放档位（平台返回的 `level`）；无远程会话时为 null。
  String? get currentQuality => _currentQuality;

  /// 队列中某一项的来源平台；越界 / 空队列返回 null（此时不提示，避免误报）。
  MusicPlatform? _platformOf(int? index) {
    final snapshot = _queue.value;
    if (index == null || index < 0 || index >= snapshot.items.length) {
      return null;
    }
    return snapshot.items[index].ref.platform;
  }

  /// 记录本次解析的真实档位；仅在**实际降权**时提示一次，回升不提示、不重复提示。
  ///
  /// **[platform] 是方案 B 的关键**：平台返回的是它自己的取值（QQ 是 `flac`/`128`），
  /// 用内部枚举下标查不到 ⇒ 非网易云平台的降级提示永远不触发。
  /// 这里只负责"取值 → 展示名"的委托，判定本身是 [resolveQualityDowngrade]。
  void _applyResolvedQuality(
    String requested,
    String? actual, {
    MusicPlatform? platform,
  }) {
    final previous = _currentQuality;
    final resolved = actual ?? requested;
    _currentQuality = resolved;
    // P-57：档位是**平台专属取值** ⇒ 连同平台一起记住（平台未知就记 null，
    // 这样携带条件判等为假，宁可不带也不带错）。
    _currentQualityPlatform = platform;
    final resolver = _qualityDowngradeLabelFor;
    if (resolver == null || platform == null) return;
    final label = resolver(
      platform: platform,
      requested: requested,
      actual: resolved,
      previousActual: previous,
    );
    if (label == null) return;
    _onQualityDowngraded?.call(label);
  }

  void cycleMode() => _queue.cycleMode();

  void reorder(int oldIndex, int newIndex) =>
      _queue.reorder(oldIndex, newIndex);

  bool previous() => _navigate(-1);

  bool next() => _navigate(1);

  bool pause() => _control(
    expectedState: PlaybackBackendState.playing,
    action: _backend.pause,
  );

  bool resume() => _control(
    expectedState: PlaybackBackendState.paused,
    action: _backend.resume,
  );

  bool _navigate(int offset) {
    if (_disposed || !_sessionStarted) return false;
    final snapshot = _queue.value;
    final currentIndex = snapshot.currentIndex;
    final requestedQuality = _requestedQuality;
    if (currentIndex == null || requestedQuality == null) return true;
    final targetIndex = currentIndex + offset;
    if (targetIndex < 0 || targetIndex >= snapshot.items.length) return true;
    final expectedRevision = _revision + 1;
    unawaited(
      _playRemote(targetIndex, requestedQuality: requestedQuality).catchError((
        error,
      ) {
        if (error is! _RemoteTransitionStopException &&
            !_disposed &&
            _revision == expectedRevision) {
          _onFailure?.call(RemotePlaybackSessionFailure.navigation);
        }
      }),
    );
    return true;
  }

  Future<void> play(int index, {required String requestedQuality}) async {
    _throwIfDisposed();
    RangeError.checkValidIndex(index, _queue.value.items, 'index');
    if (_ignoresRepeatedSelection(index)) return;
    final hadRemoteSession = _sessionStarted;
    if (!_sessionStarted) {
      final resumePoint = _localBridge.capture();
      if (resumePoint != null) {
        _localBridge.pause();
      }
      _localResumePoint = resumePoint;
      _sessionStarted = true;
    }
    await _playRemote(
      index,
      requestedQuality: requestedQuality,
      stopCurrent: hadRemoteSession,
    );
  }

  /// 播放中切换音质：保持当前流播放，解析新音质就绪后由后端在原位置无缝切换
  /// （BASS 切源会 crossfade 并恢复位置）。失败时保留当前流并回退音质。
  Future<bool> switchQuality(String newQuality) async {
    _throwIfDisposed();
    final snapshot = _queue.value;
    final currentIndex = snapshot.currentIndex;
    if (currentIndex == null || currentIndex >= snapshot.items.length) {
      return false;
    }
    if (_requestedQuality == newQuality) return true;
    final previousQuality = _requestedQuality;
    final previousActualQuality = _currentQuality;
    _requestedQuality = newQuality;
    try {
      final actual = await _remoteController.play(
        currentIndex,
        requestedQuality: newQuality,
        fallbackQuality: previousActualQuality,
      );
      _applyResolvedQuality(
        newQuality,
        actual,
        platform: _platformOf(currentIndex),
      );
      return true;
    } catch (_) {
      _requestedQuality = previousQuality;
      _currentQuality = previousActualQuality;
      return false;
    }
  }

  /// 从在线队列移除指定索引；移除了当前曲目且队列非空时原位播放下一项，
  /// 队列为空则结束会话并恢复本地。
  Future<void> removeFromQueue(int index) async {
    _throwIfDisposed();
    final snapshot = _queue.value;
    final currentIndex = snapshot.currentIndex;
    if (index < 0 || index >= snapshot.items.length) return;
    final removedRef = _queue.removeAt(index);
    if (removedRef == null) return;
    final wasCurrent =
        currentIndex != null && snapshot.items[currentIndex].ref == removedRef;
    if (!_sessionStarted || !wasCurrent) return;
    if (_queue.value.isEmpty) {
      await clearQueue();
      return;
    }
    final requestedQuality = _requestedQuality;
    final targetIndex = _queue.value.currentIndex;
    if (requestedQuality == null || targetIndex == null) return;
    await _playRemote(targetIndex, requestedQuality: requestedQuality);
  }

  /// 清空在线队列并结束远程会话，恢复到进入远程前的本地播放点。
  Future<void> clearQueue() async {
    _throwIfDisposed();
    if (!_sessionStarted) return;
    ++_revision;
    _remoteController.cancel();
    _queue.clear();
    final resumePoint = _localResumePoint;
    _endSession();
    await _stopRemoteSafely();
    if (resumePoint == null) return;
    try {
      _localBridge.restore(resumePoint);
    } catch (_) {
      try {
        _localBridge.pause();
      } catch (_) {}
      if (!_disposed) {
        _onFailure?.call(RemotePlaybackSessionFailure.localRestore);
      }
    }
  }

  Future<void> _playRemote(
    int index, {
    required String requestedQuality,
    bool stopCurrent = true,
  }) async {
    final revision = ++_revision;
    _invalidateControl();
    _remoteController.cancel();
    _setControlState(
      const RemotePlaybackControlSnapshot(
        state: PlaybackBackendState.opening,
        controlInFlight: false,
      ),
    );
    _queue.select(index);
    _activeRemoteRevision = null;
    _requestedQuality = requestedQuality;
    try {
      if (stopCurrent) {
        _stopTransitionRevision = revision;
        try {
          await _backend.stop();
        } catch (_) {
          if (!_disposed && revision == _revision) {
            _onFailure?.call(RemotePlaybackSessionFailure.remoteStop);
          }
          throw const _RemoteTransitionStopException();
        } finally {
          if (_stopTransitionRevision == revision) {
            _stopTransitionRevision = null;
          }
        }
        if (_disposed || revision != _revision) {
          throw const RemoteStreamPlaybackException(
            kind: RemoteStreamPlaybackErrorKind.cancelled,
          );
        }
        _setControlState(
          const RemotePlaybackControlSnapshot(
            state: PlaybackBackendState.opening,
            controlInFlight: false,
          ),
        );
      }
      // P-57：`fallbackQuality` **只在同一平台内携带**。
      // `_currentQuality` 是**上一首所在平台**的实际取值（平台专属）；下一首换了平台时
      // 它对新平台毫无意义 —— 带着它会在新平台的档位表里反查出一个错误下限，
      // 压掉本该可用的档位（且用户只看到"音质被降了"，没有任何线索）。
      // 代价：跨平台时可能多试 1–2 个更低档，这正是要求的方向（宁可按偏好重选）。
      final carriesFallback = stopCurrent &&
          _currentQuality != null &&
          _currentQualityPlatform != null &&
          _currentQualityPlatform == _platformOf(index);
      final actual = await _remoteController.play(
        index,
        requestedQuality: requestedQuality,
        fallbackQuality: carriesFallback ? _currentQuality : null,
      );
      _applyResolvedQuality(
        requestedQuality,
        actual,
        platform: _platformOf(index),
      );
    } catch (_) {
      if (!_disposed && revision == _revision) {
        _setControlState(
          const RemotePlaybackControlSnapshot(
            state: PlaybackBackendState.failed,
            controlInFlight: false,
          ),
        );
      }
      rethrow;
    }
    if (!_disposed && revision == _revision) {
      _activeRemoteRevision = revision;
    }
  }

  void _onBackendState(PlaybackBackendState state) {
    if (_disposed || !_sessionStarted) return;
    if (_stopTransitionRevision != null) return;
    _setControlState(
      RemotePlaybackControlSnapshot(
        state: state,
        controlInFlight: _controlState.controlInFlight,
      ),
    );
    if (state != PlaybackBackendState.completed) return;
    final revision = _activeRemoteRevision;
    if (revision == null) return;
    _activeRemoteRevision = null;
    unawaited(_handleCompleted(revision));
  }

  void _onLocalPlaybackRequested() {
    if (_disposed || !_sessionStarted) return;
    ++_revision;
    _remoteController.cancel();
    _endSession();
    unawaited(_stopRemoteSafely());
  }

  Future<void> _stopRemoteSafely() async {
    try {
      await _backend.stop();
    } catch (_) {
      if (!_disposed) {
        _onFailure?.call(RemotePlaybackSessionFailure.remoteStop);
      }
    }
  }

  bool _control({
    required PlaybackBackendState expectedState,
    required Future<void> Function() action,
  }) {
    if (_disposed || !_sessionStarted) return false;
    if (_controlState.controlInFlight || _controlState.state != expectedState) {
      return true;
    }
    final controlRevision = ++_controlRevision;
    _setControlState(
      RemotePlaybackControlSnapshot(
        state: _controlState.state,
        controlInFlight: true,
      ),
    );
    unawaited(_runControl(controlRevision, action));
    return true;
  }

  Future<void> _runControl(
    int controlRevision,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (_isCurrentControl(controlRevision)) {
        _onFailure?.call(RemotePlaybackSessionFailure.control);
      }
    } finally {
      if (_isCurrentControl(controlRevision)) {
        _setControlState(
          RemotePlaybackControlSnapshot(
            state: _controlState.state,
            controlInFlight: false,
          ),
        );
      }
    }
  }

  bool _isCurrentControl(int controlRevision) =>
      !_disposed && _sessionStarted && controlRevision == _controlRevision;

  Future<void> _handleCompleted(int revision) async {
    if (_disposed || revision != _revision) return;
    final snapshot = _queue.value;
    final currentIndex = snapshot.currentIndex;
    final requestedQuality = _requestedQuality;
    if (currentIndex == null || requestedQuality == null) return;

    // 单曲循环：重新解析当前曲目，不复用可能过期的 URL。
    if (snapshot.mode == RemotePlaybackMode.repeatOne) {
      final nextRevision = _revision + 1;
      try {
        await _playRemote(currentIndex, requestedQuality: requestedQuality);
      } catch (error) {
        if (error is! _RemoteTransitionStopException &&
            !_disposed &&
            _revision == nextRevision) {
          _onFailure?.call(RemotePlaybackSessionFailure.nextTrack);
        }
      }
      return;
    }

    if (currentIndex + 1 < snapshot.items.length) {
      final nextRevision = _revision + 1;
      try {
        await _playRemote(currentIndex + 1, requestedQuality: requestedQuality);
      } catch (error) {
        if (error is! _RemoteTransitionStopException &&
            !_disposed &&
            _revision == nextRevision) {
          _onFailure?.call(RemotePlaybackSessionFailure.nextTrack);
        }
      }
      return;
    }

    // 列表循环：播完最后一首回到实际播放顺序的第一首，不结束远程会话、不恢复本地。
    if (snapshot.mode == RemotePlaybackMode.loop) {
      final nextRevision = _revision + 1;
      try {
        await _playRemote(0, requestedQuality: requestedQuality);
      } catch (error) {
        if (error is! _RemoteTransitionStopException &&
            !_disposed &&
            _revision == nextRevision) {
          _onFailure?.call(RemotePlaybackSessionFailure.nextTrack);
        }
      }
      return;
    }

    ++_revision;
    final resumePoint = _localResumePoint;
    _endSession();
    if (resumePoint == null) return;
    try {
      _localBridge.restore(resumePoint);
    } catch (_) {
      try {
        _localBridge.pause();
      } catch (_) {}
      if (!_disposed) {
        _onFailure?.call(RemotePlaybackSessionFailure.localRestore);
      }
    }
  }

  void _endSession() {
    _invalidateControl();
    _sessionStarted = false;
    _localResumePoint = null;
    _requestedQuality = null;
    _currentQuality = null;
    // P-57：平台也要一起清 —— 否则下次会话开始时可能拿上一段会话的平台去判等。
    _currentQualityPlatform = null;
    _activeRemoteRevision = null;
    _stopTransitionRevision = null;
    _setControlState(RemotePlaybackControlSnapshot.inactive);
  }

  bool _ignoresRepeatedSelection(int index) {
    if (!_sessionStarted || _queue.value.currentIndex != index) return false;
    return switch (_controlState.state) {
      PlaybackBackendState.opening ||
      PlaybackBackendState.playing ||
      PlaybackBackendState.paused ||
      PlaybackBackendState.stalled ||
      PlaybackBackendState.completed => true,
      _ => false,
    };
  }

  void _invalidateControl() {
    ++_controlRevision;
    if (_controlState.controlInFlight) {
      _setControlState(
        RemotePlaybackControlSnapshot(
          state: _controlState.state,
          controlInFlight: false,
        ),
      );
    }
  }

  void _setControlState(RemotePlaybackControlSnapshot state) {
    if (_controlState.state == state.state &&
        _controlState.controlInFlight == state.controlInFlight) {
      return;
    }
    _controlState = state;
    if (!_controlStateController.isClosed) {
      _controlStateController.add(state);
    }
  }

  void dispose() {
    if (_disposed) return;
    _localBridge.removeLocalPlaybackRequestListener(_onLocalPlaybackRequested);
    ++_revision;
    _endSession();
    _disposed = true;
    unawaited(
      _backendStateSubscription.cancel().whenComplete(
        _controlStateController.close,
      ),
    );
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('RemotePlaybackSessionController has been disposed');
    }
  }
}

final class _RemoteTransitionStopException implements Exception {
  const _RemoteTransitionStopException();
}
