import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/index.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';

void main() {
  test('keeps the displayed order and selected index', () {
    final selection = OnlineTrackSelection.fromResultPage(
      tracks: [_track('3'), _track('1'), _track('2')],
      selectedRef: _ref('1'),
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['3', '1', '2']);
    expect(selection.selectedIndex, 1);
  });

  test('filters unavailable tracks without changing playable order', () {
    final selection = OnlineTrackSelection.fromResultPage(
      tracks: [
        _track('3', TrackAvailability.paid),
        _track('1'),
        _track('4', TrackAvailability.unavailable),
        _track('2'),
      ],
      selectedRef: _ref('2'),
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['1', '2']);
    expect(selection.selectedIndex, 1);
  });

  test('rejects a missing or unplayable selected track', () {
    expect(
      () => OnlineTrackSelection.fromResultPage(
        tracks: [_track('1')],
        selectedRef: _ref('2'),
      ),
      throwsArgumentError,
    );
    expect(
      () => OnlineTrackSelection.fromResultPage(
        tracks: [_track('1', TrackAvailability.paid)],
        selectedRef: _ref('1'),
      ),
      throwsArgumentError,
    );
  });

  // ── 以下三条从 `test/page/online_music_page_test.dart:25-81` 迁移而来 ──────────
  // 那三条测的是**纯逻辑**（选曲 / 历史 / 复用判定），与页面无关；页面已随 D2
  // 删除 ⇒ 它们跟着起播链路留在这里，断言逐条不变。

  test('online selection filters explicitly unplayable tracks', () {
    final tracks = [
      _fullTrack('1', title: 'Playable'),
      _fullTrack('2', title: 'Paid', availability: TrackAvailability.paid),
      _fullTrack(
        '3',
        title: 'Unavailable',
        availability: TrackAvailability.unavailable,
      ),
      _fullTrack(
        '4',
        title: 'Unknown',
        availability: TrackAvailability.unknown,
      ),
    ];

    final selection = OnlineTrackSelection.fromResultPage(
      tracks: tracks,
      selectedRef: tracks.last.ref,
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['1', '4']);
    expect(selection.selectedIndex, 1);
  });

  test('history selection preserves visible order and last quality', () {
    final entries = [
      _history('2', quality: 'standard'),
      _history('1', quality: 'lossless'),
    ];

    final selection = OnlineTrackSelection.fromHistory(
      entries: entries,
      selectedRef: entries.last.track.ref,
    );

    expect(selection.tracks.map((track) => track.ref.trackId), ['2', '1']);
    expect(selection.selectedIndex, 1);
    expect(selection.requestedQuality, 'lossless');
  });

  test('active matching online identity is reused without a new request', () {
    final ref = _fullTrack('1', title: 'Current').ref;

    expect(
      shouldReuseActiveOnlineTrack(
        state: PlaybackBackendState.playing,
        currentRef: ref,
        selectedRef: ref,
      ),
      isTrue,
    );
    expect(
      shouldReuseActiveOnlineTrack(
        state: PlaybackBackendState.failed,
        currentRef: ref,
        selectedRef: ref,
      ),
      isFalse,
    );
  });
}

PlatformTrackRef _ref(String id) => PlatformTrackRef(
  platform: MusicPlatform.netease,
  trackId: id,
);

/// 最简曲目：只带 id 与可播性（前三条用例的输入形状）。
MusicTrack _track(
  String id, [
  TrackAvailability availability = TrackAvailability.playable,
]) => MusicTrack(
  ref: _ref(id),
  title: id,
  artists: const ['Artist'],
  availability: availability,
);

/// 带完整元信息的曲目（迁移过来的三条用例需要）。
MusicTrack _fullTrack(
  String id, {
  String? title,
  TrackAvailability availability = TrackAvailability.playable,
}) => MusicTrack(
  ref: _ref(id),
  title: title ?? id,
  artists: const ['Test Artist'],
  album: 'Test Album',
  duration: const Duration(seconds: 123),
  availability: availability,
);

OnlineHistoryEntry _history(String id, {required String quality}) =>
    OnlineHistoryEntry(
      track: _fullTrack(id, title: 'History $id'),
      playCount: 1,
      lastPlayedAt: DateTime.utc(2026, 8, 18),
      lastQuality: quality,
    );
