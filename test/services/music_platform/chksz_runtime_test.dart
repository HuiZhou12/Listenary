import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/playback_source.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';
const _replacementApiKey = 'chksz_REPLACED_TEST_ONLY';
const _trackRef = PlatformTrackRef(
  platform: MusicPlatform.netease,
  trackId: '123456',
);

void main() {
  test('owns search, resolve, and quota state', () async {
    final transport = _FakeTransport((request, _) async {
      if (request.path == '/api/163_search') {
        return ChkszTransportResponse(
          statusCode: 200,
          data: _searchBody(),
          headers: const {
            'X-Quota-Free-Remaining': ['9'],
          },
        );
      }
      return ChkszTransportResponse(
        statusCode: 200,
        data: _resolveBody(),
        headers: const {
          'X-Quota-Free-Remaining': ['8'],
        },
      );
    });
    final runtime = ChkszRuntime(
      credentialProvider: InMemoryChkszCredentialProvider(
        initialApiKey: _fakeApiKey,
      ),
      transport: transport,
      clock: () => DateTime.utc(2026, 8, 14),
    );

    final page = await runtime.searchNetease(
      keyword: 'Test Track',
      cancelToken: ChkszCancelToken(),
    );
    expect(page.items.single.ref, _trackRef);
    expect(runtime.quota?.freeRemaining, 9);

    final stream = await runtime.resolveNetease(
      _trackRef,
      requestedQuality: NeteaseAdapter.defaultQuality,
      cancelToken: ChkszCancelToken(),
    );
    expect(stream.ref, _trackRef);
    expect(runtime.quota?.freeRemaining, 8);
  });

  test(
    'opens a resolved Netease stream through the runtime coordinator',
    () async {
      final transport = _FakeTransport(
        (_, _) async =>
            ChkszTransportResponse(statusCode: 200, data: _resolveBody()),
      );
      final runtime = ChkszRuntime(
        credentialProvider: InMemoryChkszCredentialProvider(
          initialApiKey: _fakeApiKey,
        ),
        transport: transport,
        clock: () => DateTime.utc(2026, 8, 14),
      );
      final backend = _RuntimePlaybackBackend();
      addTearDown(() async {
        await backend.dispose();
        runtime.dispose();
      });

      final stream = await runtime.resolveAndOpenNetease(
        _trackRef,
        requestedQuality: NeteaseAdapter.defaultQuality,
        backend: backend,
        cancelToken: ChkszCancelToken(),
      );

      expect(stream.ref, _trackRef);
      expect(backend.opened, hasLength(1));
      expect(backend.opened.single, isA<RemotePlaybackSource>());
      expect(
        (backend.opened.single as RemotePlaybackSource).uri,
        Uri.parse('https://media.invalid/test.flac'),
      );
    },
  );

  test(
    'cancels active requests and clears quota before replacing key',
    () async {
      final searchResponse = Completer<ChkszTransportResponse>();
      final resolveResponse = Completer<ChkszTransportResponse>();
      final transport = _FakeTransport((request, _) {
        return request.path == '/api/163_search'
            ? searchResponse.future
            : resolveResponse.future;
      });
      late final ChkszRuntime runtime;
      final credentials = _RecordingCredentialProvider(
        initialApiKey: _fakeApiKey,
        onWrite: () {
          expect(transport.tokens.every((token) => token.isCancelled), isTrue);
          expect(runtime.quota, isNull);
        },
      );
      runtime = ChkszRuntime(
        credentialProvider: credentials,
        transport: transport,
      );
      await _setQuota(runtime, transport);

      final searchToken = ChkszCancelToken();
      final resolveToken = ChkszCancelToken();
      final search = runtime.searchNetease(
        keyword: 'Test Track',
        cancelToken: searchToken,
      );
      final resolve = runtime.resolveNetease(
        _trackRef,
        requestedQuality: NeteaseAdapter.defaultQuality,
        cancelToken: resolveToken,
      );
      await Future<void>.delayed(Duration.zero);

      await runtime.writeApiKey(_replacementApiKey);
      expect(await runtime.readApiKey(), _replacementApiKey);
      expect(searchToken.isCancelled, isTrue);
      expect(resolveToken.isCancelled, isTrue);

      searchResponse.complete(
        ChkszTransportResponse(
          statusCode: 200,
          data: _searchBody(),
          headers: const {
            'X-Quota-Free-Remaining': ['6'],
          },
        ),
      );
      resolveResponse.complete(
        ChkszTransportResponse(
          statusCode: 200,
          data: _resolveBody(),
          headers: const {
            'X-Quota-Free-Remaining': ['5'],
          },
        ),
      );
      expect(
        (await _captureChkszException(search)).kind,
        ChkszErrorKind.cancelled,
      );
      expect(
        (await _captureChkszException(resolve)).kind,
        ChkszErrorKind.cancelled,
      );
      expect(runtime.quota, isNull);
    },
  );

  test('clears active state even when credential clearing fails', () async {
    final response = Completer<ChkszTransportResponse>();
    final transport = _FakeTransport((_, _) => response.future);
    final credentials = _RecordingCredentialProvider(
      initialApiKey: _fakeApiKey,
      clearError: const ChkszCredentialStorageException(
        operation: ChkszCredentialStorageOperation.clear,
      ),
    );
    final runtime = ChkszRuntime(
      credentialProvider: credentials,
      transport: transport,
    );
    await _setQuota(runtime, transport);
    final token = ChkszCancelToken();
    final search = runtime.searchNetease(
      keyword: 'Test Track',
      cancelToken: token,
    );
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      runtime.clearApiKey(),
      throwsA(isA<ChkszCredentialStorageException>()),
    );
    expect(token.isCancelled, isTrue);
    expect(runtime.quota, isNull);

    response.complete(
      ChkszTransportResponse(statusCode: 200, data: _searchBody()),
    );
    expect(
      (await _captureChkszException(search)).kind,
      ChkszErrorKind.cancelled,
    );
  });

  test(
    'removes completed and failed requests from active registration',
    () async {
      var shouldFail = false;
      final transport = _FakeTransport((_, _) async {
        if (shouldFail) {
          return ChkszTransportResponse(
            statusCode: 503,
            data: const {'msg': 'unavailable'},
          );
        }
        return ChkszTransportResponse(statusCode: 200, data: _searchBody());
      });
      final runtime = ChkszRuntime(
        credentialProvider: InMemoryChkszCredentialProvider(
          initialApiKey: _fakeApiKey,
        ),
        transport: transport,
      );
      final completedToken = ChkszCancelToken();
      await runtime.searchNetease(
        keyword: 'Test Track',
        cancelToken: completedToken,
      );
      shouldFail = true;
      final failedToken = ChkszCancelToken();
      expect(
        (await _captureChkszException(
          runtime.searchNetease(
            keyword: 'Test Track',
            cancelToken: failedToken,
          ),
        )).kind,
        ChkszErrorKind.unavailable,
      );

      await runtime.writeApiKey(_replacementApiKey);
      expect(completedToken.isCancelled, isFalse);
      expect(failedToken.isCancelled, isFalse);
    },
  );

  test(
    'dispose cancels requests and transport without clearing credentials',
    () async {
      final response = Completer<ChkszTransportResponse>();
      final transport = _FakeTransport((_, _) => response.future);
      final credentials = _RecordingCredentialProvider(
        initialApiKey: _fakeApiKey,
      );
      var transportDisposed = false;
      final runtime = ChkszRuntime(
        credentialProvider: credentials,
        transport: transport,
        disposeTransport: () => transportDisposed = true,
      );
      final token = ChkszCancelToken();
      final search = runtime.searchNetease(
        keyword: 'Test Track',
        cancelToken: token,
      );
      await Future<void>.delayed(Duration.zero);

      runtime.dispose();
      runtime.dispose();
      expect(token.isCancelled, isTrue);
      expect(transportDisposed, isTrue);
      expect(credentials.clearCount, 0);
      expect(await credentials.readApiKey(), _fakeApiKey);
      expect(
        () => runtime.searchNetease(
          keyword: 'Test Track',
          cancelToken: ChkszCancelToken(),
        ),
        throwsStateError,
      );

      response.complete(
        ChkszTransportResponse(statusCode: 200, data: _searchBody()),
      );
      expect(
        (await _captureChkszException(search)).kind,
        ChkszErrorKind.cancelled,
      );
    },
  );
}

