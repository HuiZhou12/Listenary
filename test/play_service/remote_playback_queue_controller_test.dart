import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/remote_playback_queue.dart';
import 'package:pure_music/play_service/remote_playback_queue_controller.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';
import 'package:pure_music/services/music_platform/chksz/remote_stream_coordinator.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

void main() {
  late RemotePlaybackQueue queue;
  late _FakeRemoteQueuePlaybackGateway gateway;
  late RemotePlaybackQueueController controller;

  setUp(() {
    queue = RemotePlaybackQueue();
    queue.replace([_item('1'), _item('2')], currentIndex: 0);
    gateway = _FakeRemoteQueuePlaybackGateway();
    controller = RemotePlaybackQueueController(queue: queue, gateway: gateway);
  });

  tearDown(() {
    controller.dispose();
    queue.dispose();
  });

  test('selects the target only after opening succeeds', () async {
    final pending = Completer<void>();
    gateway.pending.add(pending.future);

    final result = controller.play(1, requestedQuality: 'lossless');
    await pumpEventQueue();

    expect(queue.value.currentIndex, 0);
    expect(gateway.refs.single.trackId, '2');
    expect(gateway.qualities.single, 'lossless');

    pending.complete();
    await result;
    expect(queue.value.currentIndex, 1);
  });

  test('open failure does not change the current item', () async {
    gateway.error = const RemoteStreamPlaybackException(
      kind: RemoteStreamPlaybackErrorKind.openFailed,
    );

    await expectLater(
      controller.play(1, requestedQuality: 'standard'),
      throwsA(isA<RemoteStreamPlaybackException>()),
    );

    expect(queue.value.currentIndex, 0);
  });

  test('a newer request cancels the old request and wins selection', () async {
    final oldPending = Completer<void>();
    final newPending = Completer<void>();
    gateway.pending.addAll([oldPending.future, newPending.future]);

    final oldResult = controller.play(1, requestedQuality: 'standard');
    await pumpEventQueue();
    final oldToken = gateway.tokens.single;
    final newResult = controller.play(0, requestedQuality: 'lossless');
    await pumpEventQueue();

    expect(oldToken.isCancelled, isTrue);
    newPending.complete();
    await newResult;
    oldPending.complete();
    await expectLater(
      oldResult,
      throwsA(
        isA<RemoteStreamPlaybackException>().having(
          (error) => error.kind,
          'kind',
          RemoteStreamPlaybackErrorKind.cancelled,
        ),
      ),
    );
    expect(queue.value.currentIndex, 0);
  });

  test('invalid indexes do not cancel or open anything', () async {
    await expectLater(
      controller.play(2, requestedQuality: 'standard'),
      throwsRangeError,
    );

    expect(gateway.refs, isEmpty);
    expect(queue.value.currentIndex, 0);
  });

  test('cancel stops active work but keeps the controller reusable', () async {
    final pending = Completer<void>();
    gateway.pending.add(pending.future);
    final cancelled = controller.play(1, requestedQuality: 'standard');
    await pumpEventQueue();
    final token = gateway.tokens.single;

    controller.cancel();
    expect(token.isCancelled, isTrue);
    pending.complete();
    await expectLater(cancelled, throwsA(isA<RemoteStreamPlaybackException>()));

    await controller.play(0, requestedQuality: 'lossless');
    expect(queue.value.currentIndex, 0);
  });

  test('dispose cancels the active request and rejects new work', () async {
    final pending = Completer<void>();
    gateway.pending.add(pending.future);
    final result = controller.play(1, requestedQuality: 'standard');
    await pumpEventQueue();
    final token = gateway.tokens.single;

    controller.dispose();
    expect(token.isCancelled, isTrue);
    pending.complete();
    await expectLater(result, throwsA(isA<RemoteStreamPlaybackException>()));
    expect(
      () => controller.play(0, requestedQuality: 'standard'),
      throwsStateError,
    );
  });
}

RemotePlaybackQueueItem _item(String trackId) {
  return RemotePlaybackQueueItem(
    ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
    title: 'Track $trackId',
    artists: const ['Artist'],
  );
}

final class _FakeRemoteQueuePlaybackGateway
    implements RemoteQueuePlaybackGateway {
  final refs = <PlatformTrackRef>[];
  final qualities = <String>[];
  final tokens = <ChkszCancelToken>[];
  final pending = <Future<void>>[];
  Object? error;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    refs.add(ref);
    qualities.add(requestedQuality);
    tokens.add(cancelToken);
    if (pending.isNotEmpty) await pending.removeAt(0);
    final nextError = error;
    if (nextError != null) throw nextError;
  }
}
