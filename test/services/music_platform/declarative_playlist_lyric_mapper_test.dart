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

/// S7a：声明式 playlist / lyric 的**映射器**。
///
/// 本切片只做映射落地与接线，**不动"第二阶段"守卫**（那属于 S7b），
/// 因此对外行为零变化：没有任何路径能保存出这类绑定，Provider 也不会被调用到。
void main() {
  const netease = MusicPlatform.netease;
  JsonPath p(String source) => JsonPath.tryParse(source)!;

  group('mapDeclarativePlaylistResponse', () {
    final spec = OnlineMusicResponseSpec(
      fieldsRootPath: p('playlist'),
      listPath: p('playlist.tracks'),
      fields: {
        OnlineMusicDomainField.playlistId: OnlineMusicFieldSpec(
          candidates: [p('id')],
          transform: OnlineMusicFieldTransform.asString,
        ),
        OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
          candidates: [p('name')],
          transform: OnlineMusicFieldTransform.asString,
        ),
        OnlineMusicDomainField.playlistCreator: OnlineMusicFieldSpec(
          candidates: [p('creator.nickname')],
          transform: OnlineMusicFieldTransform.asString,
        ),
        OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
          candidates: [p('id')],
          transform: OnlineMusicFieldTransform.asString,
          required: true,
        ),
        OnlineMusicDomainField.title: OnlineMusicFieldSpec(
          candidates: [p('name')],
          transform: OnlineMusicFieldTransform.asString,
          required: true,
        ),
      },
    );

    test('读出歌单元数据与曲目，曲目带自己的来源身份（I1）', () {
      final playlist = mapDeclarativePlaylistResponse(
        spec: spec,
        body: const {
          'playlist': {
            'id': '24381616',
            'name': '我喜欢的音乐',
            'creator': {'nickname': '某人'},
            'tracks': [
              {'id': 347230, 'name': '海阔天空'},
              {'id': 65800, 'name': '最佳损友'},
            ],
          },
        },
        platform: netease,
        requestedPlaylistId: 'fallback',
      );

      expect(playlist.platform, netease);
      expect(playlist.id, '24381616');
      expect(playlist.name, '我喜欢的音乐');
      expect(playlist.creator, '某人');
      expect(playlist.tracks, hasLength(2));
      expect(playlist.tracks.first.ref.platform, netease);
      expect(playlist.tracks.first.ref.trackId, '347230');
      expect(playlist.tracks[1].title, '最佳损友');
    });

    test('歌单 id 映射取不到时回落到请求里的 id（不算映射失败）', () {
      final playlist = mapDeclarativePlaylistResponse(
        spec: OnlineMusicResponseSpec(
          fieldsRootPath: p('playlist'),
          fields: {
            OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
              candidates: [p('name')],
              transform: OnlineMusicFieldTransform.asString,
            ),
          },
        ),
        body: const {
          'playlist': {'name': '无 id 歌单'},
        },
        platform: netease,
        requestedPlaylistId: 'requested_id',
      );

      expect(playlist.id, 'requested_id');
      expect(playlist.tracks, isEmpty);
    });

    test('列表路径配了但取不到数组 → 映射失败（endpointMismatch 的来源）', () {
      expect(
        () => mapDeclarativePlaylistResponse(
          spec: OnlineMusicResponseSpec(
            listPath: p('playlist.tracks'),
            fields: const {},
          ),
          body: const {
            'playlist': {'tracks': 'not-a-list'},
          },
          platform: netease,
          requestedPlaylistId: 'x',
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });
  });

  group('mapDeclarativeLyricsResponse', () {
    final spec = OnlineMusicResponseSpec(
      fieldsRootPath: p('lrc'),
      fields: {
        OnlineMusicDomainField.lyricOriginal: OnlineMusicFieldSpec(
          candidates: [p('lyric')],
          transform: OnlineMusicFieldTransform.asString,
        ),
        OnlineMusicDomainField.lyricTranslation: OnlineMusicFieldSpec(
          candidates: [p('tlyric.lyric')],
          transform: OnlineMusicFieldTransform.asString,
        ),
      },
    );
    const ref = PlatformTrackRef(platform: netease, trackId: '347230');

    test('读出原文与翻译，并带上来源', () {
      final lyrics = mapDeclarativeLyricsResponse(
        spec: spec,
        body: const {
          'lrc': {
            'lyric': '[00:00.00]海阔天空',
            'tlyric': {'lyric': 'translated'},
          },
        },
        ref: ref,
      );

      expect(lyrics.original, '[00:00.00]海阔天空');
      expect(lyrics.translation, 'translated');
      expect(lyrics.ref, ref);
    });

    test('纯音乐：字段读到空是正常空结果，不是映射失败', () {
      final lyrics = mapDeclarativeLyricsResponse(
        spec: spec,
        body: const {
          'lrc': {'lyric': ''},
        },
        ref: ref,
      );

      expect(lyrics.isEmpty, isTrue);
      expect(lyrics.ref, ref);
    });

    test('一个歌词字段都没配置 → 明确报配置错误（不能让用户以为"这首没歌词"）', () {
      expect(
        () => mapDeclarativeLyricsResponse(
          spec: OnlineMusicResponseSpec(fieldsRootPath: p('lrc')),
          body: const {
            'lrc': {'lyric': 'whatever'},
          },
          ref: ref,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });
  });

  group('接进 DeclarativeMusicProvider', () {
    DeclarativeMusicProvider providerWith(
      OnlineMusicDeclarativeCapabilityBinding playlistBinding,
      _StubTransport transport,
    ) => DeclarativeMusicProvider(
      providerId: 'declarativeA',
      bindings: {OnlineMusicCapability.playlist: playlistBinding},
      transport: transport,
      credentials: const _NoCredentialReader(),
      contentPlatform: netease,
    );

    test('声明式歌单能取到 RemotePlaylist，曲目来源不丢', () async {
      final provider = providerWith(
        OnlineMusicDeclarativeCapabilityBinding(
          request: const OnlineMusicRequestSpec(
            path: '/playlist/detail',
            query: [
              OnlineMusicParamBinding(
                name: 'id',
                source: OnlineMusicInputSource.playlistId,
                required: true,
              ),
            ],
          ),
          response: OnlineMusicResponseSpec(
            fieldsRootPath: p('playlist'),
            listPath: p('playlist.tracks'),
            fields: {
              OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
                candidates: [p('name')],
                transform: OnlineMusicFieldTransform.asString,
              ),
              OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
                candidates: [p('id')],
                transform: OnlineMusicFieldTransform.asString,
                required: true,
              ),
              OnlineMusicDomainField.title: OnlineMusicFieldSpec(
                candidates: [p('name')],
                transform: OnlineMusicFieldTransform.asString,
                required: true,
              ),
            },
          ),
        ),
        _StubTransport(
          const DeclarativeHttpResponse(
            statusCode: 200,
            data: {
              'playlist': {
                'name': '自建歌单',
                'tracks': [
                  {'id': 1, 'name': 'A'},
                ],
              },
            },
          ),
        ),
      );

      final playlist = await provider.fetchPlaylist(
        platform: netease,
        playlistId: '999',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(playlist.id, '999');
      expect(playlist.name, '自建歌单');
      expect(
        playlist.tracks.single.ref,
        const PlatformTrackRef(platform: netease, trackId: '1'),
      );
    });
  });

  group('歌单集合（playlistCollection，Spec §19.2）', () {
    final spec = OnlineMusicResponseSpec(
      listPath: p('data.list'),
      fields: {
        OnlineMusicDomainField.playlistId: OnlineMusicFieldSpec(
          candidates: [p('id')],
          transform: OnlineMusicFieldTransform.asString,
          required: true,
        ),
        OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
          candidates: [p('name')],
          transform: OnlineMusicFieldTransform.asString,
          required: true,
        ),
        OnlineMusicDomainField.playlistCreator: OnlineMusicFieldSpec(
          candidates: [p('creator')],
          transform: OnlineMusicFieldTransform.asString,
        ),
        OnlineMusicDomainField.playlistTrackCount: OnlineMusicFieldSpec(
          candidates: [p('count')],
          transform: OnlineMusicFieldTransform.asInt,
        ),
      },
    );

    test('把数组映射成歌单摘要：来源身份完整、不含曲目', () {
      final summaries = mapDeclarativePlaylistCollectionResponse(
        spec: spec,
        body: const {
          'data': {
            'list': [
              {'id': 111, 'name': '歌单一', 'creator': '甲', 'count': 12},
              {'id': '222', 'name': '歌单二'},
            ],
          },
        },
        platform: netease,
      );

      expect(summaries, hasLength(2));
      expect(summaries.first.platform, netease);
      expect(summaries.first.id, '111');
      expect(summaries.first.name, '歌单一');
      expect(summaries.first.creator, '甲');
      expect(summaries.first.trackCount, 12);
      expect(summaries.last.id, '222');
      expect(summaries.last.creator, isNull);
    });

    test('缺必填字段 / 路径取不到数组 / 没配列表路径时明确失败', () {
      expect(
        () => mapDeclarativePlaylistCollectionResponse(
          spec: spec,
          body: const {
            'data': {
              'list': [
                {'id': 1},
              ],
            },
          },
          platform: netease,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
      expect(
        () => mapDeclarativePlaylistCollectionResponse(
          spec: spec,
          body: const {
            'data': {'list': 1},
          },
          platform: netease,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
      expect(
        () => mapDeclarativePlaylistCollectionResponse(
          spec: const OnlineMusicResponseSpec(fields: {}),
          body: const {},
          platform: netease,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });

    test('歌单集合的字段集里**没有**曲目字段（与歌单详情是两个语义）', () {
      final fields = domainFieldsFor(OnlineMusicCapability.playlistCollection);
      expect(fields, contains(OnlineMusicDomainField.playlistId));
      expect(fields, contains(OnlineMusicDomainField.playlistTrackCount));
      expect(fields.contains(OnlineMusicDomainField.trackId), isFalse);
      expect(fields.contains(OnlineMusicDomainField.title), isFalse);
    });

    test('接进 DeclarativeMusicProvider：请求带 limit/offset，结果带来源', () async {
      final provider = DeclarativeMusicProvider(
        providerId: 'collections',
        bindings: {
          OnlineMusicCapability.playlistCollection:
              OnlineMusicDeclarativeCapabilityBinding(
                request: const OnlineMusicRequestSpec(
                  path: '/top/playlist',
                  query: [
                    OnlineMusicParamBinding(
                      name: 'limit',
                      source: OnlineMusicInputSource.limit,
                    ),
                    OnlineMusicParamBinding(
                      name: 'offset',
                      source: OnlineMusicInputSource.offset,
                    ),
                  ],
                ),
                response: OnlineMusicResponseSpec(
                  listPath: p('playlists'),
                  fields: {
                    OnlineMusicDomainField.playlistId: OnlineMusicFieldSpec(
                      candidates: [p('id')],
                      transform: OnlineMusicFieldTransform.asString,
                      required: true,
                    ),
                    OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
                      candidates: [p('name')],
                      transform: OnlineMusicFieldTransform.asString,
                      required: true,
                    ),
                  },
                ),
              ),
        },
        transport: _StubTransport(
          const DeclarativeHttpResponse(
            statusCode: 200,
            data: {
              'playlists': [
                {'id': 1, 'name': '推荐一'},
              ],
            },
          ),
        ),
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      final summaries = await provider.fetchPlaylistCollection(
        platform: netease,
        limit: 10,
        offset: 20,
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(provider.platformsFor(OnlineMusicCapability.playlistCollection), {
        netease,
      });
      expect(summaries.single.name, '推荐一');
      expect(summaries.single.platform, netease);
    });

    test('服务层按平台路由，且与歌单详情各算各的候选', () async {
      final provider = _CollectionProvider(
        'qqCollections',
        platforms: const {MusicPlatform.qq},
      );
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: [provider]),
      );

      expect(service.capabilities.playlistCollectionPlatforms, {
        MusicPlatform.qq,
      });
      // 只声明了"歌单集合"⇒"歌单详情"仍然没有候选，两者不互相顶替。
      expect(service.capabilities.playlistPlatforms, isEmpty);

      final summaries = await service.fetchPlaylistCollection(
        platform: MusicPlatform.qq,
        limit: 10,
        offset: 30,
        cancelToken: OnlineMusicCancelToken(),
      );
      expect(summaries.single.id, 'p30');
      expect(provider.offsets, [30]);

      // 没有候选的平台：明确 unavailable，不静默换平台。
      await expectLater(
        service.fetchPlaylistCollection(
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

final class _CollectionProvider extends UnsupportedOnlineMusicProvider {
  _CollectionProvider(this.providerId, {required this.platforms});

  @override
  final String providerId;

  final Set<MusicPlatform> platforms;
  final List<int> offsets = [];

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      capability == OnlineMusicCapability.playlistCollection
      ? platforms
      : const {};

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    offsets.add(offset);
    return [
      RemotePlaylistSummary(
        platform: platform,
        id: 'p$offset',
        name: '歌单$offset',
      ),
    ];
  }
}

final class _StubTransport implements DeclarativeHttpTransport {
  _StubTransport(this.response);

  final DeclarativeHttpResponse response;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async => response;
}

final class _NoCredentialReader implements OnlineMusicCredentialReader {
  const _NoCredentialReader();

  @override
  Future<String?> readCredential(String reference) async => null;
}
