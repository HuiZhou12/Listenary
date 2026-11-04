import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/system_volume_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
import 'package:pure_music/play_service/active_playback_volume.dart';
import 'package:pure_music/play_service/desktop_lyric_service.dart';
import 'package:pure_music/play_service/lyric_service.dart';
import 'package:pure_music/play_service/playback_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/smtc_bridge.dart';

abstract interface class RemotePlaybackControlState {
  PlaybackBackendState? get state;
  bool get controlInFlight;
  bool get isActive;
}

typedef PlaybackServiceCreatedListener<T> = void Function(T service);

final class PlaybackServiceHandoff<T> {
  PlaybackServiceHandoff({required T Function() create}) : _create = create;

  final T Function() _create;
  final Set<PlaybackServiceCreatedListener<T>> _listeners = {};
  T? _existing;

  T? get existing => _existing;

  T getOrCreate() {
    final existing = _existing;
    if (existing != null) return existing;

    final created = _create();
    _existing = created;
    for (final listener in List.of(_listeners)) {
      listener(created);
    }
    return created;
  }

  void addCreatedListener(PlaybackServiceCreatedListener<T> listener) {
    if (!_listeners.add(listener)) return;
    final existing = _existing;
    if (existing != null) {
      listener(existing);
    }
  }

  void removeCreatedListener(PlaybackServiceCreatedListener<T> listener) {
    _listeners.remove(listener);
  }

  void clearCreatedListeners() {
    _listeners.clear();
  }
}

final class _InactiveRemotePlaybackControlState
    implements RemotePlaybackControlState {
  const _InactiveRemotePlaybackControlState();

  @override
  PlaybackBackendState? get state => null;

  @override
  bool get controlInFlight => false;

  @override
  bool get isActive => false;
}

/// 远程激活时**进度条**是否可跳（与歌词行点击门禁 [RemotePlaybackControlBinding.canSeekFromUi] 分开）。
///
/// 注意：本地场景（`!state.isActive`）刻意返回 `true`（进度条本地当然可跳）。
/// 因此**在线歌词行**的门禁不能只用本函数，见
/// [RemotePlaybackControlBinding.canSeekLyricLineFromUi]（显式叠加了 `isActive`）。
///
/// 抽成顶层纯函数：绑定层用它算快照，UI 用同一个规则直接由收到的状态求值，
/// 避免 UI 依赖"监听器注册顺序"这种隐式前提。
bool remoteProgressSeekAllowed(RemotePlaybackControlState state) {
  if (!state.isActive) return true;
  if (state.controlInFlight) return false;
  return switch (state.state) {
    PlaybackBackendState.playing ||
    PlaybackBackendState.paused ||
    PlaybackBackendState.stalled ||
    PlaybackBackendState.completed => true,
    PlaybackBackendState.opening ||
    PlaybackBackendState.stopped ||
    PlaybackBackendState.failed ||
    null => false,
  };
}

final class RemotePlaybackControlBinding {
  final _stateController =
      StreamController<RemotePlaybackControlState>.broadcast();
  static const _inactive = _InactiveRemotePlaybackControlState();
  RemotePlaybackControlState _state = _inactive;
  StreamSubscription<RemotePlaybackControlState>? _stateSubscription;
  bool Function()? _pauseHandler;
  bool Function()? _resumeHandler;
  Future<bool> Function(Duration position)? _seekHandler;
  bool Function()? _isActiveReader;
  int _revision = 0;
  bool _disposed = false;

  RemotePlaybackControlState get state => _state;
  Stream<RemotePlaybackControlState> get stateStream => _stateController.stream;
  bool get isActive => _isActiveReader?.call() ?? _state.isActive;

  /// **本地歌词行点击**的门禁：远程激活时保持关闭。
  ///
  /// 消费方是本地歌词视图（`vertical_lyric_view.dart`）与同步入口 [seekFromUi]。
  /// 在线歌词行点击**不读这里**，它有自己的门禁 [canSeekLyricLineFromUi]：
  /// 两者共用开关会让本地链路跟着远程行为一起变，而本地仍应保持原有语义。
  bool get canSeekFromUi => !isActive;

  /// **进度条**的门禁：远程激活时，只要流确实可跳就放开。
  ///
  /// 与 [canSeekFromUi] 分开是有意的：两者共用一个开关会把"点歌词行跳转"
  /// 顺带解锁（歌词组件未改一行代码也会跟着变行为）。
  bool get canSeekProgressFromUi => remoteProgressSeekAllowed(_state);

