import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';
const _ref = PlatformTrackRef(
  platform: MusicPlatform.netease,
  trackId: '123456',
);

void main() {
  group('OnlineMusicProviderRegistry routing', () {
    test('routes every capability to its own provider', () async {
      final data = _RecordingProvider('a');
      final playback = _RecordingProvider('b');
      final registry = OnlineMusicProviderRegistry(
        providers: [data, playback],
        defaultProviderId: 'a',
        capabilityProviders: {
          OnlineMusicCapability.playlist: 'b',
          OnlineMusicCapability.stream: 'b',
        },
      );
      final service = CompositeOnlineMusicService(registry: registry);

      await service.search(
        platform: MusicPlatform.netease,
        keyword: 'test',
        cancelToken: OnlineMusicCancelToken(),
      );
      await service.fetchPlaylist(
        platform: MusicPlatform.netease,
        playlistId: '5202687076',
        cancelToken: OnlineMusicCancelToken(),
      );
      await service.fetchLyrics(_ref, cancelToken: OnlineMusicCancelToken());
      await service.resolve(
        _ref,
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(data.calls, ['search', 'lyric']);
      expect(playback.calls, ['playlist', 'resolve']);
    });

    test('playback can differ from every data capability at once', () async {
      final search = _RecordingProvider('search-only');
      final playlist = _RecordingProvider('playlist-only');
      final lyric = _RecordingProvider('lyric-only');
      final playback = _RecordingProvider('playback-only');
      final registry = OnlineMusicProviderRegistry(
        providers: [search, playlist, lyric, playback],
        defaultProviderId: 'search-only',
        capabilityProviders: {
          OnlineMusicCapability.playlist: 'playlist-only',
          OnlineMusicCapability.lyric: 'lyric-only',
          OnlineMusicCapability.stream: 'playback-only',
        },
      );

      expect(
        registry.providerIdFor(OnlineMusicCapability.search),
        'search-only',
      );
      expect(
        registry.providerIdFor(OnlineMusicCapability.playlist),
        'playlist-only',
      );
      expect(registry.providerIdFor(OnlineMusicCapability.lyric), 'lyric-only');
      expect(
        registry.providerIdFor(OnlineMusicCapability.stream),
        'playback-only',
      );
    });

    test('an unregistered target falls back to the default provider', () {
      final data = _RecordingProvider('a');
      final registry = OnlineMusicProviderRegistry(
        providers: [data],
        defaultProviderId: 'a',
        capabilityProviders: {OnlineMusicCapability.stream: 'missing'},
      );

      expect(registry.providerIdFor(OnlineMusicCapability.stream), 'a');
      expect(registry.providerIdFor(OnlineMusicCapability.search), 'a');
    });

    test('an unregistered default falls back to the first provider', () {
      final first = _RecordingProvider('a');
      final second = _RecordingProvider('b');
      final registry = OnlineMusicProviderRegistry(
        providers: [first, second],
        defaultProviderId: 'missing',
      );

      expect(registry.defaultProvider, same(first));
      expect(registry.providerIdFor(OnlineMusicCapability.search), 'a');
    });

    test('keeps the first registration for a duplicated provider id', () {
      final first = _RecordingProvider('a');
      final duplicate = _RecordingProvider('a');
      final registry = OnlineMusicProviderRegistry(
        providers: [first, duplicate],
      );

      expect(registry.providers, hasLength(1));
      expect(registry.defaultProvider, same(first));
    });

    test('requires at least one provider', () {
      expect(
        () => OnlineMusicProviderRegistry(providers: const []),
        throwsArgumentError,
      );
    });

    test('aggregates capability platforms from every usable provider', () {
      final neteaseProvider = _RecordingProvider('a');
      final qqProvider = _RecordingProvider(
        'b',
        platforms: const {MusicPlatform.qq},
      );
      final registry = OnlineMusicProviderRegistry(
        providers: [neteaseProvider, qqProvider],
        capabilityProviders: {OnlineMusicCapability.stream: 'b'},
      );

      final service = CompositeOnlineMusicService(registry: registry);
      final capabilities = service.capabilities;

      // S3：平台集合按 `(platform, capability)` **候选求并集**，而不是"只看被选中的
      // 那一个 Provider 声明了什么"。旧语义下 qq 只会出现在 stream 一项里，netease
      // 也不会同时出现在 stream 上 —— 多平台聚合下这是错的。
      expect(capabilities.searchablePlatforms, {
        MusicPlatform.netease,
        MusicPlatform.qq,
      });
      expect(capabilities.playlistPlatforms, {
        MusicPlatform.netease,
        MusicPlatform.qq,
      });
      expect(capabilities.lyricPlatforms, {
        MusicPlatform.netease,
        MusicPlatform.qq,
      });
      expect(capabilities.resolvablePlatforms, {
        MusicPlatform.netease,
        MusicPlatform.qq,
      });
      expect(capabilities.unavailableSearchReasons, isEmpty);
    });

    test('disposes every registered provider exactly once', () {
      final data = _RecordingProvider('a');
      final shared = _RecordingProvider('a');
      final playback = _RecordingProvider('b');
      final registry = OnlineMusicProviderRegistry(
        providers: [data, shared, playback],
      );

      CompositeOnlineMusicService(registry: registry).dispose();

      expect(data.disposeCount, 1);
      expect(playback.disposeCount, 1);
      expect(shared.disposeCount, 0);
    });

    test('delegates the default quality to the playback provider', () {
      final data = _RecordingProvider('a', quality: 'standard');
      final playback = _RecordingProvider('b', quality: 'hires');
      final registry = OnlineMusicProviderRegistry(
        providers: [data, playback],
        capabilityProviders: {OnlineMusicCapability.stream: 'b'},
      );

      expect(
        CompositeOnlineMusicService(
          registry: registry,
        ).defaultQualityFor(MusicPlatform.netease),
        'hires',
      );
    });
  });

  group('capability auth boundary', () {
    test('authenticates per capability inside one provider', () async {
      final transport = _RecordingTransport();
      final catalog = MusicCatalogService(
        client: ChkszClient(
          transport: transport,
          credentialProvider: InMemoryChkszCredentialProvider(
            initialApiKey: _fakeApiKey,
          ),
        ),
        authResolver: (capability) => capability == OnlineMusicCapability.search
            ? const OnlineMusicNoAuth()
            : const OnlineMusicApiKeyAuth(),
      );

      await catalog.search(keyword: 'test', cancelToken: ChkszCancelToken());
      await catalog.fetchLyrics(ref: _ref, cancelToken: ChkszCancelToken());

      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.first.queryParameters.containsKey('apikey'),
        isFalse,
      );
      expect(transport.requests.last.queryParameters['apikey'], _fakeApiKey);
    });

    test(
      'a credential-free provider never touches the credential source',
      () async {
        final credentials = _UnusedCredentialProvider();
        final transport = _RecordingTransport();
        final runtime = ChkszRuntime(
          credentialProvider: credentials,
          transport: transport,
          authResolver: (capability) => const OnlineMusicNoAuth(),
        );
        final provider = ChkszOnlineMusicProvider(runtime: runtime);

        await provider.search(
          platform: MusicPlatform.netease,
          keyword: 'test',
          cancelToken: OnlineMusicCancelToken(),
        );

        expect(credentials.readCount, 0);
        expect(transport.requests.single.queryParameters, {
          'keyword': 'test',
          'limit': '30',
          'offset': '0',
        });
        provider.dispose();
      },
    );

    test('the provider reports its own per-capability auth', () {
      final runtime = ChkszRuntime(
        transport: _RecordingTransport(),
        authResolver: (capability) => capability == OnlineMusicCapability.lyric
            ? const OnlineMusicApiKeyAuth()
            : const OnlineMusicNoAuth(),
      );
      final provider = ChkszOnlineMusicProvider(runtime: runtime);

      expect(
        provider.authFor(OnlineMusicCapability.search),
        isA<OnlineMusicNoAuth>(),
      );
      expect(
        provider.authFor(OnlineMusicCapability.lyric),
        isA<OnlineMusicApiKeyAuth>(),
      );
      provider.dispose();
    });

    test('an unsupported platform is reported as unavailable', () async {
      final provider = ChkszOnlineMusicProvider(
        runtime: ChkszRuntime(transport: _RecordingTransport()),
      );

      await expectLater(
        provider.fetchLyrics(
          const PlatformTrackRef(platform: MusicPlatform.qq, trackId: '123456'),
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.unavailable,
          ),
        ),
      );
      provider.dispose();
    });
  });
}

