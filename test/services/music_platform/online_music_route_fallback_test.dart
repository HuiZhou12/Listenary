import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_music_provider.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_diagnostics.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/composite_online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_credentials.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_settings.dart';

/// S2：fail-closed 受限回退、诊断可观测、以及 D15 的 `endpointMismatch` 分类。
void main() {
  const search = OnlineMusicCapability.search;
  const stream = OnlineMusicCapability.stream;
  const netease = MusicPlatform.netease;

  final neteaseSearchAndStream = <OnlineMusicCapability, Set<MusicPlatform>>{
    search: {netease},
    stream: {netease},
  };

  CompositeOnlineMusicService serviceWith(List<_ScriptedProvider> providers) =>
      CompositeOnlineMusicService(
        registry: OnlineMusicProviderRegistry(providers: providers),
      );

  Future<MusicSearchPage> searchWith(CompositeOnlineMusicService service) =>
      service.search(
        platform: netease,
        keyword: 'x',
        cancelToken: OnlineMusicCancelToken(),
      );

  group('回退判定（fail-closed，Spec §6.3 + D16）', () {
    test('允许回退的 kind 恰好是规定的五项', () {
      const allowed = {
        OnlineMusicErrorKind.network,
        OnlineMusicErrorKind.unavailable,
        OnlineMusicErrorKind.notConfigured,
        OnlineMusicErrorKind.quotaExhausted,
        OnlineMusicErrorKind.rateLimited,
      };
      for (final kind in OnlineMusicErrorKind.values) {
        expect(
          allowsProviderFallback(kind),
          allowed.contains(kind),
          reason: '${kind.name} 的回退判定与 Spec 不一致',
        );
      }
    });

    test('网络失败 → 换下一个候选并成功，诊断记录可读', () async {
      final failing = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.network,
      );
      final healthy = _ScriptedProvider('neteaseB', neteaseSearchAndStream);
      final service = serviceWith([failing, healthy]);

      final page = await searchWith(service);

      expect(page.items, isEmpty);
      expect(failing.searchCalls, 1);
      expect(healthy.searchCalls, 1);
      final record = service.lastRoute!;
      expect(record.didFallback, isTrue);
      expect(record.attempts.single.providerId, 'neteaseA');
      expect(record.attempts.single.kind, OnlineMusicErrorKind.network);
      expect(record.winnerProviderId, 'neteaseB');
    });

    test('业务"资源不存在"不换 Provider（D15）', () async {
      final missing = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.notFound,
      );
      final healthy = _ScriptedProvider('neteaseB', neteaseSearchAndStream);
      final service = serviceWith([missing, healthy]);

      await expectLater(
        searchWith(service),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.notFound,
          ),
        ),
      );
      expect(healthy.searchCalls, 0, reason: '内容语义类错误不得触发回退');
      expect(service.lastRoute!.winnerProviderId, isNull);
    });

    test('接口定义不匹配不换 Provider（D15）', () async {
      final mismatch = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.endpointMismatch,
      );
      final healthy = _ScriptedProvider('neteaseB', neteaseSearchAndStream);
      final service = serviceWith([mismatch, healthy]);

      await expectLater(
        searchWith(service),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.endpointMismatch,
          ),
        ),
      );
      expect(healthy.searchCalls, 0, reason: '配置类错误不得靠换 Provider 掩盖');
    });

    test('全部候选都因可回退错误失败时，抛出最后一个错误', () async {
      final first = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.network,
      );
      final second = _ScriptedProvider(
        'neteaseB',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.unavailable,
      );
      final service = serviceWith([first, second]);

      await expectLater(
        searchWith(service),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.unavailable,
          ),
        ),
      );
      expect(first.searchCalls, 1);
      expect(second.searchCalls, 1);
      expect(service.lastRoute!.attempts, hasLength(2));
    });

    test('★ P-29 诊断经**窄接口**可达（生产路径拿到的就是接口类型）', () async {
      final first = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.network,
      );
      final second = _ScriptedProvider('neteaseB', neteaseSearchAndStream);
      final service = serviceWith([first, second]);
      addTearDown(service.dispose);

      await searchWith(service);

      // 关键：**只用接口类型**读诊断（应用层拿不到、也不该拿到实现类）。
      final OnlineMusicService asInterface = service;
      expect(asInterface, isA<OnlineMusicDiagnosticsSource>());
      final entries =
          (asInterface as OnlineMusicDiagnosticsSource).routeDiagnostics;

      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.platformLabel, musicPlatformLabel(MusicPlatform.netease));
      expect(
        entry.capabilityLabel,
        onlineMusicCapabilityLabel(OnlineMusicCapability.search),
      );
      expect(entry.attempts.single, contains('neteaseA'));
      expect(
        entry.attempts.single,
        contains(onlineMusicErrorKindLabel(OnlineMusicErrorKind.network)),
      );
      // "已本地化"要能被抓住：诊断里必须出现中文类别名，且**不得**把枚举名当文案。
      expect(entry.attempts.single, contains('网络'));
      expect(
        entry.attempts.single,
        isNot(contains('network')),
        reason: '诊断是给人看的：不得直接暴露枚举名',
      );
      expect(entry.capabilityLabel, isNot('search'));
      expect(entry.winnerProviderId, 'neteaseB');
      expect(entry.didFallback, isTrue);
      expect(entry.summary, contains('neteaseB（成功）'));
      // 记录里只有 providerId 与错误类别：不含地址、查询串、响应片段或凭据。
      expect(entry.summary, isNot(contains('http')));
      expect(entry.summary, isNot(contains('SECRET')));
    });

    test('★ P-29 诊断不落库（Spec §6.4 明令只读、仅内存）', () {
      // `servedByProviderId` 与路由记录都不得进入持久化配置。
      final json = OnlineMusicSettings.defaults.toJson().toString();
      expect(json, isNot(contains('servedByProvider')));
      expect(json, isNot(contains('routeLog')));
      expect(json, isNot(contains('routeDiagnostics')));
    });

    test('空结果不是错误：直接返回，不触发回退', () async {
      final empty = _ScriptedProvider('neteaseA', neteaseSearchAndStream);
      final next = _ScriptedProvider('neteaseB', neteaseSearchAndStream);
      final service = serviceWith([empty, next]);

      final page = await searchWith(service);

      expect(page.items, isEmpty);
      expect(next.searchCalls, 0);
      expect(service.lastRoute!.didFallback, isFalse);
      expect(service.lastRoute!.winnerProviderId, 'neteaseA');
    });

    test('该平台没有候选时，发请求前就失败且不留路由记录', () async {
      final provider = _ScriptedProvider('neteaseA', neteaseSearchAndStream);
      final service = serviceWith([provider]);

      await expectLater(
        service.search(
          platform: MusicPlatform.qq,
          keyword: 'x',
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
      expect(provider.searchCalls, 0);
      expect(service.routeLog, isEmpty);
    });

    test('播放解析结果带上实际使用的 Provider，仅供诊断', () async {
      final provider = _ScriptedProvider('neteaseA', neteaseSearchAndStream);
      final service = serviceWith([provider]);

      final result = await service.resolve(
        const PlatformTrackRef(platform: netease, trackId: '1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(result.servedByProviderId, 'neteaseA');
      expect(service.lastRoute!.capability, stream);
    });
  });

  group('D15：声明式 Provider 的两类"找不到"必须分开', () {
    DeclarativeMusicProvider declarativeWith(_StubTransport transport) =>
        DeclarativeMusicProvider(
          providerId: 'declarativeA',
          bindings: {OnlineMusicCapability.search: msapiSearchTemplate},
          transport: transport,
          credentials: const _NoCredentialReader(),
          contentPlatform: netease,
        );

    Future<void> runSearch(DeclarativeMusicProvider provider) =>
        provider.search(
          platform: netease,
          keyword: 'x',
          cancelToken: OnlineMusicCancelToken(),
        );

    test('声明式 404 → endpointMismatch，文案指向接口定义', () async {
      final provider = declarativeWith(
        _StubTransport(
          const DeclarativeHttpResponse(
            statusCode: 404,
            data: {'message': 'not found'},
          ),
        ),
      );

      await expectLater(
        runSearch(provider),
        throwsA(
          isA<OnlineMusicException>()
              .having(
                (error) => error.kind,
                'kind',
                OnlineMusicErrorKind.endpointMismatch,
              )
              .having(
                (error) => error.safeMessage,
                'message',
                contains('接口定义无法匹配响应'),
              ),
        ),
      );
    });

    test('响应不是 JSON → endpointMismatch', () async {
      final provider = declarativeWith(
        _StubTransport(
          const DeclarativeHttpResponse(statusCode: 200, data: '<html>oops'),
        ),
      );

      await expectLater(
        runSearch(provider),
        throwsA(
          isA<OnlineMusicException>().having(
            (error) => error.kind,
            'kind',
            OnlineMusicErrorKind.endpointMismatch,
          ),
        ),
      );
    });

    test('字段映射失败 → endpointMismatch，且说明缺什么', () async {
      final provider = declarativeWith(
        _StubTransport(
          const DeclarativeHttpResponse(
            statusCode: 200,
            // 列表存在但缺少必填的 id → 映射失败（配置的字段路径对不上）。
            data: {
              'result': {
                'songs': [
                  {'name': '海阔天空'},
                ],
              },
            },
          ),
        ),
      );

      await expectLater(
        runSearch(provider),
        throwsA(
          isA<OnlineMusicException>()
              .having(
                (error) => error.kind,
                'kind',
                OnlineMusicErrorKind.endpointMismatch,
              )
              .having(
                (error) => error.safeMessage,
                'message',
                contains('接口定义无法匹配响应'),
              ),
        ),
      );
    });
  });

  // ======================================================== P-56
  group('★ P-56 档位声明者与服务者', () {
    test('回落时分叉：转换用**服务者**的声明，UI 用**声明者**的清单，且诊断里说出来', () async {
      // A 是候选里的第一个（= 档位**声明者**），但它解析失败 ⇒ 由 B 真正提供服务。
      // 两个条目的档位映射不同：A 把 lossless 映射成 flac、B 映射成 sq。
      final declarer = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.network,
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: 'FLAC',
            requestValue: 'flac',
          ),
        ],
      );
      final server = _ScriptedProvider(
        'neteaseB',
        neteaseSearchAndStream,
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: 'SQ',
            requestValue: 'sq',
          ),
        ],
      );
      final service = serviceWith([declarer, server]);
      addTearDown(service.dispose);

      // ① UI 看到的档位清单来自**声明者 A**（这是既定语义，本片把它写明）。
      expect(
        service.qualityTiersFor(MusicPlatform.netease).single.requestValue,
        'flac',
      );

      // ② 实际收到请求的是 B，它按**自己**的声明转换 ⇒ 请求值是 sq，不是 flac。
      await service.resolve(
        const PlatformTrackRef(platform: netease, trackId: 't1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );
      expect(declarer.resolveQualities, isEmpty, reason: 'A 失败了，不该留下请求');
      expect(server.resolveQualities.single, 'sq');

      // ③ 分叉必须**可见**：诊断里写出档位声明来自谁。
      final entries =
          (service as OnlineMusicDiagnosticsSource).routeDiagnostics;
      final streamEntry = entries.firstWhere(
        (entry) => entry.capabilityLabel ==
            onlineMusicCapabilityLabel(OnlineMusicCapability.stream),
      );
      expect(streamEntry.winnerProviderId, 'neteaseB');
      expect(streamEntry.qualityDeclarerProviderId, 'neteaseA');
      expect(streamEntry.qualityDeclarerDiffers, isTrue);
      expect(streamEntry.summary, contains('档位声明来自 neteaseA'));

      // ④ **F4-S4b（P-56 的另一半）**：回退发生之后，档位清单必须跟随**实际服务者 B**
      //    （B 自己声明的是 `sq`）—— 不能再借用 A 的 `flac`，否则菜单与"已回落为 X"
      //    会显示**别人的**档位名。
      expect(
        service.qualityTiersFor(MusicPlatform.netease).single.requestValue,
        'sq',
        reason: '回退后档位表跟随实际服务者（不再张冠李戴）',
      );
    });

    test('★ F4-S4b 实际服务者**没有**档位声明 ⇒ 诚实返回空表（不借用别人的档位名）', () async {
      final declarer = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        failure: OnlineMusicErrorKind.network,
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: 'SQ',
            requestValue: 'sq',
          ),
        ],
      );
      // B 不声明档位（内部偏好原样透传）。
      final silentServer = _ScriptedProvider('neteaseB', neteaseSearchAndStream);

      final service = serviceWith([declarer, silentServer]);
      addTearDown(service.dispose);

      // 回落前：没有路由记录 ⇒ 按声明者 A 的档位表（既有语义）。
      expect(service.qualityTiersFor(MusicPlatform.netease).single.requestValue, 'sq');

      await service.resolve(
        const PlatformTrackRef(platform: netease, trackId: 't1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(
        service.qualityTiersFor(MusicPlatform.netease),
        isEmpty,
        reason: '实际服务者 B 不声明档位 ⇒ 只能展示内部偏好，绝不借用 A 的平台档位名',
      );
    });

    test('★ F5（P-58）某平台抛非归一化异常 ⇒ 其它平台的成功结果必须保留', () async {
      final broken = _ScriptedProvider(
        'neteaseBroken',
        neteaseSearchAndStream,
        rawSearchError: StateError('provider bug'),
      );
      final healthy = _ScriptedProvider('qqHealthy', qqSearchAndStream);
      final service = serviceWith([broken, healthy]);
      addTearDown(service.dispose);

      // 旧实现：`_searchOnePlatform` 只捕获 `OnlineMusicException` ⇒ 这个 `StateError`
      // 会逃出 `Future.wait`，把 qq 已经成功的结果一起吞掉（整个调用抛错）。
      final result = await service.searchAggregated(
        keyword: 'x',
        platforms: const [MusicPlatform.netease, MusicPlatform.qq],
        limit: 10,
        offset: 0,
        cancelToken: OnlineMusicCancelToken(),
      );

      expect(
        result.perPlatform.keys,
        contains(MusicPlatform.qq),
        reason: '健康平台的结果必须保留',
      );
      // 夹具的成功搜索返回空列表 ⇒ 关键断言是"qq 那次调用**成功完成并留下了记录**"，
      // 而不是它的条数（旧实现下这个 await 会直接抛错）。
      expect(result.perPlatform, contains(MusicPlatform.qq));
      final failure = result.failures[MusicPlatform.netease];
      expect(failure, isNotNull, reason: '失败平台要如实进 failures');
      expect(
        failure!.kind,
        OnlineMusicErrorKind.unknown,
        reason: '非归一化异常不得伪装成网络故障',
      );
      expect(
        failure.safeMessage,
        allOf(contains('非归一化'), contains('StateError')),
        reason: '要带运行时类型便于定位，且不得混成普通网络错误',
      );
    });

    test('★ F4 收口 Search 服务者 ≠ Stream 实际服务者 ⇒ 档位跟随**实际服务者**', () async {
      // A：只对 **search** 失败（`resolve` 照常成功），声明档位 `flac`；
      // B：搜索的正常服务者，声明档位 `sq`。
      final streamOwner = _ScriptedProvider(
        'neteaseA',
        neteaseSearchAndStream,
        searchFailure: OnlineMusicErrorKind.network,
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: 'SQ',
            requestValue: 'flac',
          ),
        ],
      );
      final searchServer = _ScriptedProvider(
        'neteaseB',
        neteaseSearchAndStream,
        tiers: const [
          PlatformQualityTier(
            internalLevel: 'lossless',
            displayLabel: 'SQ',
            requestValue: 'sq',
          ),
        ],
      );
      final service = serviceWith([streamOwner, searchServer]);
      addTearDown(service.dispose);

      // **先**播放解析（stream 由 A 服务），**后**搜索（回退到 B）——
      // 这样"最后一次路由记录"是 **search**，正好能证明档位表**只看 stream**：
      // 若实现改成"取最后一条路由记录"，这里就会用 B 的 `sq`（错误）。
      await service.resolve(
        const PlatformTrackRef(platform: netease, trackId: 't1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );
      await searchWith(service);

      final entries = (service as OnlineMusicDiagnosticsSource).routeDiagnostics;
      final streamEntry = entries.firstWhere(
        (entry) =>
            entry.capabilityLabel ==
            onlineMusicCapabilityLabel(OnlineMusicCapability.stream),
      );
      final searchEntry = entries.firstWhere(
        (entry) =>
            entry.capabilityLabel ==
            onlineMusicCapabilityLabel(OnlineMusicCapability.search),
      );
      expect(streamEntry.winnerProviderId, 'neteaseA', reason: 'stream 仍由 A 服务');
      expect(searchEntry.winnerProviderId, 'neteaseB', reason: 'search 回退到 B');

      expect(
        service.qualityTiersFor(MusicPlatform.netease).single.requestValue,
        'flac',
        reason: '档位表必须跟随**实际服务者 A（stream）**，而不是最后一条路由记录（search 的 B）',
      );
    });

    test('未回落时声明者就是服务者 ⇒ 诊断不补那句话（不制造噪音）', () async {
      final only = _ScriptedProvider('neteaseA', neteaseSearchAndStream);
      final service = serviceWith([only]);
      addTearDown(service.dispose);

      await service.resolve(
        const PlatformTrackRef(platform: netease, trackId: 't1'),
        requestedQuality: 'lossless',
        cancelToken: OnlineMusicCancelToken(),
      );

      final entry = (service as OnlineMusicDiagnosticsSource)
          .routeDiagnostics
          .single;
      expect(entry.qualityDeclarerDiffers, isFalse);
      expect(entry.summary, isNot(contains('档位声明来自')));
    });
  });
}