  /// **在线歌词行点击**的门禁（新增的第三个门禁，不复用前两个）。
  ///
  /// 与 [canSeekProgressFromUi] 的差别只在**是否远程会话**这一层：
  /// [remoteProgressSeekAllowed] 在本地场景刻意返回 `true`（进度条本地当然可跳），
  /// 若本门禁只写它，本地也会被判为可点 —— 而本地歌词行点击的判定源是
  /// [canSeekFromUi]（`vertical_lyric_view.dart` 读的那个），两者会分裂成双重标准。
  /// 因此这里显式叠加 [isActive]：只有远程会话才走本门禁。
  bool get canSeekLyricLineFromUi =>
      isActive && remoteProgressSeekAllowed(_state);

  void bind({
    required RemotePlaybackControlState initialState,
    required Stream<RemotePlaybackControlState> stateStream,
    required bool Function() isActive,
    required bool Function() pause,
    required bool Function() resume,
    Future<bool> Function(Duration position)? seek,
  }) {
    if (_disposed) {
      throw StateError('RemotePlaybackControlBinding has been disposed');
    }
    final revision = ++_revision;
    final oldSubscription = _stateSubscription;
    _stateSubscription = null;
    if (oldSubscription != null) {
      unawaited(oldSubscription.cancel());
    }
    _pauseHandler = pause;
    _resumeHandler = resume;
    _seekHandler = seek;
    _isActiveReader = isActive;
    _setState(initialState);
    _stateSubscription = stateStream.listen((state) {
      if (!_disposed && revision == _revision) {
        _setState(state);
      }
    });
  }

  bool pause() {
    if (!isActive) return false;
    if (_state.controlInFlight ||
        _state.state != PlaybackBackendState.playing) {
      return true;
    }
    _pauseHandler?.call();
    return true;
  }

  bool resume() {
    if (!isActive) return false;
    if (_state.controlInFlight || _state.state != PlaybackBackendState.paused) {
      return true;
    }
    _resumeHandler?.call();
    return true;
  }

  bool seekFromUi(void Function() seek) {
    if (!canSeekFromUi) return false;
    seek();
    return true;
  }

  /// 远程进度跳转（异步、失败返回 false，不抛异常）。
  ///
  /// 没绑定 handler（组合根未装配）时返回 false，让 UI 走"失败提示+回滚"。
  Future<bool> seekRemoteProgress(double seconds) async {
    final handler = _seekHandler;
    if (handler == null) return false;
    try {
      return await handler(
        Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()),
      );
    } catch (_) {
      return false;
    }
  }

  /// **在线歌词行**的跳转入口：门禁 [canSeekLyricLineFromUi] 关时直接拒绝，
  /// 否则完全复用 [seekRemoteProgress] 的路由与静默失败语义。
  ///
  /// 只服务远程：本入口不碰本地播放器（本地歌词行继续走同步的 `seekFromUi`）。
  Future<bool> seekLyricLine(double seconds) async {
    if (!canSeekLyricLineFromUi) return false;
    return seekRemoteProgress(seconds);
  }

  void clear() {
    if (_disposed) return;
    _clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_revision;
    _pauseHandler = null;
    _resumeHandler = null;
    _seekHandler = null;
    _isActiveReader = null;
    final subscription = _stateSubscription;
    _stateSubscription = null;
    _setState(_inactive);
    await subscription?.cancel();
    await _stateController.close();
  }

  void _clear() {
    ++_revision;
    _pauseHandler = null;
    _resumeHandler = null;
    _seekHandler = null;
    _isActiveReader = null;
    final subscription = _stateSubscription;
    _stateSubscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    _setState(_inactive);
  }

  void _setState(RemotePlaybackControlState state) {
    if (_state.state == state.state &&
        _state.controlInFlight == state.controlInFlight) {
      return;
    }
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}

class PlayService {
  late final PlaybackServiceHandoff<PlaybackService> _playbackServiceHandoff;
  LyricService? _lyricService;
  DesktopLyricService? _desktopLyricService;
  final Set<PlaybackServiceCreatedListener<DesktopLyricService>>
  _desktopLyricServiceCreatedListeners = {};
  SmtcSessionOwner? _smtcSessionOwner;
  bool _smtcKeepAliveRequested = false;
  void Function()? _remoteSmtcKeepAlivePublisher;
  final Set<void Function()> _localPlaybackRequestListeners = {};
  bool Function()? _remotePreviousHandler;
  bool Function()? _remoteNextHandler;
  final RemotePlaybackControlBinding _remotePlaybackControls =
      RemotePlaybackControlBinding();
  late final SmtcControlRouter _smtcControlRouter;
  late final ActivePlaybackVolumeRouter<PlaybackService> _activeVolume;