final class _RecordingProvider extends UnsupportedOnlineMusicProvider {
  _RecordingProvider(
    this.providerId, {
    this.platforms = const {MusicPlatform.netease},
    this.quality = 'lossless',
  });

  @override
  final String providerId;

  final Set<MusicPlatform> platforms;
  final String quality;
  final List<String> calls = [];
  int disposeCount = 0;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      platforms;

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    calls.add('search');
    return MusicSearchPage(platform: platform, items: const []);
  }

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    calls.add('playlist');
    return RemotePlaylist(platform: platform, id: playlistId, name: 'n');
  }

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    calls.add('lyric');
    return const MusicLyrics();
  }

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    calls.add('resolve');
    return ResolvedStream(
      ref: ref,
      uri: Uri.parse('https://media.invalid/test.flac'),
      requestedQuality: requestedQuality,
      resolvedAt: DateTime.utc(2026, 8, 14),
    );
  }

  @override
  String defaultQualityFor(MusicPlatform platform) => quality;

  @override
  void dispose() => disposeCount++;
}

final class _RecordingTransport implements ChkszTransport {
  final List<ChkszAuthorizedRequest> requests = [];

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) async {
    requests.add(request);
    return ChkszTransportResponse(
      statusCode: 200,
      data: const {
        'code': 200,
        'msg': 'success',
        'data': {'songs': <Object?>[], 'total': 0, 'lrc': '[00:01.00]line'},
      },
    );
  }
}

final class _UnusedCredentialProvider implements ChkszCredentialProvider {
  int readCount = 0;

  @override
  Future<String?> readApiKey() async {
    readCount++;
    return _fakeApiKey;
  }

  @override
  Future<void> writeApiKey(String apiKey) async {}

  @override
  Future<void> clearApiKey() async {}
}
