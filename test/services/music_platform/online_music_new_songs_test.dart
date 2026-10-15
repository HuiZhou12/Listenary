import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// 新歌（newSongs）。
///
/// 与前几种内容不同：它**返回的就是曲目**，因此**不新增领域字段**、也**不需要新的映射函数**
/// （与搜索同构）。但真实响应的曲目信息是**嵌在 `song` 里**的，所以字段路径必须写对 ——
/// 这个测试用真实样本把路径钉住。
void main() {
  const netease = MusicPlatform.netease;

  JsonPath p(String source) => JsonPath.tryParse(source)!;

  /// **真实响应样本**：字段名与嵌套形状取自对
  /// `http://127.0.0.1:3000/personalized/newsong?limit=2` 的实际请求
  /// （`code=200`，元素含 `id/type/name/picUrl/song{...}`；此处按原样保留嵌套与字段名）。
  const realNewsongSample = <String, Object?>{
    'code': 200,
    'category': 0,
    'result': [
      {
        'id': 3436855494,
        'type': 4,
        'name': '自由的你',
        'picUrl':
            'http://p1.music.126.net/G4Vtk4Je9Sj8zB4KGlxprw==/109951174017350276.jpg',
        'song': {
          'id': 3436855494,
          'name': '自由的你',
          'duration': 296900,
          'artists': [
            {'id': 7763, 'name': 'G.E.M.邓紫棋'},
          ],
          'album': {
            'id': 348196141,
            'name': '自由的你',
            'picUrl':
                'http://p3.music.126.net/G4Vtk4Je9Sj8zB4KGlxprw==/109951174017350276.jpg',
          },
        },
      },
      {
        'id': 3436352693,
        'type': 4,
        'name': '第二首',
        'song': {
          'id': 3436352693,
          'name': '第二首',
          'duration': 210000,
          'artists': [
            {'id': 1, 'name': '甲'},
            {'id': 2, 'name': '乙'},
          ],
          'album': {'id': 2, 'name': '某专辑'},
        },
      },
    ],
  };

  OnlineMusicResponseSpec newSongSpec({
    OnlineMusicFieldTransform durationTransform =
        OnlineMusicFieldTransform.asDurationMs,
  }) => OnlineMusicResponseSpec(
    listPath: p('result'),
    fields: {
      OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
        candidates: [p('song.id')],
        transform: OnlineMusicFieldTransform.asInt,
        required: true,
      ),
      OnlineMusicDomainField.title: OnlineMusicFieldSpec(
        candidates: [p('song.name')],
        transform: OnlineMusicFieldTransform.asString,
        required: true,
      ),
      OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
        candidates: [p('song.artists[*].name')],
        transform: OnlineMusicFieldTransform.asStringList,
      ),
      OnlineMusicDomainField.album: OnlineMusicFieldSpec(
        candidates: [p('song.album.name')],
        transform: OnlineMusicFieldTransform.asString,
      ),
      OnlineMusicDomainField.coverUri: OnlineMusicFieldSpec(
        candidates: [p('song.album.picUrl')],
        transform: OnlineMusicFieldTransform.asHttpsUri,
      ),
      OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
        candidates: [p('song.duration')],
        transform: durationTransform,
      ),
    },
  );

  group('新歌映射（真实嵌套样本）', () {
    test('从 result[].song.* 映射出曲目：身份、艺人、专辑、时长、https 封面', () {
      final tracks = mapDeclarativeSearchResponse(
        spec: newSongSpec(),
        body: realNewsongSample,
        platform: netease,
        limit: 30,
        offset: 0,
      ).items;

      expect(tracks, hasLength(2));
      final first = tracks.first;
      expect(first.ref.platform, netease);
      expect(first.ref.trackId, '3436855494');
      expect(first.title, '自由的你');
      expect(first.artistDisplay, 'G.E.M.邓紫棋');
      expect(first.album, '自由的你');
      expect(first.duration, const Duration(milliseconds: 296900));
      // http 被提升为 https（与既有封面行为一致）。
      expect(first.coverUri?.scheme, 'https');
      // 多艺人按顺序保留。
      expect(tracks.last.artists, ['甲', '乙']);
      expect(tracks.last.coverUri, isNull);
    });

    // 时长单位：**域模型定的是毫秒**，但平台不一定这么给 ——
    // 网易云 `song.duration` 是毫秒（实测 296900），而 QQ `getNewSongs` 的 `interval` 是**秒**（实测 188）。
    // 因此 DSL 提供了两个转换；**`asDurationSeconds` 此前一条测试都没有**，
    // 而它正是"接 QQ 那种服务"时会用到的那个 —— 用错单位的表现是每首都显示 0:00。
    group('时长单位（秒）', () {
    Map<String, Object?> bodyWith(Object? duration) => {
      'code': 200,
      'result': [
        {
          'id': 1,
          'name': '某首歌',
          'artists': [
            {'name': '甲'},
          ],
          'album': {'name': '某专辑'},
          'song': {'id': 1, 'name': '某首歌', 'duration': duration},
        },
      ],
    };

    List<MusicTrack> mapWith(
      OnlineMusicFieldTransform transform,
      Map<String, Object?> body,
    ) => mapDeclarativeSearchResponse(
      spec: newSongSpec(durationTransform: transform),
      body: body,
      platform: netease,
      limit: 30,
      offset: 0,
    ).items;

    test('★ asDurationSeconds：188 秒 → 188s（而不是 188ms）', () {
      final track = mapWith(
        OnlineMusicFieldTransform.asDurationSeconds,
        bodyWith(188),
      ).single;

      expect(track.duration, const Duration(seconds: 188));
      expect(track.duration.inMilliseconds, 188000);
    });

    test('★ 秒值以**字符串**给出时也能转（JSON 里数字常被写成字符串）', () {
      final track = mapWith(
        OnlineMusicFieldTransform.asDurationSeconds,
        bodyWith('188'),
      ).single;

      expect(track.duration, const Duration(seconds: 188));
    });

    test('★ 单位必须真的生效：同一份样本按"秒"与按"毫秒"解析相差 1000 倍', () {
      // 这条防的是"两个转换其实做了一样的事"（静默退化成同一个）：
      // 真那样的话，接秒制平台时每首歌都会变成 0:00，而这种错误**不会报错**。
      final asSeconds = mapWith(
        OnlineMusicFieldTransform.asDurationSeconds,
        bodyWith(188),
      ).single;
      final asMillis = mapWith(
        OnlineMusicFieldTransform.asDurationMs,
        bodyWith(188),
      ).single;

      expect(
        asSeconds.duration.inMilliseconds,
        asMillis.duration.inMilliseconds * 1000,
      );
      expect(asMillis.duration, const Duration(milliseconds: 188));
    });

    test('时长字段缺失时不硬造一个假时长', () {
      final body = bodyWith(null);
      final track = mapWith(
        OnlineMusicFieldTransform.asDurationSeconds,
        body,
      ).single;

      expect(track.duration, Duration.zero);
    });
    });

    test('缺必填字段时明确失败，不产生半条曲目', () {
      expect(
        () => mapDeclarativeSearchResponse(
          spec: newSongSpec(),
          body: const {
            'result': [
              {
                'song': {'id': 1},
              },
            ],
          },
          platform: netease,
          limit: 30,
          offset: 0,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });
  });

  group('新歌能力的字段集与配置校验', () {
    test('字段集与搜索完全相同（不新增领域字段）', () {
      expect(
        domainFieldsFor(OnlineMusicCapability.newSongs),
        domainFieldsFor(OnlineMusicCapability.search),
      );
    });

    test('必填字段是曲目 id 与标题', () {
      expect(requiredFieldsFor(OnlineMusicCapability.newSongs), {
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
      });
    });

    test('没有列表路径时报配置问题', () {
      final issues = const OnlineMusicResponseSpec(fields: {}).validationIssues(
        OnlineMusicCapability.newSongs,
      );
      expect(issues, contains('新歌能力必须配置列表路径'));
    });
  });

  group('接进 DeclarativeMusicProvider / 服务层', () {
    test('fetchNewSongs 走自己的绑定，输出曲目数组', () async {
      final provider = DeclarativeMusicProvider(
        providerId: 'news',
        bindings: {
          OnlineMusicCapability.newSongs:
              OnlineMusicDeclarativeCapabilityBinding(
                request: const OnlineMusicRequestSpec(
                  path: '/personalized/newsong',
                  query: [
                    OnlineMusicParamBinding(
                      name: 'limit',
                      source: OnlineMusicInputSource.limit,
                    ),
                  ],
                ),
                response: newSongSpec(),
              ),
        },
        transport: _RecordingTransport(
          const DeclarativeHttpResponse(
            statusCode: 200,
            data: realNewsongSample,
          ),
        ),
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      final tracks = await provider.fetchNewSongs(
        platform: netease,
        limit: 30,
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(provider.platformsFor(OnlineMusicCapability.newSongs), {netease});
      expect(tracks.map((track) => track.title), ['自由的你', '第二首']);
    });

    test('没有配置该绑定时报"不支持"，不伪装成空列表', () async {
      final provider = DeclarativeMusicProvider(
        providerId: 'none',
        bindings: const {},
        transport: _RecordingTransport(
          const DeclarativeHttpResponse(statusCode: 200, data: {}),
        ),
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      await expectLater(
        provider.fetchNewSongs(
          platform: netease,
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
    });

    test('★ 只列新歌、没有播放解析的平台：列表里不该出现（点不响比不显示更糟）', () {
      final listOnly = _NewSongProvider(
        'listOnly',
        platforms: const {MusicPlatform.qq},
      );
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: [listOnly]),
      );

      expect(service.capabilities.newSongPlatforms, {MusicPlatform.qq});
      expect(service.capabilities.resolvablePlatforms, isEmpty);
      // ★ 关键：不能播放 ⇒ 不算"可播放的新歌"。
      expect(service.capabilities.playableNewSongPlatforms, isEmpty);
    });

    test('同时具备新歌与播放解析时才算可播放', () {
      final both = _NewSongProvider(
        'both',
        platforms: const {netease},
        alsoStream: true,
      );
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: [both]),
      );

      expect(service.capabilities.playableNewSongPlatforms, {netease});
    });

    test('没有候选的平台明确 unavailable', () async {
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(
          providers: [_NewSongProvider('none', platforms: const {})],
        ),
      );

      await expectLater(
        service.fetchNewSongs(
          platform: netease,
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
    });
  });
}

/// 只实现"新歌"（可选再加"播放解析"）的 Provider 替身。
final class _NewSongProvider extends UnsupportedOnlineMusicProvider {
  @override
  Future<List<RemotePlaylistSummary>> fetchPersonalizedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Personalized playlists are not implemented here');

  @override
  Future<List<OnlineArtistSummary>> fetchFollowedArtists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Followed artists are not implemented here');

  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended playlists are not implemented here');

  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

  _NewSongProvider(
    this.providerId, {
    required this.platforms,
    this.alsoStream = false,
  });

  @override
  final String providerId;

  final Set<MusicPlatform> platforms;
  final bool alsoStream;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      switch (capability) {
        OnlineMusicCapability.newSongs => platforms,
        OnlineMusicCapability.stream when alsoStream => platforms,
        _ => const {},
      };

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    MusicTrack(
      ref: PlatformTrackRef(platform: platform, trackId: 'n1'),
      title: '新歌一',
      artists: const ['甲'],
    ),
  ];

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async => throw unsupportedCapability();
}

final class _RecordingTransport implements DeclarativeHttpTransport {
  _RecordingTransport(this.response);

  final DeclarativeHttpResponse response;
  final List<BuiltDeclarativeRequest> requests = [];

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requests.add(request);
    return response;
  }
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();

  @override
  Future<String?> readCredential(String reference) async => null;
}
