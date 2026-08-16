import 'dart:async';
import 'dart:typed_data';

import 'package:pure_music/component/rectangle_progress_indicator.dart';
import 'package:pure_music/component/responsive_builder.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/core/hotkeys.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/native/bass/bass_player.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

final class MiniNowPlayingMetadataProjection {
  const MiniNowPlayingMetadataProjection({
    required this.title,
    required this.subtitle,
    required this.usesLocalMedia,
  });

  final String title;
  final String subtitle;
  final bool usesLocalMedia;
}

bool miniNowPlayingUsesLocalMedia(ActivePlaybackSessionSnapshot snapshot) =>
    snapshot.source != ActivePlaybackSessionSource.remote;

MiniNowPlayingMetadataProjection resolveMiniNowPlayingMetadata({
  required ActivePlaybackSessionSnapshot snapshot,
  required String? localTitle,
  required String? localArtist,
  required String? localAlbum,
}) {
  if (!miniNowPlayingUsesLocalMedia(snapshot)) {
    final item = snapshot.currentItem;
    return MiniNowPlayingMetadataProjection(
      title: item?.title ?? 'Pure Music',
      subtitle: item?.artist ?? '享受音乐',
      usesLocalMedia: false,
    );
  }

  return MiniNowPlayingMetadataProjection(
    title: localTitle ?? 'Pure Music',
    subtitle: localTitle == null
        ? '享受音乐'
        : '${localArtist ?? ''} - ${localAlbum ?? ''}',
    usesLocalMedia: true,
  );
}

final class MiniNowPlayingControlProjection {
  const MiniNowPlayingControlProjection({
    required this.presentation,
    required this.canPrevious,
    required this.canNext,
  });

  final PlaybackControlPresentation presentation;
  final bool canPrevious;
  final bool canNext;
}

MiniNowPlayingControlProjection resolveMiniNowPlayingControls({
  required ActivePlaybackSessionSnapshot snapshot,
  required RemotePlaybackControlState remoteState,
  required PlayerState localState,
  required bool hasLocalSession,
}) {
  if (snapshot.source != ActivePlaybackSessionSource.remote) {
    final presentation = resolvePlaybackControlPresentation(
      remoteState: remoteState,
      localState: localState,
      hasLocalSession: hasLocalSession,
    );
    return MiniNowPlayingControlProjection(
      presentation: presentation,
      canPrevious: presentation.hasSession,
      canNext: presentation.hasSession,
    );
  }

  final capabilities = snapshot.capabilities;
  final action = snapshot.controlInFlight
      ? PlaybackControlAction.none
      : switch (snapshot.state) {
          ActivePlaybackSessionState.playing when capabilities.canPause =>
            PlaybackControlAction.pause,
          ActivePlaybackSessionState.paused when capabilities.canPlay =>
            PlaybackControlAction.play,
          _ => PlaybackControlAction.none,
        };
  return MiniNowPlayingControlProjection(
    presentation: PlaybackControlPresentation(
      hasSession: true,
      canToggle: action != PlaybackControlAction.none,
      isPlaying: snapshot.state == ActivePlaybackSessionState.playing,
      action: action,
    ),
    canPrevious: capabilities.canPrevious,
    canNext: capabilities.canNext,
  );
}

class MiniNowPlaying extends StatelessWidget {
  const MiniNowPlaying({super.key});

