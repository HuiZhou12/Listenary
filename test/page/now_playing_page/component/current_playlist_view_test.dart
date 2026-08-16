import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/page/now_playing_page/component/current_playlist_view.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/play_service.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/adapters/netease_adapter.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late _Harness harness;

  setUp(() => harness = _Harness());
  tearDown(() => harness.dispose());

  testWidgets('inactive without a local player shows an empty queue', (
    tester,
  ) async {
    await tester.pumpWidget(harness.app());

    expect(find.text('播放队列还是空的'), findsOneWidget);
    expect(PlayService.instance.existingPlaybackService, isNull);
  });

  testWidgets('remote source has priority without creating a local player', (
    tester,
  ) async {
    harness.showRemote(currentIndex: 0);
    await tester.pumpWidget(harness.app());

    expect(find.text('Remote 1'), findsOneWidget);
    expect(find.text('Remote artist 1 - Remote album 1'), findsOneWidget);
    expect(find.text('Remote 2'), findsOneWidget);
    expect(find.byIcon(Symbols.reorder), findsNothing);
    expect(find.byIcon(Symbols.clear_all), findsNothing);
    expect(find.byIcon(Symbols.remove_circle_outline), findsNothing);
    expect(PlayService.instance.existingPlaybackService, isNull);
  });

  testWidgets('remote selection uses target index and default quality', (
    tester,
  ) async {
    harness.showRemote(currentIndex: 0);
    await tester.pumpWidget(harness.app());

    await tester.tap(find.text('Remote 1'));
    await tester.pump();
    expect(harness.gateway.calls, 0);

    await tester.tap(find.text('Remote 2'));
    await tester.pump();

    expect(harness.gateway.calls, 1);
    expect(harness.gateway.lastRef, harness.remoteItems[1].ref);
    expect(harness.gateway.lastQuality, NeteaseAdapter.defaultQuality);
    expect(harness.queue.value.currentIndex, 1);
  });

  testWidgets('leaving remote source removes remote items without local init', (
    tester,
  ) async {
    harness.showRemote(currentIndex: 0);
    await tester.pumpWidget(harness.app());
    expect(find.text('Remote 1'), findsOneWidget);

    harness.showLocal();
    await tester.pump();

    expect(find.text('Remote 1'), findsNothing);
    expect(find.text('播放队列还是空的'), findsOneWidget);
    expect(PlayService.instance.existingPlaybackService, isNull);
  });
}

final class _Harness {
  _Harness() {
    queue.replace(remoteItems, currentIndex: 0);
    queueController = RemotePlaybackQueueController(
      queue: queue,
      gateway: gateway,
    );
    remoteController = RemotePlaybackSessionController(
      queue: queue,
      remoteController: queueController,
      localBridge: localBridge,
      backend: backend,
    );
  }

  final activeSession = ActivePlaybackSession();
  final queue = RemotePlaybackQueue();
  final gateway = _Gateway();
  final localBridge = _LocalBridge();
  final backend = _Backend();
  final remoteItems = [_remoteItem(1), _remoteItem(2)];
  late final RemotePlaybackQueueController queueController;
  late final RemotePlaybackSessionController remoteController;

  Widget app() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ActivePlaybackSession>.value(
          value: activeSession,
        ),
        Provider<RemotePlaybackSessionController>.value(
          value: remoteController,
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 400, child: CurrentPlaylistView()),
        ),
      ),
    );
  }

  void showRemote({required int currentIndex}) {
    activeSession.switchTo(
      source: ActivePlaybackSessionSource.remote,
      queue: remoteItems.map(
        (item) => ActivePlaybackSessionItem(
          title: item.title,
          artist: item.artistDisplay,
          album: item.album,
        ),
      ),
      currentIndex: currentIndex,
      state: ActivePlaybackSessionState.playing,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: false,
        canPause: true,
        canPrevious: false,
        canNext: true,
        canSeek: false,
      ),
    );
  }

  void showLocal() {
    activeSession.switchTo(
      source: ActivePlaybackSessionSource.local,
      queue: const [
        ActivePlaybackSessionItem(
          title: 'Local 1',
          artist: 'Local artist 1',
          album: 'Local album 1',
        ),
      ],
      currentIndex: 0,
      state: ActivePlaybackSessionState.paused,
      controlInFlight: false,
      capabilities: const ActivePlaybackSessionCapabilities(
        canPlay: true,
        canPause: false,
        canPrevious: true,
        canNext: true,
        canSeek: true,
      ),
    );
  }

  Future<void> dispose() async {
    remoteController.dispose();
    queueController.dispose();
    queue.dispose();
    activeSession.dispose();
    await Future<void>.delayed(Duration.zero);
    await backend.dispose();
  }
}

final class _Gateway implements RemoteQueuePlaybackGateway {
  int calls = 0;
  PlatformTrackRef? lastRef;
  String? lastQuality;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    calls++;
    lastRef = ref;
    lastQuality = requestedQuality;
  }
}

final class _LocalBridge implements LocalPlaybackSessionBridge {
  final _listeners = <void Function()>{};

  @override
  void addLocalPlaybackRequestListener(void Function() listener) {
    _listeners.add(listener);
  }

  @override
  LocalPlaybackResumePoint? capture() => null;

  @override
  void pause() {}

  @override
  void removeLocalPlaybackRequestListener(void Function() listener) {
    _listeners.remove(listener);
  }

  @override
  void restore(LocalPlaybackResumePoint resumePoint) {}
}

final class _Backend implements ControllablePlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast(sync: true);

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  @override
  Future<void> dispose() => _states.close();

  @override
  Future<void> open(PlaybackSource source) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}
}

RemotePlaybackQueueItem _remoteItem(int id) {
  return RemotePlaybackQueueItem(
    ref: PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: 'remote-$id',
    ),
    title: 'Remote $id',
    artists: ['Remote artist $id'],
    album: 'Remote album $id',
  );
}