  PlaybackService get playbackService => _playbackServiceHandoff.getOrCreate();
  PlaybackService? get existingPlaybackService =>
      _playbackServiceHandoff.existing;
  LyricService get lyricService => _lyricService ??= LyricService(this);
  DesktopLyricService get desktopLyricService {
    final existing = _desktopLyricService;
    if (existing != null) return existing;
    final created = DesktopLyricService(
      this,
      localProjectionSuppressed: _remotePlaybackControls.isActive,
    );
    _desktopLyricService = created;
    for (final listener in List.of(_desktopLyricServiceCreatedListeners)) {
      listener(created);
    }
    return created;
  }
  DesktopLyricService? get existingDesktopLyricService => _desktopLyricService;
  SmtcSessionOwner get _sharedSmtcSession {
    final existing = _smtcSessionOwner;
    if (existing != null) return existing;
    final created = SmtcSessionOwner.create();
    created.bindControlRouter(_smtcControlRouter);
    final remotePublisher = _remoteSmtcKeepAlivePublisher;
    if (remotePublisher != null) {
      created.bindRemoteKeepAlive(remotePublisher);
    }
    _smtcSessionOwner = created;
    if (_smtcKeepAliveRequested) {
      created.startKeepAlive();
    }
    return created;
  }

  SmtcBridge get smtcBridge => _sharedSmtcSession.bridge;

  PlayService._() {
    _playbackServiceHandoff = PlaybackServiceHandoff(
      create: () => PlaybackService(this),
    );
    _smtcControlRouter = SmtcControlRouter(
      isRemoteActive: () => _remotePlaybackControls.isActive,
      remotePlay: playAudio,
      remotePause: pauseAudio,
      remotePrevious: previousAudio,
      remoteNext: nextAudio,
      localPlay: () => existingPlaybackService?.start(),
      localPause: () => existingPlaybackService?.pause(),
      localPrevious: () => existingPlaybackService?.lastAudio(),
      localNext: () => existingPlaybackService?.nextAudio(),
      localStop: _stopLocalFromSmtc,
      localPosition: _seekLocalFromSmtc,
    );
    _activeVolume = ActivePlaybackVolumeRouter<PlaybackService>(
      initialVolume: AppPreference.instance.playbackPref.volumeDsp,
      isRemoteActive: () => _remotePlaybackControls.isActive,
      hasLocalSession: () => hasPlaybackSession,
      localTarget: () => existingPlaybackService,
      setLocalVolume: (service, volume) => service.setVolumeDsp(volume),
      persistRemoteVolume: (volume) {
        AppPreference.instance.playbackPref.volumeDsp = volume;
        unawaited(AppPreference.instance.savePlaybackOnly());
      },
    );
  }

  static PlayService? _instance;
  static PlayService get instance {
    _instance ??= PlayService._();
    return _instance!;
  }

  bool get hasPlaybackSession => existingPlaybackService?.nowPlaying != null;
  RemotePlaybackControlState get remotePlaybackControlState =>
      _remotePlaybackControls.state;
  Stream<RemotePlaybackControlState> get remotePlaybackControlStateStream =>
      _remotePlaybackControls.stateStream;
  bool get canSeekFromUi => _remotePlaybackControls.canSeekFromUi;

  /// 进度条可跳：远程激活时也放开（见 [RemotePlaybackControlBinding.canSeekProgressFromUi]）。
  bool get canSeekProgressFromUi =>
      _remotePlaybackControls.canSeekProgressFromUi;

  /// **在线歌词行**可跳：仅远程激活且流可跳时为真（见
  /// [RemotePlaybackControlBinding.canSeekLyricLineFromUi]）。
  ///
  /// 视图在构建期读它决定 `onTap` 是否为 null；点击时 [seekLyricLineFromUi]
  /// 会再判一次，避免门禁在两次读取之间变化后仍然提交。
  bool get canSeekLyricLineFromUi =>
      _remotePlaybackControls.canSeekLyricLineFromUi;

  ValueListenable<double> get activeVolumeDsp => _activeVolume;
  bool get canSetActiveVolume => _activeVolume.canSetVolume;