  @override
  Widget build(BuildContext context) {
    return ResponsiveBuilder(
      builder: (context, screenType) {
        final activeSnapshot = context.watch<ActivePlaybackSession>().value;
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              8.0,
              0,
              8.0,
              screenType == ScreenType.small ? 8.0 : 32.0,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600.0),
              child: SizedBox(
                height: 64.0,
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: AppRadius.smCircular,
                    boxShadow: kElevationToShadow[4],
                  ),
                  child: ClipRRect(
                    borderRadius: AppRadius.smCircular,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return RectangleProgressIndicator(
                          size: Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          ),
                          progressEnabled: miniNowPlayingUsesLocalMedia(
                            activeSnapshot,
                          ),
                          child: _NowPlayingForeground(
                            activeSnapshot: activeSnapshot,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NowPlayingForeground extends StatefulWidget {
  const _NowPlayingForeground({required this.activeSnapshot});

  final ActivePlaybackSessionSnapshot activeSnapshot;

  @override
  State<_NowPlayingForeground> createState() => _NowPlayingForegroundState();
}

class _NowPlayingForegroundState extends State<_NowPlayingForeground> {
  bool _hovered = false;
  bool _controlsVisible = false;
  Timer? _controlsHideTimer;

  void _setControlsVisible(bool visible) {
    if (_controlsVisible == visible) return;
    setState(() => _controlsVisible = visible);
  }

  void _scheduleHideControls() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      if (_hovered) return;
      _setControlsVisible(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return IconButtonTheme(
      data: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return scheme.onSecondaryContainer.withValues(alpha: Alpha.hover);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return scheme.onSecondaryContainer.withValues(alpha: 0.02);
            }
            return Colors.transparent;
          }),
        ),
      ),
      child: AnimatedContainer(
        duration: MotionDuration.fast,
        curve: MotionCurve.standard,
        decoration: BoxDecoration(
          color: _hovered
              ? scheme.onSecondaryContainer.withValues(alpha: 0.06)
              : null,
          borderRadius: AppRadius.smCircular,
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: AppRadius.smCircular,
          child: InkWell(
            onHover: (v) {
              _controlsHideTimer?.cancel();
              setState(() => _hovered = v);
              if (v) {
                _setControlsVisible(true);
              } else {
                _scheduleHideControls();
              }
            },
            onTap: () {
              context.push(app_paths.NOW_PLAYING_PAGE);
            },
            borderRadius: AppRadius.smCircular,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: StreamBuilder<RemotePlaybackControlState>(
                stream: PlayService.instance.remotePlaybackControlStateStream,
                initialData: PlayService.instance.remotePlaybackControlState,
                builder: (context, remoteSnapshot) {
                  final remoteState = remoteSnapshot.data!;
                  return ListenableBuilder(
                    listenable:
                        PlayService.instance.playbackService.nowPlayingNotifier,
                    builder: (context, _) {
                      final playbackService =
                          PlayService.instance.playbackService;
                      final nowPlaying = playbackService.nowPlaying;
                      final metadata = resolveMiniNowPlayingMetadata(
                        snapshot: widget.activeSnapshot,
                        localTitle: nowPlaying?.title,
                        localArtist: nowPlaying?.artist,
                        localAlbum: nowPlaying?.album,
                      );
                      final heroEnabled =
                          !playbackService.nowPlayingChangedRecently;
                      final placeholder = Icon(
                        Symbols.queue_music,
                        size: 48.0,
                        color: scheme.onSecondaryContainer,
                      );

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final dense = constraints.maxWidth <= 520;
                          final hideControls = !_controlsVisible;
                          final controlState = resolveMiniNowPlayingControls(
                            snapshot: widget.activeSnapshot,
                            remoteState: remoteState,
                            localState: playbackService.playerState,
                            hasLocalSession: nowPlaying != null,
                          );
                          final hasPlaybackSession =
                              controlState.presentation.hasSession;
                          final controls = Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!dense)
                                IconButton(
                                  tooltip: controlState.canPrevious
                                      ? '上一曲'
                                      : hasPlaybackSession
                                      ? '没有上一曲'
                                      : '暂无正在播放',
                                  onPressed: controlState.canPrevious
                                      ? PlayService.instance.previousAudio
                                      : null,
                                  icon: const Icon(
                                    Symbols.skip_previous,
                                    fill: 1.0,
                                    weight: 400.0,
                                  ),
                                  color: scheme.onSecondaryContainer,
                                ),
                              _MiniPlayPauseButton(
                                dense: dense,
                                onSecondaryContainer:
                                    scheme.onSecondaryContainer,
                                enabled: hasPlaybackSession,
                                remoteState: remoteState,
                                activeSnapshot: widget.activeSnapshot,
                              ),
                              if (!dense)
                                IconButton(
                                  tooltip: controlState.canNext
                                      ? '下一曲'
                                      : hasPlaybackSession
                                      ? '没有下一曲'
                                      : '暂无正在播放',
                                  onPressed: controlState.canNext
                                      ? PlayService.instance.nextAudio
                                      : null,
                                  icon: const Icon(
                                    Symbols.skip_next,
                                    fill: 1.0,
                                    weight: 400.0,
                                  ),
                                  color: scheme.onSecondaryContainer,
                                ),
                              if (!dense) const SizedBox(width: 8.0),
                              if (!dense && metadata.usesLocalMedia)
                                _MiniTimeText(
                                  color: scheme.onSecondaryContainer,
                                ),
                            ],
                          );
                          return Row(
                            children: [
                              metadata.usesLocalMedia && nowPlaying != null
                                  ? Builder(
                                      builder: (context) {
                                        final cover = ClipRRect(
                                          borderRadius: AppRadius.smCircular,
                                          child: SizedBox(
                                            width: 48.0,
                                            height: 48.0,
                                            child: _MiniCoverWidget(
                                              audio: nowPlaying,
                                            ),
                                          ),
                                        );
                                        if (!heroEnabled) return cover;
                                        return Hero(
                                          tag: nowPlaying.path,
                                          child: cover,
                                        );
                                      },
                                    )
                                  : SizedBox(
                                      width: 48.0,
                                      height: 48.0,
                                      child: Center(child: placeholder),
                                    ),
                              const SizedBox(width: 8.0),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      metadata.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: scheme.onSecondaryContainer,
                                      ),
                                    ),
                                    Text(
                                      metadata.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: scheme.onSecondaryContainer,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8.0),
                              IgnorePointer(
                                ignoring: hideControls,
                                child: AnimatedSlide(
                                  duration: MotionDuration.fast,
                                  curve: MotionCurve.standard,
                                  offset: hideControls
                                      ? const Offset(0.02, 0.0)
                                      : Offset.zero,
                                  child: AnimatedOpacity(
                                    duration: MotionDuration.fast,
                                    curve: MotionCurve.standard,
                                    opacity: hideControls ? 0.0 : 1.0,
                                    child: controls,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    super.dispose();
  }
}

class _MiniPlayPauseButton extends StatelessWidget {
  const _MiniPlayPauseButton({
    required this.dense,
    required this.onSecondaryContainer,
    required this.enabled,
    required this.remoteState,
    required this.activeSnapshot,
  });

  final bool dense;
  final Color onSecondaryContainer;
  final bool enabled;
  final RemotePlaybackControlState remoteState;
  final ActivePlaybackSessionSnapshot activeSnapshot;

  @override
  Widget build(BuildContext context) {
    final playbackService = PlayService.instance.playbackService;
    return _AnimatedPlayPauseIconButton(
      dense: dense,
      color: onSecondaryContainer,
      enabled: enabled,
      remoteState: remoteState,
      activeSnapshot: activeSnapshot,
      playerStateStream: playbackService.playerStateStream,
      initialState: playbackService.playerState,
    );
  }
}

class _AnimatedPlayPauseIconButton extends StatefulWidget {
  const _AnimatedPlayPauseIconButton({
    required this.dense,
    required this.color,
    required this.enabled,
    required this.remoteState,
    required this.activeSnapshot,
    required this.playerStateStream,
    required this.initialState,
  });

  final bool dense;
  final Color color;
  final bool enabled;
  final RemotePlaybackControlState remoteState;
  final ActivePlaybackSessionSnapshot activeSnapshot;
  final Stream<PlayerState> playerStateStream;
  final PlayerState initialState;

  @override
  State<_AnimatedPlayPauseIconButton> createState() =>
      _AnimatedPlayPauseIconButtonState();
}

class _AnimatedPlayPauseIconButtonState
    extends State<_AnimatedPlayPauseIconButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late PlayerState _localState = widget.initialState;
  StreamSubscription<PlayerState>? _playerStateSub;

  PlaybackControlPresentation get _presentation =>
      resolveMiniNowPlayingControls(
        snapshot: widget.activeSnapshot,
        remoteState: widget.remoteState,
        localState: _localState,
        hasLocalSession: widget.enabled,
      ).presentation;

  @override
  void initState() {
    super.initState();
    if (_presentation.isPlaying) {
      _controller.value = 1.0;
    } else {
      _controller.value = 0.0;
    }
    _bindPlayerStateStream();
  }

  void _bindPlayerStateStream() {
    _playerStateSub?.cancel();
    _playerStateSub = widget.playerStateStream.listen(_syncPlayerState);
  }

  void _syncPlayerState(PlayerState nextState) {
    if (!mounted || nextState == _localState) return;
    final wasPlaying = _presentation.isPlaying;
    setState(() {
      _localState = nextState;
    });
    if (wasPlaying == _presentation.isPlaying) return;
    _controller.animateTo(
      _presentation.isPlaying ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 240),
      curve: const Cubic(0.2, 0.0, 0.0, 1.0),
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedPlayPauseIconButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasPlaying = resolveMiniNowPlayingControls(
      snapshot: oldWidget.activeSnapshot,
      remoteState: oldWidget.remoteState,
      localState: _localState,
      hasLocalSession: oldWidget.enabled,
    ).presentation.isPlaying;
    if (oldWidget.playerStateStream != widget.playerStateStream) {
      _bindPlayerStateStream();
    }
    if (oldWidget.initialState != widget.initialState &&
        widget.initialState != _localState) {
      _localState = widget.initialState;
    }
    if (wasPlaying != _presentation.isPlaying) {
      _controller.animateTo(
        _presentation.isPlaying ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 240),
        curve: const Cubic(0.2, 0.0, 0.0, 1.0),
      );
    }
  }

  @override
  void dispose() {
    _playerStateSub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presentation = _presentation;
    final iconColor = presentation.canToggle
        ? widget.color
        : widget.color.withValues(alpha: 0.38);

    final icon = AnimatedIcon(
      icon: AnimatedIcons.play_pause,
      progress: _controller,
      color: iconColor,
      size: widget.dense ? 24.0 : 28.0,
    );

    return IconButton(
      tooltip: presentation.canToggle
          ? (presentation.isPlaying ? '暂停' : '播放')
          : presentation.hasSession
          ? '暂不可控制'
          : '暂无正在播放',
      onPressed: presentation.canToggle
          ? () {
              if (presentation.action == PlaybackControlAction.pause) {
                PlayService.instance.pauseAudio();
              } else {
                PlayService.instance.playAudio();
              }
            }
          : null,
      icon: icon,
      color: iconColor,
    );
  }
}

class _MiniTimeText extends StatefulWidget {
  const _MiniTimeText({required this.color});

  final Color color;

  @override
  State<_MiniTimeText> createState() => _MiniTimeTextState();
}

class _MiniTimeTextState extends State<_MiniTimeText> {
  final playbackService = PlayService.instance.playbackService;
  Timer? _positionTimer;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastNativeSyncMs = 0;
  int _syncedPositionSeconds = 0;
  late int _positionSeconds;
  late int _lengthSeconds;
  static const _nativeSyncInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _syncedPositionSeconds = playbackService.position.floor();
    _positionSeconds = _syncedPositionSeconds;
    _lengthSeconds = playbackService.length.floor();
    playbackService.playerStateNotifier.addListener(_syncTimer);
    playbackService.nowPlayingNotifier.addListener(_onNowPlayingChanged);
    _syncTimer();
  }

  void _syncTimer() {
    _syncNativePosition();
    final isPlaying =
        playbackService.playerStateNotifier.value == PlayerState.playing;
    if (!isPlaying) {
      _positionTimer?.cancel();
      _positionTimer = null;
      return;
    }
    _positionTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      final elapsedSinceNative = _clock.elapsedMilliseconds - _lastNativeSyncMs;
      if (elapsedSinceNative >= _nativeSyncInterval.inMilliseconds) {
        _syncNativePosition();
      } else {
        _emitLocalPosition();
      }
    });
  }

  void _syncNativePosition() {
    _syncedPositionSeconds = playbackService.position.floor();
    _lastNativeSyncMs = _clock.elapsedMilliseconds;
    _emitLocalPosition(forceLength: true);
  }

  void _emitLocalPosition({bool forceLength = false}) {
    final isPlaying =
        playbackService.playerStateNotifier.value == PlayerState.playing;
    final elapsedSeconds = isPlaying
        ? ((_clock.elapsedMilliseconds - _lastNativeSyncMs) / 1000).floor()
        : 0;
    final nextLengthSeconds = playbackService.length.floor();
    final nextSeconds = nextLengthSeconds > 0
        ? (_syncedPositionSeconds + elapsedSeconds)
              .clamp(0, nextLengthSeconds)
              .toInt()
        : _syncedPositionSeconds + elapsedSeconds;
    if (nextSeconds == _positionSeconds &&
        (!forceLength || nextLengthSeconds == _lengthSeconds)) {
      return;
    }
    if (!mounted) {
      _positionSeconds = nextSeconds;
      _lengthSeconds = nextLengthSeconds;
      return;
    }
    setState(() {
      _positionSeconds = nextSeconds;
      _lengthSeconds = nextLengthSeconds;
    });
  }

  void _onNowPlayingChanged() {
    _syncNativePosition();
  }

  @override
  void dispose() {
    playbackService.playerStateNotifier.removeListener(_syncTimer);
    playbackService.nowPlayingNotifier.removeListener(_onNowPlayingChanged);
    _positionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final posText = Duration(
      seconds: _positionSeconds,
    ).toStringHMMSS().replaceFirst(RegExp(r'^0:'), '');
    final lenText = Duration(
      seconds: _lengthSeconds,
    ).toStringHMMSS().replaceFirst(RegExp(r'^0:'), '');
    return Text(
      '$posText / $lenText',
      style: TextStyle(
        color: widget.color,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// 迷你封面组件：
/// 同步检查 Audio.smallCoverBytes，已缓存则用 Image.memory 直接渲染；
/// 未缓存则显示纯色占位 + 异步加载后写回 Audio 并 setState。
/// 不使用 FutureBuilder，避免鼠标 hover 时因 rebuild 导致的闪烁。
class _MiniCoverWidget extends StatefulWidget {
  final Audio audio;
  const _MiniCoverWidget({required this.audio});

  @override
  State<_MiniCoverWidget> createState() => _MiniCoverWidgetState();
}

class _MiniCoverWidgetState extends State<_MiniCoverWidget> {
  Uint8List? _cached;

  @override
  void initState() {
    super.initState();
    _cached = widget.audio.smallCoverBytes;
    if (_cached == null) {
      _load();
    }
  }

  @override
  void didUpdateWidget(_MiniCoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audio != widget.audio ||
        widget.audio.smallCoverBytes != _cached) {
      final bytes = widget.audio.smallCoverBytes;
      if (bytes != null && !identical(bytes, _cached)) {
        setState(() => _cached = bytes);
      } else if (bytes == null && _cached != null) {
        setState(() => _cached = null);
        _load();
      }
    }
  }

  Future<void> _load() async {
    final bytes = await widget.audio.loadSmallCoverBytes();
    if (mounted && bytes != null) {
      setState(() => _cached = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) {
      return ClipRRect(
        borderRadius: AppRadius.smCircular,
        child: Image.memory(
          _cached!,
          width: 48.0,
          height: 48.0,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _placeholder(context),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      width: 48.0,
      height: 48.0,
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: AppRadius.smCircular,
      ),
    );
  }
}
