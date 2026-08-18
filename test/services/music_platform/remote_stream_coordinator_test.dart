import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

void main() {
  const ref = PlatformTrackRef(
    platform: MusicPlatform.netease,
    trackId: 'track-1',
  );
  final now = DateTime.utc(2026, 8, 14, 12);

  late _LoopbackFixture fixture;
  late _HttpPlaybackBackend backend;

  setUp(() async {
    fixture = await _LoopbackFixture.start();
    backend = _HttpPlaybackBackend();
  });

  tearDown(() async {
    await backend.dispose();
    await fixture.close();
  });

  test('opens a resolved loopback stream', () async {
    final coordinator = RemoteStreamCoordinator(
      resolver: (_, {required requestedQuality, required cancelToken}) async {
        return _stream(ref, fixture.uri('/ok'), requestedQuality, now);
      },
      backend: backend,
      clock: () => now,
    );

    final stream = await coordinator.resolveAndOpen(
      ref,
      requestedQuality: 'standard',
    );

    expect(stream.ref, ref);
    expect(backend.openCount, 1);
    expect(fixture.paths, ['/ok']);
  });

  test('re-resolves once after an expired backend response', () async {
    var resolveCount = 0;
    final coordinator = RemoteStreamCoordinator(
      resolver: (_, {required requestedQuality, required cancelToken}) async {
        resolveCount++;
        final path = resolveCount == 1 ? '/expired' : '/ok';
        return _stream(ref, fixture.uri(path), requestedQuality, now);
      },
      backend: backend,
      clock: () => now,
    );

    final stream = await coordinator.resolveAndOpen(
      ref,
      requestedQuality: 'standard',
    );

    expect(resolveCount, 2);
    expect(stream.uri.path, '/ok');
    expect(backend.openCount, 2);
    expect(backend.stopCount, 1);
    expect(fixture.paths, ['/expired', '/ok']);
  });

  test('cancellation after resolution does not open the URI', () async {
    final completer = Completer<ResolvedStream>();
    final token = ChkszCancelToken();
    final coordinator = RemoteStreamCoordinator(
      resolver: (_, {required requestedQuality, required cancelToken}) {
        return completer.future;
      },
      backend: backend,
      clock: () => now,
    );

    final future = coordinator.resolveAndOpen(
      ref,
      requestedQuality: 'standard',
      cancelToken: token,
    );
    token.cancel();
    completer.complete(_stream(ref, fixture.uri('/ok'), 'standard', now));

    await expectLater(
      future,
      throwsA(
        isA<RemoteStreamPlaybackException>().having(
          (error) => error.kind,
          'kind',
          RemoteStreamPlaybackErrorKind.cancelled,
        ),
      ),
    );
    expect(backend.openCount, 0);
    expect(fixture.paths, isEmpty);
  });

  test('backend failures do not expose signed URI details', () async {
    final coordinator = RemoteStreamCoordinator(
      resolver: (_, {required requestedQuality, required cancelToken}) async {
        return _stream(
          ref,
          fixture
              .uri('/fail')
              .replace(queryParameters: {'signature': 'TEST_ONLY_SIGNATURE'}),
          requestedQuality,
          now,
        );
      },
      backend: backend,
      clock: () => now,
    );

    final error = await _capturePlaybackError(
      coordinator.resolveAndOpen(ref, requestedQuality: 'standard'),
    );

    expect(error.kind, RemoteStreamPlaybackErrorKind.openFailed);
    expect(error.toString(), isNot(contains('TEST_ONLY_SIGNATURE')));
    expect(error.safeMessage, isNot(contains('TEST_ONLY_SIGNATURE')));
    expect(error.toString(), isNot(contains('/fail')));
  });
}

ResolvedStream _stream(
  PlatformTrackRef ref,
  Uri uri,
  String quality,
  DateTime resolvedAt,
) {
  return ResolvedStream(
    ref: ref,
    uri: uri,
    requestedQuality: quality,
    resolvedAt: resolvedAt,
    expiresAt: resolvedAt.add(const Duration(minutes: 1)),
  );
}

Future<RemoteStreamPlaybackException> _capturePlaybackError(
  Future<Object?> future,
) async {
  try {
    await future;
  } on RemoteStreamPlaybackException catch (error) {
    return error;
  }
  throw StateError('Expected RemoteStreamPlaybackException');
}

final class _HttpPlaybackBackend implements PlaybackBackend {
  final _client = HttpClient()..findProxy = (_) => 'DIRECT';
  final _states = StreamController<PlaybackBackendState>.broadcast();
  var openCount = 0;
  var stopCount = 0;

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  @override
  Future<void> open(PlaybackSource source) async {
    if (source is! RemotePlaybackSource) {
      throw const PlaybackBackendOpenException(
        kind: PlaybackBackendOpenFailure.unavailable,
      );
    }
    openCount++;
    _states.add(PlaybackBackendState.opening);
    final request = await _client.getUrl(source.uri);
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode == HttpStatus.gone) {
      throw const PlaybackBackendOpenException(
        kind: PlaybackBackendOpenFailure.expired,
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      throw const PlaybackBackendOpenException(
        kind: PlaybackBackendOpenFailure.unavailable,
      );
    }
    _states.add(PlaybackBackendState.playing);
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _states.add(PlaybackBackendState.stopped);
  }

  @override
  Future<void> dispose() async {
    _client.close(force: true);
    await _states.close();
  }
}

final class _LoopbackFixture {
  _LoopbackFixture._(this._server) {
    _subscription = _server.listen(_handle);
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final List<String> paths = [];

  static Future<_LoopbackFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _LoopbackFixture._(server);
  }

  Uri uri(String path) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: path,
  );

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }

  void _handle(HttpRequest request) {
    paths.add(request.uri.path);
    switch (request.uri.path) {
      case '/ok':
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..add([0x49, 0x44, 0x33]);
      case '/expired':
        request.response.statusCode = HttpStatus.gone;
      default:
        request.response.statusCode = HttpStatus.internalServerError;
    }
    unawaited(request.response.close());
  }
}