  bool setActiveVolumeDsp(double volume) => _activeVolume.setVolume(volume);

  void bindRemoteVolume(ActiveVolumeSetter setter) {
    _activeVolume.bindRemote(setter);
  }

  void clearRemoteVolume() {
    _activeVolume.clearRemote();
  }

  void bindSmtcKeepAlive(void Function() handler) {
    _sharedSmtcSession.bindLocalKeepAlive(handler);
  }

  void clearSmtcKeepAlive(void Function() handler) {
    _smtcSessionOwner?.clearLocalKeepAlive(handler);
  }

  void bindRemoteSmtcKeepAlive(void Function() publisher) {
    final oldPublisher = _remoteSmtcKeepAlivePublisher;
    if (identical(oldPublisher, publisher)) return;
    if (oldPublisher != null) {
      _smtcSessionOwner?.clearRemoteKeepAlive(oldPublisher);
    }
    _remoteSmtcKeepAlivePublisher = publisher;
    _smtcSessionOwner?.bindRemoteKeepAlive(publisher);
  }

  void clearRemoteSmtcKeepAlive(void Function() publisher) {
    if (!identical(_remoteSmtcKeepAlivePublisher, publisher)) return;
    _smtcSessionOwner?.clearRemoteKeepAlive(publisher);
    _remoteSmtcKeepAlivePublisher = null;
  }

  void startSmtcKeepAlive() {
    _smtcKeepAliveRequested = true;
    _smtcSessionOwner?.startKeepAlive();
  }

  void stopSmtcKeepAlive() {
    _smtcKeepAliveRequested = false;
    _smtcSessionOwner?.stopKeepAlive();
  }

  void addLocalPlaybackRequestListener(void Function() listener) {
    _localPlaybackRequestListeners.add(listener);
  }

  void removeLocalPlaybackRequestListener(void Function() listener) {
    _localPlaybackRequestListeners.remove(listener);
  }

  void notifyLocalPlaybackRequested() {
    for (final listener in List.of(_localPlaybackRequestListeners)) {
      listener();
    }
  }

  void addPlaybackServiceCreatedListener(
    PlaybackServiceCreatedListener<PlaybackService> listener,
  ) {
    _playbackServiceHandoff.addCreatedListener(listener);
  }

  void removePlaybackServiceCreatedListener(
    PlaybackServiceCreatedListener<PlaybackService> listener,
  ) {
    _playbackServiceHandoff.removeCreatedListener(listener);
  }

  void addDesktopLyricServiceCreatedListener(
    PlaybackServiceCreatedListener<DesktopLyricService> listener,
  ) {
    if (!_desktopLyricServiceCreatedListeners.add(listener)) return;
    final existing = _desktopLyricService;
    if (existing != null) listener(existing);
  }

  void removeDesktopLyricServiceCreatedListener(
    PlaybackServiceCreatedListener<DesktopLyricService> listener,
  ) {
    _desktopLyricServiceCreatedListeners.remove(listener);
  }

  void setRemoteNavigationHandlers({
    required bool Function() previous,
    required bool Function() next,
  }) {
    _remotePreviousHandler = previous;
    _remoteNextHandler = next;
  }

  void clearRemoteNavigationHandlers() {
    _remotePreviousHandler = null;
    _remoteNextHandler = null;
  }

  void setRemotePlaybackControlHandlers({
    required RemotePlaybackControlState initialState,
    required Stream<RemotePlaybackControlState> stateStream,
    required bool Function() isActive,
    required bool Function() pause,
    required bool Function() resume,
    Future<bool> Function(Duration position)? seek,
  }) {
    _remotePlaybackControls.bind(
      initialState: initialState,
      stateStream: stateStream,
      isActive: isActive,
      pause: pause,
      resume: resume,
      seek: seek,
    );
  }

  void clearRemotePlaybackControlHandlers() {
    _remotePlaybackControls.clear();
  }

  void previousAudio() {
    if (_remotePreviousHandler?.call() == true) return;
    playbackService.lastAudio();
  }

  void nextAudio() {
    if (_remoteNextHandler?.call() == true) return;
    playbackService.nextAudio();
  }

  void pauseAudio() {
    if (_remotePlaybackControls.pause()) return;
    playbackService.pause();
  }

  void playAudio() {
    if (_remotePlaybackControls.resume()) return;
    final service = playbackService;
    if (service.playerState == PlayerState.completed) {
      service.playAgain();
    } else {
      service.start();
    }
  }

