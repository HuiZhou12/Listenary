import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/component/hotkey_ui_feedback.dart';
import 'package:pure_music/core/hotkey_focus_state.dart';
import 'package:pure_music/core/immersive.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

enum PlaybackControlAction { none, pause, play, replay }

final class PlaybackControlPresentation {
  const PlaybackControlPresentation({
    required this.hasSession,
    required this.canToggle,
    required this.isPlaying,
    required this.action,
  });

  final bool hasSession;
  final bool canToggle;
  final bool isPlaying;
  final PlaybackControlAction action;
}

PlaybackControlPresentation resolvePlaybackControlPresentation({
  required RemotePlaybackControlState remoteState,
  required PlayerState localState,
  required bool hasLocalSession,
}) {
  if (remoteState.isActive) {
    final action = switch (remoteState.state) {
      PlaybackBackendState.playing when !remoteState.controlInFlight =>
        PlaybackControlAction.pause,
      PlaybackBackendState.paused when !remoteState.controlInFlight =>
        PlaybackControlAction.play,
      _ => PlaybackControlAction.none,
    };
    return PlaybackControlPresentation(
      hasSession: true,
      canToggle: action != PlaybackControlAction.none,
      isPlaying: remoteState.state == PlaybackBackendState.playing,
      action: action,
    );
  }

  final action = !hasLocalSession
      ? PlaybackControlAction.none
      : switch (localState) {
          PlayerState.playing => PlaybackControlAction.pause,
          PlayerState.completed => PlaybackControlAction.replay,
          _ => PlaybackControlAction.play,
        };
  return PlaybackControlPresentation(
    hasSession: hasLocalSession,
    canToggle: action != PlaybackControlAction.none,
    isPlaying: localState == PlayerState.playing,
    action: action,
  );
}

class HotkeysHelper {
  static bool _registered = false;
  static bool _windowToggleInProgress = false;

  static bool _canHandlePlaybackHotkey() => canHandleInAppPlaybackHotkey(
        textInputFocused: isTextInputFocusedForHotkeys(),
      );

  static PlaybackControlAction togglePlayback([PlayService? target]) {
    final playService = target ?? PlayService.instance;
    final remoteState = playService.remotePlaybackControlState;
    final presentation = resolvePlaybackControlPresentation(
      remoteState: remoteState,
      localState: remoteState.isActive
          ? PlayerState.stopped
          : playService.playbackService.playerState,
      hasLocalSession: remoteState.isActive
          ? false
          : playService.hasPlaybackSession,
    );
    switch (presentation.action) {
      case PlaybackControlAction.pause:
        playService.pauseAudio();
      case PlaybackControlAction.play:
      case PlaybackControlAction.replay:
        playService.playAudio();
      case PlaybackControlAction.none:
        return PlaybackControlAction.none;
    }
    return presentation.action;
  }

  static final Map<HotKey, void Function(HotKey)> _hotKeys = {
    HotKey(key: PhysicalKeyboardKey.space, scope: HotKeyScope.inapp): (_) {
      if (!_canHandlePlaybackHotkey()) return;

      switch (togglePlayback()) {
        case PlaybackControlAction.pause:
          showHotkeyToast(text: '暂停', icon: Icons.pause);
        case PlaybackControlAction.play:
          showHotkeyToast(text: '播放', icon: Icons.play_arrow);
        case PlaybackControlAction.replay:
          showHotkeyToast(text: '重播', icon: Icons.replay);
        case PlaybackControlAction.none:
          break;
      }
    },
    HotKey(key: PhysicalKeyboardKey.escape, scope: HotKeyScope.inapp):
        (_) async {
      final routerContext = routerKey.currentContext;
      if (routerContext == null) return;

      final router = GoRouter.of(routerContext);
      if (ImmersiveModeController.instance.enabled) {
        await ImmersiveModeController.instance.exit();
        final startIndex = AppPreference.instance.startPage
            .clamp(0, app_paths.START_PAGES.length - 1);
        router.go(app_paths.START_PAGES[startIndex]);
        return;
      }

      // 先关闭弹窗，再返回上一级页面
      final navigator = Navigator.maybeOf(routerContext);
      if (navigator?.canPop() == true) {
        navigator?.pop();
      } else if (routerKey.currentContext?.canPop() == true) {
        routerKey.currentContext?.pop();
      }
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowLeft,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      if (!_canHandlePlaybackHotkey()) return;
      PlayService.instance.previousAudio();
      hotkeyUiFeedback.emit(HotkeyUiAction.prev);
      showHotkeyToast(text: '上一曲', icon: Icons.skip_previous);
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowRight,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      if (!_canHandlePlaybackHotkey()) return;
      PlayService.instance.nextAudio();
      hotkeyUiFeedback.emit(HotkeyUiAction.next);
      showHotkeyToast(text: '下一曲', icon: Icons.skip_next);
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowUp,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      if (!_canHandlePlaybackHotkey()) return;
      final playbackService = PlayService.instance.playbackService;
      final next = (playbackService.volumeDsp + 0.05).clamp(0.0, 1.0);
      playbackService.setVolumeDsp(next);
      hotkeyUiFeedback.emit(HotkeyUiAction.volumeStep);
      showHotkeyToast(
        text: '应用音量：${(next * 100).round()}%',
        icon: Icons.volume_up,
      );
    },
    HotKey(
      key: PhysicalKeyboardKey.arrowDown,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ): (_) {
      if (!_canHandlePlaybackHotkey()) return;
      final playbackService = PlayService.instance.playbackService;
      final next = (playbackService.volumeDsp - 0.05).clamp(0.0, 1.0);
      playbackService.setVolumeDsp(next);
      hotkeyUiFeedback.emit(HotkeyUiAction.volumeStep);
      showHotkeyToast(
        text: '应用音量：${(next * 100).round()}%',
        icon: Icons.volume_down,
      );
    },
    HotKey(key: PhysicalKeyboardKey.f1, scope: HotKeyScope.inapp): (_) async {
      if (!_canHandlePlaybackHotkey()) return;
      await ImmersiveModeController.instance.toggle();
      showHotkeyToast(
        text: "沉浸：${ImmersiveModeController.instance.enabled ? "开" : "关"}",
        icon: Icons.fullscreen,
      );
    },
    HotKey(key: PhysicalKeyboardKey.f11, scope: HotKeyScope.inapp): (_) async {
      if (_windowToggleInProgress) return;
      _windowToggleInProgress = true;
      try {
        final isMaximized = await windowManager.isMaximized();
        if (isMaximized) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
        showHotkeyToast(
          text: isMaximized ? '还原窗口' : '最大化窗口',
          icon: isMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
        );
      } catch (err, trace) {
        logger.e('F11 窗口切换失败', error: err, stackTrace: trace);
      } finally {
        _windowToggleInProgress = false;
      }
    },
  };

  static void registerHotKeys() {
    if (_registered) return;
    for (var item in _hotKeys.entries) {
      hotKeyManager.register(
        item.key,
        keyDownHandler: item.value,
      );
    }
    _registered = true;
  }

  static Future<void> unregisterAll() async {
    for (var item in _hotKeys.keys) {
      await hotKeyManager.unregister(item);
    }
    _registered = false;
  }

  static Future<void> onFocusChanges(bool focus) async {
    if (focus) {
      await unregisterAll();
    } else {
      registerHotKeys();
    }
  }
}
