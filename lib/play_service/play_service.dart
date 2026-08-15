import 'dart:async';

import 'package:pure_music/core/cache.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/core/matcher.dart' hide logger;
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/core/theme.dart';
import 'package:pure_music/core/system_volume_service.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/page/now_playing_page/component/lyric_view_controls.dart';
import 'package:pure_music/play_service/audio_echo_log_recorder.dart';
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

final class RemotePlaybackControlBinding {
  final _stateController =
      StreamController<RemotePlaybackControlState>.broadcast();
  static const _inactive = _InactiveRemotePlaybackControlState();
  RemotePlaybackControlState _state = _inactive;
  StreamSubscription<RemotePlaybackControlState>? _stateSubscription;
  bool Function()? _pauseHandler;
  bool Function()? _resumeHandler;
  int _revision = 0;
  bool _disposed = false;

  RemotePlaybackControlState get state => _state;
  Stream<RemotePlaybackControlState> get stateStream => _stateController.stream;
  bool get canSeekFromUi => !_state.isActive;

  void bind({
    required RemotePlaybackControlState initialState,
    required Stream<RemotePlaybackControlState> stateStream,
    required bool Function() pause,
    required bool Function() resume,
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
    _setState(initialState);
    _stateSubscription = stateStream.listen((state) {
      if (!_disposed && revision == _revision) {
        _setState(state);
      }
    });
  }

  bool pause() {
    if (!_state.isActive) return false;
    if (_state.controlInFlight ||
        _state.state != PlaybackBackendState.playing) {
      return true;
    }
    _pauseHandler?.call();
    return true;
  }

  bool resume() {
    if (!_state.isActive) return false;
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
  PlaybackService? _playbackService;
  LyricService? _lyricService;
  DesktopLyricService? _desktopLyricService;
  SmtcSessionOwner? _smtcSessionOwner;
  bool _smtcKeepAliveRequested = false;
  final Set<void Function()> _localPlaybackRequestListeners = {};
  bool Function()? _remotePreviousHandler;
  bool Function()? _remoteNextHandler;
  final RemotePlaybackControlBinding _remotePlaybackControls =
      RemotePlaybackControlBinding();

  PlaybackService get playbackService =>
      _playbackService ??= PlaybackService(this);
  LyricService get lyricService => _lyricService ??= LyricService(this);
  DesktopLyricService get desktopLyricService =>
      _desktopLyricService ??= DesktopLyricService(this);
  SmtcSessionOwner get _sharedSmtcSession {
    final existing = _smtcSessionOwner;
    if (existing != null) return existing;
    final created = SmtcSessionOwner.create();
    _smtcSessionOwner = created;
    if (_smtcKeepAliveRequested) {
      created.startKeepAlive();
    }
    return created;
  }

  SmtcBridge get smtcBridge => _sharedSmtcSession.bridge;

  PlayService._();

  static PlayService? _instance;
  static PlayService get instance {
    _instance ??= PlayService._();
    return _instance!;
  }

  bool get hasPlaybackSession => _playbackService?.nowPlaying != null;
  RemotePlaybackControlState get remotePlaybackControlState =>
      _remotePlaybackControls.state;
  Stream<RemotePlaybackControlState> get remotePlaybackControlStateStream =>
      _remotePlaybackControls.stateStream;
  bool get canSeekFromUi => _remotePlaybackControls.canSeekFromUi;

  void bindSmtcKeepAlive(void Function() handler) {
    _sharedSmtcSession.bindKeepAlive(handler);
  }

  void clearSmtcKeepAlive(void Function() handler) {
    _smtcSessionOwner?.clearKeepAlive(handler);
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
    required bool Function() pause,
    required bool Function() resume,
  }) {
    _remotePlaybackControls.bind(
      initialState: initialState,
      stateStream: stateStream,
      pause: pause,
      resume: resume,
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

  bool seekFromUi(double seconds) {
    return _remotePlaybackControls.seekFromUi(
      () => playbackService.seek(seconds),
    );
  }

  Future<void> close() async {
    stopSmtcKeepAlive();
    _localPlaybackRequestListeners.clear();
    clearRemoteNavigationHandlers();
    await _remotePlaybackControls.dispose();
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

    final playback = _playbackService;
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
