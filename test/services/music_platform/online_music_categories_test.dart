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

/// 歌单分类（playlistCategories）与"按分类取歌单"。
///
/// 两个设计要点：
/// 1. **"取某分类下的歌单"不新开能力** —— 它是 `playlistCollection` 的一个可选输入
///    （`categoryId`），因此这里必须验证该输入真的被拼进了查询串；
/// 2. **分类字段里没有分组** —— 分组名在真实服务里是"以分组 id 为键的另一张表"，
///    拼接它属于逻辑而非映射（见能力枚举的说明）。
void main() {
  const netease = MusicPlatform.netease;

  JsonPath p(String source) => JsonPath.tryParse(source)!;

  /// **真实响应样本**：字段名与形状取自对 `http://127.0.0.1:3000/playlist/catlist`
  /// 的实际请求（`code=200`、`sub` 70 项、`categories` 是 `{0:'语种',…}` 的映射）。
  /// 这里只留 3 项，保留原始字段名。
  const realCatlistSample = <String, Object?>{
    'code': 200,
    'categories': {0: '语种', 1: '风格', 2: '场景', 3: '情感', 4: '主题'},
    'sub': [
      {'name': '华语', 'resourceCount': 1945, 'category': 0, 'hot': true},
      {'name': '摇滚', 'resourceCount': 812, 'category': 1, 'hot': false},
      {'name': '清晨', 'resourceCount': 333, 'category': 2, 'hot': false},
    ],
  };

  OnlineMusicResponseSpec categorySpec() => OnlineMusicResponseSpec(
    listPath: p('sub'),
    fields: {
      // 网易云用**分类名**当请求值（`/top/playlist?cat=华语`），所以 id 与 name 同源。
      OnlineMusicDomainField.categoryId: OnlineMusicFieldSpec(
        candidates: [p('name')],
        transform: OnlineMusicFieldTransform.asString,
        required: true,
      ),
      OnlineMusicDomainField.categoryName: OnlineMusicFieldSpec(
        candidates: [p('name')],
        transform: OnlineMusicFieldTransform.asString,
        required: true,
      ),
      OnlineMusicDomainField.categoryCount: OnlineMusicFieldSpec(
        candidates: [p('resourceCount')],
        transform: OnlineMusicFieldTransform.asInt,
      ),
    },
  );

  /// 按分类取歌单的绑定：`cat` 来自 `categoryId` 输入（这是本段新增的输入来源）。
  OnlineMusicDeclarativeCapabilityBinding collectionByCategoryBinding() =>
      OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(
          path: '/top/playlist',
          query: [
            OnlineMusicParamBinding(
              name: 'cat',
              source: OnlineMusicInputSource.categoryId,
              required: true,
            ),
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
      );

  group('分类映射', () {
    test('真实 /playlist/catlist 样本映射成分类（id 即名字、含数量与来源）', () {
      final categories = mapDeclarativePlaylistCategoriesResponse(
        spec: categorySpec(),
        body: realCatlistSample,
        platform: netease,
      );

      expect(categories, hasLength(3));
      expect(categories.first.platform, netease);
      expect(categories.first.id, '华语');
      expect(categories.first.name, '华语');
      expect(categories.first.count, 1945);
      expect(categories.last.name, '清晨');
    });

    test('没有数量字段时是 null，不编造', () {
      final categories = mapDeclarativePlaylistCategoriesResponse(
        spec: categorySpec(),
        body: const {
          'sub': [
            {'name': '华语'},
          ],
        },
        platform: netease,
      );

      expect(categories.single.count, isNull);
    });

    test('缺必填字段 / 没配列表路径时明确失败', () {
      expect(
        () => mapDeclarativePlaylistCategoriesResponse(
          spec: categorySpec(),
          body: const {
            'sub': [
              {'resourceCount': 1},
            ],
          },
          platform: netease,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
      expect(
        () => mapDeclarativePlaylistCategoriesResponse(
          spec: const OnlineMusicResponseSpec(fields: {}),
          body: const {},
          platform: netease,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });
  });

  group('分类能力的字段集与配置校验', () {
    test('字段集只有分类自身：没有任何歌单或曲目字段，也没有分组字段', () {
      final fields = domainFieldsFor(OnlineMusicCapability.playlistCategories);
      expect(fields, {
        OnlineMusicDomainField.categoryId,
        OnlineMusicDomainField.categoryName,
        OnlineMusicDomainField.categoryCount,
      });
      // 分组名要"按同级的另一个字段去查另一张表"，那是逻辑不是映射 ⇒ 刻意不支持。
      expect(
        OnlineMusicDomainField.values.any((f) => f.name.contains('Group')),
        isFalse,
        reason: '领域字段里不应存在分组字段',
      );
    });

    test('必填字段是分类 id 与名称', () {
      expect(requiredFieldsFor(OnlineMusicCapability.playlistCategories), {
        OnlineMusicDomainField.categoryId,
        OnlineMusicDomainField.categoryName,
      });
    });

    test('没有列表路径时报配置问题', () {
      final issues = const OnlineMusicResponseSpec(fields: {}).validationIssues(
        OnlineMusicCapability.playlistCategories,
      );
      expect(issues, contains('歌单分类能力必须配置列表路径'));
    });
  });

  group('接进 DeclarativeMusicProvider / 服务层', () {
    test('fetchPlaylistCategories 走自己的绑定', () async {
      final provider = DeclarativeMusicProvider(
        providerId: 'cats',
        bindings: {
          OnlineMusicCapability.playlistCategories:
              OnlineMusicDeclarativeCapabilityBinding(
                request: const OnlineMusicRequestSpec(path: '/playlist/catlist'),
                response: categorySpec(),
              ),
        },
        transport: _RecordingTransport(
          const DeclarativeHttpResponse(
            statusCode: 200,
            data: realCatlistSample,
          ),
        ),
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      final categories = await provider.fetchPlaylistCategories(
        platform: netease,
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(
        provider.platformsFor(OnlineMusicCapability.playlistCategories),
        {netease},
      );
      expect(categories.map((c) => c.id), ['华语', '摇滚', '清晨']);
    });

    test('★ categoryId 真的被拼进查询串（"按分类取歌单"复用歌单列表能力）', () async {
      final transport = _RecordingTransport(
        const DeclarativeHttpResponse(
          statusCode: 200,
          data: {
            'playlists': [
              {'id': 1, 'name': '华语歌单'},
            ],
          },
        ),
      );
      final provider = DeclarativeMusicProvider(
        providerId: 'catFilter',
        bindings: {
          OnlineMusicCapability.playlistCollection:
              collectionByCategoryBinding(),
        },
        transport: transport,
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      await provider.fetchPlaylistCollection(
        platform: netease,
        limit: 10,
        offset: 20,
        categoryId: '华语',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.query['cat'], '华语');
      expect(transport.requests.single.query['limit'], '10');
      expect(transport.requests.single.query['offset'], '20');
    });

    test('绑定要求分类却没给时，明确报"缺输入"而不是悄悄发一个不带分类的请求', () async {
      final transport = _RecordingTransport(
        const DeclarativeHttpResponse(statusCode: 200, data: {'playlists': []}),
      );
      final provider = DeclarativeMusicProvider(
        providerId: 'catFilter',
        bindings: {
          OnlineMusicCapability.playlistCollection:
              collectionByCategoryBinding(),
        },
        transport: transport,
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      await expectLater(
        provider.fetchPlaylistCollection(
          platform: netease,
          cancelToken: OnlineMusicCancelToken(),
        ),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.badRequest,
          ),
        ),
      );
      // 关键：失败发生在**发请求之前**，不会漏出一个没有分类的请求。
      expect(transport.requests, isEmpty);
    });

    test('分类浏览的平台 = 分类索引 ∩ 歌单列表（单有分类不算可用）', () {
      // 只有分类、没有歌单列表 ⇒ chip 点不动，不该算"可浏览"。
      final categoryOnly = _CategoryProvider(
        'catsOnly',
        platforms: const {MusicPlatform.qq},
      );
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: [categoryOnly]),
      );

      expect(service.capabilities.playlistCategoryPlatforms, {
        MusicPlatform.qq,
      });
      expect(service.capabilities.playlistCollectionPlatforms, isEmpty);
      expect(service.capabilities.browsableCategoryPlatforms, isEmpty);
    });

    test('同时具备两者时才算可浏览', () {
      final both = _CategoryProvider(
        'both',
        platforms: const {netease},
        alsoCollection: true,
      );
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: [both]),
      );

      expect(service.capabilities.browsableCategoryPlatforms, {netease});
    });

    test('没有候选的平台明确 unavailable', () async {
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(
          providers: [_CategoryProvider('none', platforms: const {})],
        ),
      );

      await expectLater(
        service.fetchPlaylistCategories(
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

/// 只实现"分类索引"（可选再加"歌单列表"）的 Provider 替身。
final class _CategoryProvider extends UnsupportedOnlineMusicProvider {
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

  _CategoryProvider(
    this.providerId, {
    required this.platforms,
    this.alsoCollection = false,
  });

  @override
  final String providerId;

  final Set<MusicPlatform> platforms;
  final bool alsoCollection;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      switch (capability) {
        OnlineMusicCapability.playlistCategories => platforms,
        OnlineMusicCapability.playlistCollection when alsoCollection =>
          platforms,
        _ => const {},
      };

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    RemotePlaylistCategory(platform: platform, id: '华语', name: '华语'),
  ];
}

/// 记录每次请求（用来断言查询串真的带上了分类）。
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