final class _ScriptedProvider extends UnsupportedOnlineMusicProvider {
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

  _ScriptedProvider(
    this.providerId,
    this._platforms, {
    this.failure,
    this.tiers = const [],
    this.searchFailure,
    this.rawSearchError,
  });

  @override
  final String providerId;

  final Map<OnlineMusicCapability, Set<MusicPlatform>> _platforms;

  /// 非空时，该 Provider 的所有调用都以这个 kind 失败。
  final OnlineMusicErrorKind? failure;

  /// F4 收口：**只有 `search` 失败**（`resolve` 照常成功）。
  ///
  /// 用来制造"**Search 服务者 ≠ Stream 实际服务者**"：搜索回退到别人，
  /// 而播放仍由本 Provider 服务 —— 档位表必须跟随**实际服务者**（stream 的那个）。
  final OnlineMusicErrorKind? searchFailure;

  /// F5（P-58）：让 `search` 抛出**非归一化异常**（如 `StateError`），
  /// 用来验证"平台级隔离边界"是否兜得住。
  final Object? rawSearchError;

  /// 该 Provider 声明的平台档位（P-56：用来制造"声明者 ≠ 服务者"）。
  final List<PlatformQualityTier> tiers;

  /// 每次成功的 `resolve` 收到的档位请求值（用来验证**用谁的声明做转换**）。
  final List<String> resolveQualities = [];

