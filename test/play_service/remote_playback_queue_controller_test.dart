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
    gateway.results.add(
      RemoteQueuePlaybackResult(
        coverUri: Uri.parse('https://cover.invalid/resolved'),
      ),
    );

    final result = controller.play(1, requestedQuality: 'lossless');
    await pumpEventQueue();

    expect(queue.value.currentIndex, 0);
    expect(gateway.refs.single.trackId, '2');
    expect(gateway.qualities.single, 'lossless');

    pending.complete();
    await result;
    expect(queue.value.currentIndex, 1);
    expect(
      queue.value.currentItem?.coverUri,
      Uri.parse('https://cover.invalid/resolved'),
    );
  });

  test('keeps an existing HTTPS search cover', () async {
    final searchCover = Uri.parse('https://cover.invalid/search');
    queue.replace([_item('1', coverUri: searchCover)], currentIndex: 0);
    gateway.results.add(
      RemoteQueuePlaybackResult(
        coverUri: Uri.parse('https://cover.invalid/resolved'),
      ),
    );

    await controller.play(0, requestedQuality: 'lossless');

    expect(queue.value.currentItem?.coverUri, searchCover);
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
    gateway.results.addAll([
      RemoteQueuePlaybackResult(
        coverUri: Uri.parse('https://cover.invalid/old'),
      ),
      RemoteQueuePlaybackResult(
        coverUri: Uri.parse('https://cover.invalid/new'),
      ),
    ]);

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
    expect(
      queue.value.items[0].coverUri,
      Uri.parse('https://cover.invalid/new'),
    );
    expect(queue.value.items[1].coverUri, isNull);
  });

  test('queue replacement rejects a resolved cover from old work', () async {
    final pending = Completer<void>();
    gateway.pending.add(pending.future);
    gateway.results.add(
      RemoteQueuePlaybackResult(
        coverUri: Uri.parse('https://cover.invalid/stale'),
      ),
    );
    final result = controller.play(1, requestedQuality: 'lossless');
    await pumpEventQueue();

    queue.replace([_item('3')], currentIndex: 0);
    pending.complete();

    await expectLater(
      result,
      throwsA(
        isA<RemoteStreamPlaybackException>().having(
          (error) => error.kind,
          'kind',
          RemoteStreamPlaybackErrorKind.cancelled,
        ),
      ),
    );
    expect(queue.value.currentItem?.ref.trackId, '3');
    expect(queue.value.currentItem?.coverUri, isNull);
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

RemotePlaybackQueueItem _item(String trackId, {Uri? coverUri}) {
  return RemotePlaybackQueueItem(
    ref: PlatformTrackRef(platform: MusicPlatform.netease, trackId: trackId),
    title: 'Track $trackId',
    artists: const ['Artist'],
    coverUri: coverUri,
  );
}

final class _FakeRemoteQueuePlaybackGateway
    implements RemoteQueuePlaybackMetadataGateway {
  final refs = <PlatformTrackRef>[];
  final qualities = <String>[];
  final tokens = <ChkszCancelToken>[];
  final pending = <Future<void>>[];
  final results = <RemoteQueuePlaybackResult>[];
  Object? error;

  @override
  Future<void> open(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    await openWithMetadata(
      ref,
      requestedQuality: requestedQuality,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<RemoteQueuePlaybackResult> openWithMetadata(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required ChkszCancelToken cancelToken,
  }) async {
    refs.add(ref);
    qualities.add(requestedQuality);
    tokens.add(cancelToken);
    final result = results.isEmpty
        ? const RemoteQueuePlaybackResult()
        : results.removeAt(0);
    if (pending.isNotEmpty) await pending.removeAt(0);
    final nextError = error;
    if (nextError != null) throw nextError;
    return result;
  }
}
