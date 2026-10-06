import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
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
