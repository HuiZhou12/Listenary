import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/play_service/remote_playback_session_controller.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/remote_stream_coordinator.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late RemotePlaybackQueue queue;
  late _RecordingGateway gateway;
  late RemotePlaybackQueueController remoteController;
  late _RecordingLocalBridge localBridge;
  late RemotePlaybackSessionController sessionController;

  setUp(() {
    queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2')]);
    gateway = _RecordingGateway();
    remoteController = RemotePlaybackQueueController(
      queue: queue,
      gateway: gateway,
    );
    localBridge = _RecordingLocalBridge();
    sessionController = RemotePlaybackSessionController(
      queue: queue,
      remoteController: remoteController,
      localBridge: localBridge,
    );
  });

  tearDown(() {
    sessionController.dispose();
    remoteController.dispose();
    queue.dispose();
  });

  test('captures and pauses local playback before opening remote', () async {
    final resumePoint = _FakeResumePoint();
    localBridge.resumePoint = resumePoint;
    localBridge.events = gateway.events;

    await sessionController.play(1, requestedQuality: 'lossless');

    expect(gateway.events, ['capture', 'pause', 'open']);
    expect(sessionController.localResumePoint, same(resumePoint));
    expect(queue.value.currentIndex, 1);
  });

  test(
    'successive remote selections preserve the first local capture',
    () async {
      final resumePoint = _FakeResumePoint();
      localBridge.resumePoint = resumePoint;

      await sessionController.play(0, requestedQuality: 'lossless');
      localBridge.resumePoint = _FakeResumePoint();
      await sessionController.play(1, requestedQuality: 'lossless');

      expect(localBridge.captureCount, 1);
      expect(localBridge.pauseCount, 1);
      expect(sessionController.localResumePoint, same(resumePoint));
      expect(gateway.refs.map((ref) => ref.trackId), ['1', '2']);
    },
  );

  test('opens remote directly when there is no local session', () async {
    await sessionController.play(0, requestedQuality: 'lossless');

    expect(localBridge.captureCount, 1);
    expect(localBridge.pauseCount, 0);
    expect(sessionController.localResumePoint, isNull);
    expect(gateway.refs.single.trackId, '1');
  });

  test('remote failure keeps the captured local session paused', () async {
    final resumePoint = _FakeResumePoint();
    localBridge.resumePoint = resumePoint;
    gateway.error = const RemoteStreamPlaybackException(
      kind: RemoteStreamPlaybackErrorKind.openFailed,
    );

    await expectLater(
      sessionController.play(0, requestedQuality: 'lossless'),
      throwsA(isA<RemoteStreamPlaybackException>()),
    );

    expect(localBridge.captureCount, 1);
    expect(localBridge.pauseCount, 1);
    expect(sessionController.localResumePoint, same(resumePoint));
    expect(queue.value.currentIndex, isNull);
  });

  test(
    'pause failure leaves the session retryable and does not open',
    () async {
      final resumePoint = _FakeResumePoint();
      localBridge.resumePoint = resumePoint;
      localBridge.pauseError = StateError('pause failed');

      await expectLater(
        sessionController.play(0, requestedQuality: 'lossless'),
        throwsStateError,
      );
      expect(gateway.refs, isEmpty);
      expect(sessionController.localResumePoint, isNull);

      localBridge.pauseError = null;
      await sessionController.play(0, requestedQuality: 'lossless');
      expect(localBridge.captureCount, 2);
      expect(localBridge.pauseCount, 2);
      expect(gateway.refs.single.trackId, '1');
    },
  );

  test('invalid indexes and disposed sessions do not capture local state', () {
    expect(
      () => sessionController.play(2, requestedQuality: 'lossless'),
      throwsRangeError,
    );
    expect(localBridge.captureCount, 0);

    sessionController.dispose();
    expect(
      () => sessionController.play(0, requestedQuality: 'lossless'),
      throwsStateError,
    );
    expect(localBridge.captureCount, 0);
  });
}

RemotePlaybackQueueItem _item(String trackId) => RemotePlaybackQueueItem(
  ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
  title: 'Track $trackId',
  artists: const ['Artist'],
);

final class _FakeResumePoint implements LocalPlaybackResumePoint {}

final class _RecordingLocalBridge implements LocalPlaybackSessionBridge {
  LocalPlaybackResumePoint? resumePoint;
  List<String> events = [];
  int captureCount = 0;
  int pauseCount = 0;
  Object? pauseError;

  @override
  LocalPlaybackResumePoint? capture() {
    captureCount++;
    events.add('capture');
    return resumePoint;
  }

  @override
  void pause() {
    pauseCount++;
    events.add('pause');
    final nextError = pauseError;
    if (nextError != null) throw nextError;
  }
}

final class _RecordingGateway implements RemoteQueuePlaybackGateway {
  final refs = <PlatformTrackRef>[];
  final events = <String>[];
  Object? error;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    refs.add(ref);
    events.add('open');
    final nextError = error;
    if (nextError != null) throw nextError;
  }
}
