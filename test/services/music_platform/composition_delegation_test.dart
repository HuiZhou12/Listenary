import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/online_music_composition.dart';

/// **组合层必须"按能力转发"**（2026-10-16 ✓）。
///
/// 为什么要有这个文件：`_ConfiguredMusicProvider` 是**按能力分派**的包装类 ✓，
/// 一旦某个方法被写成"自己抛未实现"（历史上就是这么被自动补桩顶掉的 ✗），
/// 那个能力就会**在运行期永远调不到真正的实现** ✗ ——
/// 而**试跑**走的是另一条链路 ✓ ⇒ 会出现"试跑正常、主页一直失败"这种最难查的现象 ✓。
///
/// 这里用**连不上的本地端口**当靶子 ✓：
/// - 如果方法真的转发 ✓ ⇒ 会去连接 ⇒ 抛网络/服务类错误 ✓；
/// - 如果被桩顶掉 ✗ ⇒ 会**同步**抛 `UnsupportedError('... not implemented here')` ✓。
/// 于是"**错误绝不能是未实现**"就成了一条便宜又确定的守卫 ✓（不依赖任何外部服务 ✓）。
JsonPath _p(String source) => JsonPath.tryParse(source)!;

Map<String, Object?> _trackListBinding() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/recommend/songs'),
      response: OnlineMusicResponseSpec(
        listPath: _p('data.songs'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      ),
    ).toJson();

Map<String, Object?> _playlistListBinding(String path, String listPath) =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: OnlineMusicRequestSpec(path: path),
      response: OnlineMusicResponseSpec(
        listPath: _p(listPath),
        fields: {
          OnlineMusicDomainField.playlistId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      ),
    ).toJson();

Map<String, Object?> _artistListBinding() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/artist/sublist'),
      response: OnlineMusicResponseSpec(
        listPath: _p('data'),
        fields: {
          OnlineMusicDomainField.artistId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.artistName: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
        },
      ),
    ).toJson();

void main() {
  test('★ 组合层四个"账号相关"能力必须真的转发出去（不得被桩顶掉）', () async {
    const baseUrl = 'http://127.0.0.1:1';
    final settings = OnlineMusicSettings.fromJson({
      'providers': [
        {
          'id': 'localhost',
          'label': '本地自建服务',
          'contentPlatform': 'netease',
          'baseUrl': baseUrl,
          'requiresCredential': true,
          'credentialReference': 'PureMusic/localhost/APIKey',
          'capabilities': {
            OnlineMusicCapability.recommendedTracks.name: _trackListBinding(),
            OnlineMusicCapability.recommendedPlaylists.name:
                _playlistListBinding('/recommend/resource', 'recommend'),
            OnlineMusicCapability.personalizedPlaylists.name:
                _playlistListBinding('/personalized', 'result'),
            OnlineMusicCapability.followedArtists.name: _artistListBinding(),
          },
        },
      ],
    });
    final composition = createOnlineMusicComposition(
      settings: settings,
      portableBuild: true,
    );
    addTearDown(composition.service.dispose);
    final service = composition.service;
    final token = OnlineMusicCancelToken();

    // 四个能力都必须"走到网络这一层" ⇒ 因此行为只能是"连接失败"，
    // **绝不能**是"未实现"（那正是被桩顶掉的症状 ✗）。
    Future<void> mustForward(String label, Future<Object?> Function() run) async {
      try {
        await run();
        // 连不上却成功了？不可能（除非有人给 127.0.0.1:1 起了服务）⇒ 也算通过 ✓。
      } catch (error) {
        expect(
          error,
          isNot(isA<UnsupportedError>()),
          reason: '$label 被桩顶掉了 ✗：组合层没有把调用转发给真正的提供者 ✓',
        );
        expect(
          error.toString(),
          isNot(contains('not implemented here')),
          reason: '$label 抛出了"未实现"文案 ✗ ⇒ 组合层没有转发 ✓',
        );
      }
    }

    await mustForward(
      'recommendedTracks',
      () => service.fetchRecommendedTracks(
        platform: MusicPlatform.netease,
        limit: 8,
        offset: 0,
        cancelToken: token,
      ),
    );
    await mustForward(
      'recommendedPlaylists',
      () => service.fetchRecommendedPlaylists(
        platform: MusicPlatform.netease,
        limit: 8,
        offset: 0,
        cancelToken: token,
      ),
    );
    await mustForward(
      'personalizedPlaylists',
      () => service.fetchPersonalizedPlaylists(
        platform: MusicPlatform.netease,
        limit: 8,
        offset: 0,
        cancelToken: token,
      ),
    );
    await mustForward(
      'followedArtists',
      () => service.fetchFollowedArtists(
        platform: MusicPlatform.netease,
        limit: 8,
        offset: 0,
        cancelToken: token,
      ),
    );
  });
}