  /// **本地歌词行点击**路径（保持同步 bool 语义，远程激活时仍被拒绝）。
  ///
  /// 在线歌词行**不走这里**（远程激活时本入口恒为 false）：它走异步的
  /// [seekLyricLineFromUi]，因为远程跳转必须能报告失败供 UI 提示与回滚。
  bool seekFromUi(double seconds) {
    return _remotePlaybackControls.seekFromUi(
      () => playbackService.seek(seconds),
    );
  }

  /// **进度条**路径：远程激活时路由到远程后端，本地时走本地播放器。
  ///
  /// 返回 false = 这次跳转没成功（UI 据此提示并回滚）；不抛异常。
  Future<bool> seekProgressFromUi(double seconds) async {
    if (!canSeekProgressFromUi) return false;
    if (_remotePlaybackControls.isActive) {
      return _remotePlaybackControls.seekRemoteProgress(seconds);
    }
    try {
      playbackService.seek(seconds);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// **在线歌词行点击**路径：只服务远程会话。
  ///
  /// 本地（非远程）时一律返回 false —— 本地歌词行点击继续走旧的同步
  /// [seekFromUi]（`vertical_lyric_view.dart` 那一侧），本入口不碰本地播放器，
  /// 因此本地链路零回归。
  Future<bool> seekLyricLineFromUi(double seconds) async {
    if (!_remotePlaybackControls.isActive) return false;
    return _remotePlaybackControls.seekLyricLine(seconds);
  }

  void _stopLocalFromSmtc() {
    final service = existingPlaybackService;
    if (service == null) return;
    service.pause();
    service.seek(0);
  }

  void _seekLocalFromSmtc(int position) {
    final service = existingPlaybackService;
    final audio = service?.nowPlaying;
    if (service == null || audio == null) return;
    final positionSeconds = (position / 1000).clamp(
      0.0,
      audio.duration.toDouble(),
    );
    service.seek(positionSeconds);
  }

  Future<void> close() async {
    stopSmtcKeepAlive();
    _localPlaybackRequestListeners.clear();
    _playbackServiceHandoff.clearCreatedListeners();
    _desktopLyricServiceCreatedListeners.clear();
    clearRemoteNavigationHandlers();
    final remotePublisher = _remoteSmtcKeepAlivePublisher;
    _remoteSmtcKeepAlivePublisher = null;
    if (remotePublisher != null) {
      _smtcSessionOwner?.clearRemoteKeepAlive(remotePublisher);
    }
    await _remotePlaybackControls.dispose();
    _activeVolume.dispose();
    // 按顺序关闭服务，每个操作带超时保护
    final desktopLyric = _desktopLyricService;
    if (desktopLyric != null) {
      try {
        await desktopLyric.killDesktopLyric().timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            logger.w('desktopLyricService.close timeout');
          },
        );
      } catch (e) {
        logger.w('desktopLyricService.close error: $e');
      }
    }

    // 停止音频回波日志记录
    try {
      await AudioEchoLogRecorder.instance.stop().timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          logger.w('AudioEchoLogRecorder.stop timeout');
        },
      );
    } catch (e) {
      logger.w('AudioEchoLogRecorder.stop error: $e');
    }

    LyricViewController.disposeIfInitialized();
    final lyric = _lyricService;
    if (lyric != null) {
      try {
        lyric.dispose();
      } catch (e) {
        logger.w('lyricService.dispose error: $e');
      }
    }

    final playback = existingPlaybackService;
    if (playback != null) {
      try {
        await playback.close().timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            logger.w('playbackService.close timeout');
          },
        );
      } catch (e) {
        logger.w('playbackService.close error: $e');
      }
    }

    final smtcSessionOwner = _smtcSessionOwner;
    _smtcSessionOwner = null;
    if (smtcSessionOwner != null) {
      try {
        smtcSessionOwner.clearControlRouter(_smtcControlRouter);
        await smtcSessionOwner.close().timeout(const Duration(seconds: 1));
      } catch (e) {
        logger.w('smtcSessionOwner.close error: $e');
      }
    }

    ThemeProvider.instance.dispose();
    SystemVolumeService.instance.dispose();
    AlbumColorCache.instance.dispose();
    CoverImageCache.instance.dispose();
    AudioLibrary.instance.dispose();
    AppDb.instance.dispose();
    AppSettings.closeGithub();
    clearLyricCaches();

    _instance = null;
  }
}