  int searchCalls = 0;

  @override
  Set<MusicPlatform> platformsFor(OnlineMusicCapability capability) =>
      _platforms[capability] ?? const {};

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => tiers;

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    searchCalls++;
    // F4 收口：`searchFailure` 只影响搜索（`resolve` 仍成功）⇒ 可制造
    // "Search 服务者 ≠ Stream 实际服务者"。
    final raw = rawSearchError;
    if (raw != null) throw raw;
    final kind = searchFailure ?? failure;
    if (kind != null) {
      throw OnlineMusicException(
        kind: kind,
        safeMessage: 'failed:${kind.name}',
      );
    }
    return MusicSearchPage(platform: platform, items: const []);
  }

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final kind = failure;
    if (kind != null) {
      throw OnlineMusicException(
        kind: kind,
        safeMessage: 'failed:${kind.name}',
      );
    }
    resolveQualities.add(requestedQuality);
    return ResolvedStream(
      ref: ref,
      uri: Uri.parse('https://media.invalid/a.flac'),
      requestedQuality: requestedQuality,
      resolvedAt: DateTime.now(),
    );
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

const qqSearchAndStream = <OnlineMusicCapability, Set<MusicPlatform>>{
  OnlineMusicCapability.search: {MusicPlatform.qq},
  OnlineMusicCapability.stream: {MusicPlatform.qq},
};
