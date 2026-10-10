import 'package:flutter/foundation.dart';
import 'package:pure_music/lyric/lrc.dart';
import 'package:pure_music/lyric/lyric.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_timeline.dart';
import 'package:pure_music/lyric/lyric_timing.dart'
    show lyricLineIsFilteredBlank, lyricLineSwitchStartsFor;
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';

enum RemoteLyricStatus {
  inactive,
  loading,
  ready,

  /// 这首歌**没有**歌词（平台支持歌词，但这份曲目没有）。
  empty,

  /// 该平台**不支持**歌词（P-63：与 [empty] 是**两种不同的事实**）。
  ///
  /// 以前这里复用了 [empty]，于是"平台没有歌词能力"与"这首歌没歌词"在界面上
  /// **长得一模一样**（都渲染成「暂无歌词」），而播放侧对同一情形给的是明确的
  /// `unavailable` —— 同一失败两种结论（RC-C）。
  platformUnsupported,

  failed,
}

@immutable
final class RemoteLyricSnapshot {
  const RemoteLyricSnapshot._({
    required this.status,
    this.ref,
    this.lyric,
    this.position,
    this.currentLineIndex,
  });

  const RemoteLyricSnapshot.inactive()
    : this._(status: RemoteLyricStatus.inactive);

  const RemoteLyricSnapshot.loading(PlatformTrackRef ref)
    : this._(status: RemoteLyricStatus.loading, ref: ref);

  const RemoteLyricSnapshot.empty(PlatformTrackRef ref)
    : this._(status: RemoteLyricStatus.empty, ref: ref);

  /// 该平台不支持歌词（P-63）。
  const RemoteLyricSnapshot.platformUnsupported(PlatformTrackRef ref)
    : this._(status: RemoteLyricStatus.platformUnsupported, ref: ref);

  const RemoteLyricSnapshot.failed(PlatformTrackRef ref)
    : this._(status: RemoteLyricStatus.failed, ref: ref);

  const RemoteLyricSnapshot.ready({
    required PlatformTrackRef ref,
    required Lyric lyric,
    required Duration position,
    required int currentLineIndex,
  }) : this._(
         status: RemoteLyricStatus.ready,
         ref: ref,
         lyric: lyric,
         position: position,
         currentLineIndex: currentLineIndex,
       );

  final RemoteLyricStatus status;
  final PlatformTrackRef? ref;
  final Lyric? lyric;
  final Duration? position;
  final int? currentLineIndex;

  LyricLine? get currentLine {
    final lines = lyric?.lines;
    final index = currentLineIndex;
    if (lines == null || index == null || index < 0 || index >= lines.length) {
      return null;
    }
    return lines[index];
  }

  LyricLine? get nextLine {
    final lines = lyric?.lines;
    final index = currentLineIndex;
    if (lines == null || index == null || index + 1 >= lines.length) {
      return null;
    }
    return lines[index + 1];
  }
}

final class RemoteLyricController extends ValueNotifier<RemoteLyricSnapshot> {
  RemoteLyricController({
    required OnlineMusicService service,
    required ActivePlaybackSession activeSession,
    required RemotePlaybackQueue queue,
    required RemotePlaybackTimelineController timeline,
  }) : _service = service,
       _activeSession = activeSession,
       _queue = queue,
       _timeline = timeline,
       super(const RemoteLyricSnapshot.inactive()) {
    _activeSession.addListener(_syncTrack);
    _queue.addListener(_syncTrack);
    _timeline.addListener(_syncPosition);
    _syncTrack();
  }

  final OnlineMusicService _service;
  final ActivePlaybackSession _activeSession;
  final RemotePlaybackQueue _queue;
  final RemotePlaybackTimelineController _timeline;
  OnlineMusicCancelToken? _cancelToken;
  int _requestRevision = 0;
  bool _disposed = false;

  void _syncTrack() {
    if (_disposed) return;
    if (_activeSession.value.source != ActivePlaybackSessionSource.remote) {
      _deactivate();
      return;
    }
    final ref = _queue.value.currentItem?.ref;
    if (ref == null) {
      _deactivate();
      return;
    }
    if (value.ref == ref && value.status != RemoteLyricStatus.inactive) {
      _syncPosition();
      return;
    }
    _load(ref);
  }

