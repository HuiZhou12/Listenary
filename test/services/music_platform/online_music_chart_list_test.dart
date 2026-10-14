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

/// 榜单索引（chartList）。
///
/// 关键设计（见能力枚举的说明）：**榜单的曲目不新开能力** —— 在榜单以歌单形态存在的
/// 平台上（网易云实测：`/toplist` 的 id 可直接用于 `/playlist/detail`），打开榜单走的
/// 仍是既有的歌单详情链路。因此这里必须守住两件事：
/// 1. 榜单摘要**只有集合自身的字段**，没有曲目字段；
/// 2. 只能列榜、取不到歌单详情的平台，其榜单**不算"可打开"**（否则是死链）。
void main() {
  const netease = MusicPlatform.netease;

  JsonPath p(String source) => JsonPath.tryParse(source)!;

  /// **真实响应样本**：字段名与形状取自对 `http://127.0.0.1:3000/toplist` 的实际请求
  /// （响应 `code=200`、`list` 63 项；此处只留 2 项并保留原始字段名与取值形态）。
  /// 它不是构造出来的理想数据 —— 换接口时这个测试会红，那正是它存在的意义。
  const realToplistSample = <String, Object?>{
    'code': 200,
    'list': [
      {
        'id': 19723756,
        'name': '飙升榜',
        'updateFrequency': '刚刚更新',
        'coverImgUrl':
            'https://p4.music.126.net/rIi7Qzy2i2Y_1QD7cd0MYA==/109951170048506929.jpg',
        'trackCount': 98,
      },
      {
        'id': 3778678,
        'name': '热歌榜',
        'updateFrequency': '每天更新',
        'coverImgUrl':
            'https://p3.music.126.net/0SUEG8yDACfx0Bw2MYFv4Q==/109951170048519512.jpg',
        'trackCount': 200,
      },
    ],
  };

  OnlineMusicResponseSpec chartSpec() => OnlineMusicResponseSpec(
    listPath: p('list'),
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
      OnlineMusicDomainField.playlistCoverUri: OnlineMusicFieldSpec(
        candidates: [p('coverImgUrl')],
        transform: OnlineMusicFieldTransform.asHttpsUri,
      ),
      OnlineMusicDomainField.playlistTrackCount: OnlineMusicFieldSpec(
        candidates: [p('trackCount')],
        transform: OnlineMusicFieldTransform.asInt,
      ),
      OnlineMusicDomainField.playlistUpdateFrequency: OnlineMusicFieldSpec(
        candidates: [p('updateFrequency')],
        transform: OnlineMusicFieldTransform.asString,
      ),
    },
  );

  group('榜单索引映射', () {
    test('真实网易云 /toplist 样本映射成榜单摘要（含更新节奏与来源）', () {
      final charts = mapDeclarativePlaylistCollectionResponse(
        spec: chartSpec(),
        body: realToplistSample,
        platform: netease,
      );

      expect(charts, hasLength(2));
      expect(charts.first.platform, netease);
      expect(charts.first.id, '19723756');
      expect(charts.first.name, '飙升榜');
      expect(charts.first.trackCount, 98);
      expect(charts.first.updateFrequency, '刚刚更新');
      expect(charts.first.coverUri?.scheme, 'https');
      expect(charts.last.name, '热歌榜');
      expect(charts.last.updateFrequency, '每天更新');
    });

    test('没有更新节奏字段时它是 null，而不是空串或编造的值', () {
      final charts = mapDeclarativePlaylistCollectionResponse(
        spec: chartSpec(),
        body: const {
          'list': [
            {'id': 1, 'name': '无节奏榜'},
          ],
        },
        platform: netease,
      );

      expect(charts.single.updateFrequency, isNull);
      expect(charts.single.trackCount, isNull);
    });

    test('缺必填字段时明确失败，不猜一半', () {
      expect(
        () => mapDeclarativePlaylistCollectionResponse(
          spec: chartSpec(),
          body: const {
            'list': [
              {'id': 1},
            ],
          },
          platform: netease,
        ),
        throwsA(isA<DeclarativeMappingException>()),
      );
    });
  });

  group('榜单能力的字段集与配置校验', () {
    test('字段集里没有曲目字段（曲目走歌单详情链路）', () {
      final fields = domainFieldsFor(OnlineMusicCapability.chartList);
      expect(fields, contains(OnlineMusicDomainField.playlistId));
      expect(fields, contains(OnlineMusicDomainField.playlistUpdateFrequency));
      expect(fields.contains(OnlineMusicDomainField.trackId), isFalse);
      expect(fields.contains(OnlineMusicDomainField.title), isFalse);
      expect(fields.contains(OnlineMusicDomainField.duration), isFalse);
    });

    test('必填字段是 id 与名称（否则列表里会出现空条目）', () {
      expect(requiredFieldsFor(OnlineMusicCapability.chartList), {
        OnlineMusicDomainField.playlistId,
        OnlineMusicDomainField.playlistName,
      });
    });

    test('没有列表路径时报配置问题', () {
      final issues = const OnlineMusicResponseSpec(fields: {}).validationIssues(
        OnlineMusicCapability.chartList,
      );
      expect(issues, contains('榜单能力必须配置列表路径'));
    });

    test('更新节奏只接受字符串转换', () {
      expect(expectedFieldKinds[OnlineMusicDomainField.playlistUpdateFrequency], {
        OnlineMusicFieldTransform.asString,
      });
    });
  });

  group('接进 DeclarativeMusicProvider / 服务层', () {
    test('fetchChartList 走自己的绑定，结果带来源身份', () async {
      final provider = DeclarativeMusicProvider(
        providerId: 'charts',
        bindings: {
          OnlineMusicCapability.chartList:
              OnlineMusicDeclarativeCapabilityBinding(
                request: const OnlineMusicRequestSpec(path: '/toplist'),
                response: chartSpec(),
              ),
        },
        transport: _StubTransport(
          const DeclarativeHttpResponse(
            statusCode: 200,
            data: realToplistSample,
          ),
        ),
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      final charts = await provider.fetchChartList(
        platform: netease,
        limit: 10,
        offset: 0,
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(provider.platformsFor(OnlineMusicCapability.chartList), {netease});
      expect(charts.map((c) => c.id), ['19723756', '3778678']);
      expect(charts.every((c) => c.platform == netease), isTrue);
    });

    test('没有配置该绑定时报"不支持"，绝不伪装成空列表', () async {
      final provider = DeclarativeMusicProvider(
        providerId: 'no-charts',
        bindings: const {},
        transport: _StubTransport(
          const DeclarativeHttpResponse(statusCode: 200, data: {}),
        ),
        credentials: const _NoCredentialReader(),
        contentPlatform: netease,
      );

      expect(provider.platformsFor(OnlineMusicCapability.chartList), isEmpty);
      await expectLater(
        provider.fetchChartList(
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

    test('chartPlatforms 与 playlistPlatforms 各算各的', () {
      // 只声明"榜单"、不声明"歌单详情"⇒ 能列榜，但**点不开**。
      final chartOnly = _ChartProvider(
        'chartOnly',
        platforms: const {MusicPlatform.qq},
      );
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: [chartOnly]),
      );

      expect(service.capabilities.chartPlatforms, {MusicPlatform.qq});
      expect(service.capabilities.playlistPlatforms, isEmpty);
      // ★ 关键：只列榜的平台**不算可打开** —— 否则用户点进去只会看到失败。
      expect(service.capabilities.openableChartPlatforms, isEmpty);
    });

    test('同时具备两个能力时才算可打开', () {
      final both = _ChartProvider(
        'both',
        platforms: const {netease},
        alsoPlaylist: true,
      );
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: [both]),
      );

      expect(service.capabilities.chartPlatforms, {netease});
      expect(service.capabilities.playlistPlatforms, {netease});
      expect(service.capabilities.openableChartPlatforms, {netease});
    });

    test('没有候选的平台明确 unavailable，不静默换平台', () async {
      // 注册表要求至少一个 Provider，因此这里放一个**不支持榜单**的 Provider：
      // 对网易云而言它不构成任何榜单候选。
      final service = CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(
          providers: [
            _ChartProvider('none', platforms: const {}),
          ],
        ),
      );

      expect(service.capabilities.chartPlatforms, isEmpty);
      await expectLater(
        service.fetchChartList(
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

/// 只实现"榜单索引"（可选再加"歌单详情"）的 Provider 替身。
final class _ChartProvider extends UnsupportedOnlineMusicProvider {
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

  _ChartProvider(
    this.providerId, {
    required this.platforms,
    this.alsoPlaylist = false,
  });

  @override
  final String providerId;

  final Set<MusicPlatform> platforms;
  final bool alsoPlaylist;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      switch (capability) {
        OnlineMusicCapability.chartList => platforms,
        OnlineMusicCapability.playlist when alsoPlaylist => platforms,
        _ => const {},
      };

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => [
    RemotePlaylistSummary(
      platform: platform,
      id: 'chart-$offset',
      name: '榜单$offset',
      updateFrequency: '每天更新',
    ),
  ];
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