Future<void> _setQuota(ChkszRuntime runtime, _FakeTransport transport) async {
  final originalHandler = transport.handler;
  transport.handler = (_, _) async => ChkszTransportResponse(
    statusCode: 200,
    data: _searchBody(),
    headers: const {
      'X-Quota-Free-Remaining': ['7'],
    },
  );
  await runtime.searchNetease(
    keyword: 'Test Track',
    cancelToken: ChkszCancelToken(),
  );
  transport.handler = originalHandler;
  expect(runtime.quota?.freeRemaining, 7);
  transport.tokens.clear();
}

Map<String, dynamic> _searchBody() => {
  'code': 200,
  'msg': 'success',
  'data': {
    'songs': [
      {
        'id': 123456,
        'name': 'Test Track',
        'artists': 'Test Artist',
        'album': 'Test Album',
        'picUrl': 'https://cover.invalid/test.jpg',
        'duration': 123456,
      },
    ],
    'total': 1,
  },
};

Map<String, dynamic> _resolveBody() => {
  'code': 200,
  'msg': 'success',
  'data': {
    'id': 123456,
    'url': 'https://media.invalid/test.flac',
    'br': 1000000,
    'level': 'lossless',
  },
};

Future<ChkszException> _captureChkszException(Future<Object?> future) async {
  try {
    await future;
  } on ChkszException catch (error) {
    return error;
  }
  throw StateError('Expected ChkszException');
}

typedef _TransportHandler =
    Future<ChkszTransportResponse> Function(
      ChkszAuthorizedRequest request,
      ChkszCancelToken cancelToken,
    );

final class _FakeTransport implements ChkszTransport {
  _FakeTransport(this.handler);

  _TransportHandler handler;
  final List<ChkszCancelToken> tokens = [];

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) {
    tokens.add(cancelToken);
    return handler(request, cancelToken);
  }
}

final class _RuntimePlaybackBackend implements PlaybackBackend {
  final _states = StreamController<PlaybackBackendState>.broadcast();
  final List<PlaybackSource> opened = [];

  @override
  Stream<PlaybackBackendState> get stateStream => _states.stream;

  @override
  Future<void> open(PlaybackSource source) async {
    opened.add(source);
    _states.add(PlaybackBackendState.playing);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() => _states.close();
}

final class _RecordingCredentialProvider implements ChkszCredentialProvider {
  _RecordingCredentialProvider({
    required String initialApiKey,
    this.onWrite,
    this.clearError,
  }) : _apiKey = initialApiKey;

  String? _apiKey;
  final void Function()? onWrite;
  final Object? clearError;
  int clearCount = 0;

  @override
  Future<String?> readApiKey() async => _apiKey;

  @override
  Future<void> writeApiKey(String apiKey) async {
    onWrite?.call();
    _apiKey = apiKey;
  }

  @override
  Future<void> clearApiKey() async {
    clearCount++;
    final error = clearError;
    if (error != null) throw error;
    _apiKey = null;
  }
}