  void _load(PlatformTrackRef ref) {
    _cancelCurrentRequest();
    final revision = ++_requestRevision;
    value = RemoteLyricSnapshot.loading(ref);
    if (!_service.capabilities.lyricPlatforms.contains(ref.platform)) {
      // P-63：「**这个平台**没有歌词能力」不是「**这首歌**没有歌词」。
      // 前者用户换不了歌也没用（要换平台/加一个能出歌词的 Provider），
      // 后者换一首就好 —— 两者必须给出不同状态与文案。
      value = RemoteLyricSnapshot.platformUnsupported(ref);
      return;
    }

    final token = OnlineMusicCancelToken();
    _cancelToken = token;
    _service
        .fetchLyrics(ref, cancelToken: token)
        .then<void>(
          (result) {
            if (!_isCurrentRequest(revision, ref, token)) return;
            _cancelToken = null;
            final lyric = result.parsed;
            if (lyric == null || lyric.isEmpty) {
              value = RemoteLyricSnapshot.empty(ref);
              return;
            }
            _publishReady(ref, lyric);
          },
          onError: (Object _) {
            if (!_isCurrentRequest(revision, ref, token)) return;
            _cancelToken = null;
            value = RemoteLyricSnapshot.failed(ref);
          },
        );
  }

  void _syncPosition() {
    if (_disposed || value.status != RemoteLyricStatus.ready) return;
    final ref = value.ref;
    final lyric = value.lyric;
    if (ref == null || lyric == null || lyric.isEmpty) return;
    _publishReady(ref, lyric);
  }

  void _publishReady(PlatformTrackRef ref, Lyric lyric) {
    final position = _timeline.projectedSnapshot.position ?? Duration.zero;
    value = RemoteLyricSnapshot.ready(
      ref: ref,
      lyric: lyric,
      position: position,
      currentLineIndex: remoteLyricLineIndexAt(lyric, position),
    );
  }

  bool _isCurrentRequest(
    int revision,
    PlatformTrackRef ref,
    OnlineMusicCancelToken token,
  ) =>
      !_disposed &&
      revision == _requestRevision &&
      identical(token, _cancelToken) &&
      value.ref == ref &&
      _activeSession.value.source == ActivePlaybackSessionSource.remote &&
      _queue.value.currentItem?.ref == ref;

  void _deactivate() {
    _cancelCurrentRequest();
    _requestRevision++;
    if (value.status != RemoteLyricStatus.inactive) {
      value = const RemoteLyricSnapshot.inactive();
    }
  }

  void _cancelCurrentRequest() {
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelCurrentRequest();
    _activeSession.removeListener(_syncTrack);
    _queue.removeListener(_syncTrack);
    _timeline.removeListener(_syncPosition);
    super.dispose();
  }
}

int remoteLyricLineIndexAt(Lyric lyric, Duration position) {
  if (lyric.lines.isEmpty) return 0;
  final positionMs = position.inMilliseconds;
  final switchStarts = lyricLineSwitchStartsFor(lyric);
  var result = 0;
  for (var index = 0; index < switchStarts.length; index++) {
    if (switchStarts[index] > positionMs) break;
    result = index;
  }

  if (!lyricLineIsFilteredBlank(lyric.lines[result])) return result;
  for (var index = result - 1; index >= 0; index--) {
    if (!lyricLineIsFilteredBlank(lyric.lines[index])) return index;
  }
  for (var index = result + 1; index < lyric.lines.length; index++) {
    if (!lyricLineIsFilteredBlank(lyric.lines[index])) return index;
  }
  return result;
}

String remoteLyricLineContent(LyricLine line) => switch (line) {
  LrcLine value => value.content,
  SyncLyricLine value => value.content,
  UnsyncLyricLine value => value.content,
  _ => '',
};

/// 无行可显示时的占位文案（**唯一**来源，视图只做委托）。
///
/// 三问必须分开答（P-63 把最后一问补上）：
/// - 「正在加载」不是「没有歌词」；
/// - 「加载失败」也不是「没有歌词」；
/// - 「**这首歌**没有歌词」与「**这个平台**不支持歌词」是两件不同的事 ——
///   前者换一首歌就好，后者换歌没用（得换平台，或加一个能出歌词的 Provider）。
///
/// 放在这里而不是视图里：这样它是**可直接单测**的纯函数，而视图只剩委托；
/// 枚举的 `switch` 又是穷尽的 ⇒ 新增状态一定会被编译期拦下。
String remoteLyricPlaceholderFor(RemoteLyricStatus status) => switch (status) {
  RemoteLyricStatus.loading => '歌词加载中…',
  RemoteLyricStatus.failed => '歌词加载失败',
  RemoteLyricStatus.platformUnsupported => '该平台不支持歌词（当前 Provider 没有歌词能力）',
  RemoteLyricStatus.ready ||
  RemoteLyricStatus.empty ||
  RemoteLyricStatus.inactive => '暂无歌词',
};
