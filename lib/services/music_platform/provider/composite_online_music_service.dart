import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_diagnostics.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_registry.dart';
import 'package:pure_music/services/music_platform/provider/online_music_route_diagnostics.dart';

/// 应用层唯一消费的在线音乐入口：把每个能力分发给 `(platform, capability)` 的候选
/// Provider。
///
/// 应用层只依赖 [OnlineMusicService]；具体是哪个 Provider 由平台感知路由决定，
/// 因此搜索、歌曲列表、歌词、播放可以各自使用不同 Provider。
///
/// **回退语义（D5:A + D15 + D16）**：候选按序尝试，只有"Provider 级故障 /
/// 缺少凭据 / 暂时没有余量"才换下一个（见 [allowsProviderFallback]）；内容语义与
/// 配置类错误一律**立即失败**，不换 Provider。回退默认**静默**（D5b:B），
/// 但每次分发都记入 [routeLog] 以便诊断。
final class CompositeOnlineMusicService
    implements OnlineMusicService, OnlineMusicDiagnosticsSource {
  CompositeOnlineMusicService({required this.registry})
    : capabilities = _capabilitiesFor(registry);

  /// 由**候选**推导能力集合，并在搜索上施加 **Stream 硬门槛**（D3）。
  ///
  /// 旧实现取"被选中的那一个 Provider 声明了什么"，多平台下会漏掉"这个平台其实
  /// 还有另一个可用 Provider"的情况；这里改为按 `(platform, capability)` 候选求并集。
  ///
  /// 门槛：一个平台必须**同时**有可用的 Search 与 Stream 候选，才允许作为搜索来源
  /// —— 否则会出现"搜得到但播不了"。被挡下的平台连同**原因**一起暴露，供 UI 解释
  /// （D3b:a）。
  static OnlineMusicCapabilities _capabilitiesFor(
    OnlineMusicProviderRegistry registry,
  ) {
    final search = registry.platformsFor(OnlineMusicCapability.search);
    final stream = registry.platformsFor(OnlineMusicCapability.stream);
    final searchable = {
      for (final platform in search)
        if (stream.contains(platform)) platform,
    };
    final reasons = <MusicPlatform, String>{};
    for (final platform in {...search, ...stream}) {
      if (searchable.contains(platform)) continue;
      reasons[platform] = stream.contains(platform)
          ? '缺少搜索能力，因此不会参与搜索'
          : '缺少播放解析能力，因此不会参与搜索';
    }
    return OnlineMusicCapabilities(
      searchablePlatforms: searchable,
      resolvablePlatforms: stream,
      playlistPlatforms: registry.platformsFor(OnlineMusicCapability.playlist),
      playlistCollectionPlatforms: registry.platformsFor(
        OnlineMusicCapability.playlistCollection,
      ),
      playlistCategoryPlatforms: registry.platformsFor(
        OnlineMusicCapability.playlistCategories,
      ),
      chartPlatforms: registry.platformsFor(OnlineMusicCapability.chartList),
      newSongPlatforms: registry.platformsFor(OnlineMusicCapability.newSongs),
      lyricPlatforms: registry.platformsFor(OnlineMusicCapability.lyric),
      unavailableSearchReasons: reasons,
    );
  }

  final OnlineMusicProviderRegistry registry;

  @override
  final OnlineMusicCapabilities capabilities;

  /// 路由记录上限；只保留最近若干次，避免长期占用内存。
  static const _routeLogLimit = 32;
  final List<OnlineMusicRouteRecord> _routeLog = [];

  /// 最近的路由记录（**新的在前**）。
  ///
  /// 用途：回退是静默的，但要能回答"这次到底用了哪个 Provider、试过谁、为什么换"
  /// （D5b:B）。不参与任何业务判断。
  List<OnlineMusicRouteRecord> get routeLog =>
      List.unmodifiable(_routeLog.reversed);

  OnlineMusicRouteRecord? get lastRoute =>
      _routeLog.isEmpty ? null : _routeLog.last;

  /// P-29：应用层可读的**诊断出口**。
  ///
  /// Spec §6.4 要求"回退静默但必须可观测"，并把暴露面定为诊断/调试视图；
  /// 此前 `routeLog` 只是本实现的类字段 —— 应用层只拿到 `OnlineMusicService`，
  /// 生产路径**没有任何地方**能读到它（全仓只有测试 downcast 读）。
  ///
  /// 这里返回的是**已本地化、已脱敏**的行（见 [OnlineMusicDiagnosticsEntry]）：
  /// 应用层不需要、也不允许引用 Provider 层的配置/能力枚举符号。
  @override
  List<OnlineMusicDiagnosticsEntry> get routeDiagnostics =>
      List.unmodifiable(buildOnlineMusicDiagnostics(routeLog));

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
    PlatformIdentity? identity,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.search,
    identity: identity,
    (provider) => provider.search(
      platform: platform,
      keyword: keyword,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    ),
  );

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.playlist,
    (provider) => provider.fetchPlaylist(
      platform: platform,
      playlistId: playlistId,
      cancelToken: cancelToken,
    ),
  );

  /// 歌单集合（Spec §19.2）：与歌单详情是两个能力、两条候选链。
  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.playlistCollection,
    (provider) => provider.fetchPlaylistCollection(
      platform: platform,
      limit: limit,
      offset: offset,
      categoryId: categoryId,
      cancelToken: cancelToken,
    ),
  );

  /// 歌单分类索引：与歌单列表各自一条候选链（一个平台可以只有其中之一）。
  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.playlistCategories,
    (provider) => provider.fetchPlaylistCategories(
      platform: platform,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    ),
  );

  /// 榜单索引（与歌单集合同构）：各自一条候选链。
  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.chartList,
    (provider) => provider.fetchChartList(
      platform: platform,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    ),
  );

  /// 新歌（与搜索同构，但语义是"平台最近发布了什么"）。
  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    platform,
    OnlineMusicCapability.newSongs,
    (provider) => provider.fetchNewSongs(
      platform: platform,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    ),
  );

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    ref.platform,
    OnlineMusicCapability.lyric,
    (provider) => provider.fetchLyrics(ref, cancelToken: cancelToken),
    // D9 / I1：歌词必须带回来源身份（用请求里的 ref 回填，Provider 不必自己提供）。
    //
    // P-42：Provider **自己带回** ref 时，必须与请求的是同一首 —— 以前无条件采信它，
    // 于是"另一个 Provider 返回了别人的歌词"会被原样当成这首歌的歌词（身份错配无法检出）。
    // 现在不一致就**直接失败**（`invalidResponse`：数据无法采信，且不回退掩盖）。
    stamp: (lyrics, providerId) {
      final returned = lyrics.ref;
      if (returned == null) return lyrics.withRef(ref);
      if (returned != ref) {
        throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.invalidResponse,
          safeMessage: '返回的歌词与请求的曲目不是同一首：已拒绝使用该结果',
        );
      }
      return lyrics;
    },
  );

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => _dispatch(
    ref.platform,
    OnlineMusicCapability.stream,
    // F5-P-39（P2）：曲目引用**自带身份**（custom + 稳定 ID）⇒ 播放解析按身份路由；
    // 自定义平台缺稳定 ID 时身份无效 ⇒ 候选为空 ⇒ unavailable（fail-closed，不串台）。
    identity: ref.identity,
    // D2:A / D10:A + §19.7：`requestedQuality` 是**内部偏好档位**（跨平台语义），
    // 发给平台之前必须按**该 Track 所属平台自己的档位声明**转换成平台请求值。
    // 网易云的 requestValue 就是内部键，因此这条转换对既有行为零影响；
    // QQ 这类平台则得到 `flac`/`320`/`128`，而不是 `lossless`/`exhigh`/`standard`。
    (provider) => provider.resolve(
      ref,
      requestedQuality: selectPlatformQuality(
        tiers: provider.qualityTiersFor(ref.platform),
        preference: requestedQuality,
      ).requestValue,
      cancelToken: cancelToken,
    ),
    stamp: (stream, providerId) => stream.servedByProviderId == null
        ? stream.withServedByProvider(providerId)
        : stream,
  );

  /// 该平台**应请求的内部偏好档位**（**不是**平台请求值）。
  ///
  /// 返回内部档位而不是平台取值，是因为播放链路把它当"用户偏好"继续传递，
  /// 真正的平台取值由 [resolve] 按该 Track 的平台声明转换一次。
  /// 若这里就返回平台取值，[resolve] 会把它再解释一次（同一偏好被转换两次）。
  @override
  String defaultQualityFor(MusicPlatform platform) {
    // 同步查询：没有候选即不可用；不在此处回退（无异步空间，也没有请求可失败）。
    final declaring = _qualityDeclaringProvider(platform);
    if (declaring == null) throw unsupportedCapability();
    return declaring.defaultQualityFor(platform);
  }

  /// 该平台**档位清单/文案的声明者** —— P-56 的单一来源。
  ///
  /// 就是候选里的第一个（`providersFor` 已经让**显式指定的候选排在前面**，
  /// 因此用户指定了来源时，声明者与服务者都是它）。
  ///
  /// **不变量**：正常情况下"声明者 = 服务者"。
  /// 唯一的例外是**回落** —— 第一个候选失败、由后面的候选真正提供服务时：
  /// - 发给平台前的**档位转换**始终用**服务者自己**的声明（见 [resolve]：转换发生在
  ///   逐个候选的执行里，而不是在这里先算好），因此请求值永远是对的；
  /// - 但 UI 展示的档位清单/文案来自**声明者**，二者可能不同（例如 A 把 `lossless`
  ///   映射成 `flac`、B 映射成 `sq`）。
  ///
  /// 因此这种分叉必须**可见**：`_record` 会把它写进路由诊断（P-56）。
  /// （"让 UI 跟随实际服务者"需要运行期记住"这个平台上次是谁服务的"，属于档位表达力
  /// 的范畴 ⇒ F4 的延期项。）
  OnlineMusicProvider? _qualityDeclaringProvider(MusicPlatform platform) {
    final candidates = _streamCandidates(platform);
    return candidates.isEmpty ? null : candidates.first;
  }

  /// F4-S4b（P-56 的另一半）：档位表跟随**实际服务者**。
  ///
  /// 正常情况下"声明者就是服务者"；一旦发生回退，实际收到请求的是**另一个** Provider
  /// （它按自己的声明做转换）—— 此时若仍用声明者的档位表，菜单与"已回落为 X"提示就会
  /// 显示**别人的**档位名（P-56）。因此这里优先取"运行期最后一次真正服务该平台的
  /// Provider"（来自路由记录，与 D5b:B 的可观测性同一份数据），没有记录时才退回声明者。
  ///
  /// 注意：若实际服务者**没有**声明档位，就**诚实地返回空表**（UI 只展示内部偏好），
  /// 而不是回退去显示另一个 Provider 的档位名 —— 那正是 P-56 要修的误导。
  OnlineMusicProvider? _qualityTierOwner(MusicPlatform platform) {
    final servedId = _lastServedProviderId(platform);
    if (servedId != null) {
      for (final provider in registry.providers) {
        if (provider.providerId == servedId) return provider;
      }
    }
    return _qualityDeclaringProvider(platform);
  }

  /// 该平台**最后一次真正被谁服务**（只看 `stream` 路由记录；没有记录返回 null）。
  String? _lastServedProviderId(MusicPlatform platform) {
    for (final record in _routeLog.reversed) {
      if (record.platform != platform) continue;
      if (record.capability != OnlineMusicCapability.stream) continue;
      return record.winnerProviderId;
    }
    return null;
  }

  /// 该平台**可用的音质档位**（含平台自己的文案），供 UI 渲染选择菜单。
  ///
  /// 空列表表示该 Provider 没有声明档位（内部偏好原样透传）；UI 此时只应展示内部
  /// 偏好本身，**不要伪造平台档位名称**（补充口径④）。
  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) =>
      _qualityTierOwner(platform)?.qualityTiersFor(platform) ?? const [];

  /// 把内部偏好解析成该平台实际使用的档位，并告知**是否发生了回落**。
  ///
  /// 用途：UI 用 `displayLabel` 展示该平台自己的档位名称；`fellBack == true` 时提示
  /// "已回落为 displayLabel"。
  ///
  /// F4-S4b：档位表来自 `_qualityTierOwner` —— **实际服务者优先**（有路由记录时），
  /// 没有记录才退回声明者。因此"已回落为 X"里的 X 是**真正收到请求的那个 Provider**
  /// 的档位名，不再张冠李戴（P-56）。分叉仍会进路由诊断，见 [OnlineMusicRouteRecord]。
  @override
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
  }) => selectPlatformQuality(
    tiers: qualityTiersFor(platform),
    preference: preference,
  );

  List<OnlineMusicProvider> _streamCandidates(MusicPlatform platform) =>
    _streamCandidatesForIdentity(PlatformIdentity.builtin(platform));

  /// F5-P-39（P2）：按**平台身份**取 stream 候选（自定义平台靠稳定 ID 区分，不串台）。
  List<OnlineMusicProvider> _streamCandidatesForIdentity(
    PlatformIdentity identity,
  ) => registry.providersForIdentity(identity, OnlineMusicCapability.stream);

  /// 多平台聚合搜索（D6:A / D6b:a / D6c:a）。
  ///
  /// - **门槛**：只接受 [capabilities]`.searchablePlatforms` 里的平台（D3）；
  ///   被挡下的平台不会发起任何请求，也不会出现在结果的任一 map 里。
  /// - **并行**：各平台同时请求；**单平台失败不影响其它平台** —— 失败进
  ///   [AggregatedSearchResult.failures]，成功的进 `.perPlatform`。
  /// - **分页各自独立**：`limit` / `offset` 原样传给每个平台，调用方按平台分别
  ///   加载更多（D6c:a）。
  /// - **不去重**（D6b:a）：每项都保留自己的 `ref.platform` 与 `ref.trackId`。
  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final requested = {
      for (final platform in platforms)
        if (capabilities.searchablePlatforms.contains(platform)) platform,
    };
    final perPlatform = <MusicPlatform, MusicSearchPage>{};
    final failures = <MusicPlatform, OnlineMusicException>{};

    await Future.wait([
      for (final platform in requested)
        _searchOnePlatform(
          platform: platform,
          keyword: keyword,
          limit: limit,
          offset: offset,
          cancelToken: cancelToken,
          perPlatform: perPlatform,
          failures: failures,
        ),
    ]);

    // 取消要如实向上传播，而不是被收进 failures 假装成"某个平台失败了"。
    if (cancelToken.isCancelled) {
      throw const OnlineMusicException(
        kind: OnlineMusicErrorKind.cancelled,
        safeMessage: '搜索已取消',
      );
    }
    return AggregatedSearchResult(perPlatform: perPlatform, failures: failures);
  }

  /// 单平台搜索；永不抛出 `OnlineMusicException`（改写进 failures），
  /// 以便 `Future.wait` 不会因为一个平台失败而丢掉其它平台的结果。
  Future<void> _searchOnePlatform({
    required MusicPlatform platform,
    required String keyword,
    required int limit,
    required int offset,
    required OnlineMusicCancelToken cancelToken,
    required Map<MusicPlatform, MusicSearchPage> perPlatform,
    required Map<MusicPlatform, OnlineMusicException> failures,
  }) async {
    try {
      perPlatform[platform] = await search(
        platform: platform,
        keyword: keyword,
        limit: limit,
        offset: offset,
        cancelToken: cancelToken,
      );
    } on OnlineMusicException catch (error) {
      failures[platform] = error;
    } catch (error) {
      // F5（P-58）：平台级隔离边界。**非归一化异常**（`StateError` / `TypeError` /
      // 依赖抛出的任意对象）以前会逃出 `Future.wait`，把**其它平台已经成功的**结果一并吞掉。
      // 这里按平台兜住，并明确标注为「非归一化异常」（含运行时类型）——
      // **绝不**伪装成网络故障（D-F3-4 同桌口径），也不把程序缺陷混进普通网络错误里。
      // ⚠️ 只带运行时类型，不带 `error.toString()`：异常文本可能含请求细节/凭据。
      failures[platform] = OnlineMusicException(
        kind: OnlineMusicErrorKind.unknown,
        safeMessage:
            '该平台抛出了非归一化异常（${error.runtimeType}）；'
            '其它平台的结果不受影响，请按此类型定位',
      );
    }
  }

  @override
  void dispose() {
    for (final provider in registry.providers) {
      provider.dispose();
    }
  }

  /// 按候选顺序尝试；只有 [allowsProviderFallback] 认可的错误才继续下一个候选。
  ///
  /// - 候选为空 ⇒ 发请求**之前**就以 `unavailable` 失败（D14：不做平台无关回落）；
  /// - 非回退类错误 ⇒ 立即 `rethrow`，**保留原始分类与文案**（不掩盖配置错误）；
  /// - 全部候选都因可回退错误失败 ⇒ 抛出**最后一个**原始错误；
  /// - 空结果**不是错误**，原样返回，不触发回退。
  Future<T> _dispatch<T>(
    MusicPlatform platform,
    OnlineMusicCapability capability,
    Future<T> Function(OnlineMusicProvider provider) run, {
    T Function(T result, String providerId)? stamp,
    /// F5-P-39（P2）：平台身份。省略 ⇒ builtin(platform)（既有行为完全不变）；
    /// 自定义平台必须传 custom + 稳定 ID，否则身份无效 ⇒ 候选为空 ⇒ unavailable（fail-closed）。
    PlatformIdentity? identity,
  }) async {
    final resolvedIdentity = identity ?? PlatformIdentity.builtin(platform);
    final candidates = registry.providersForIdentity(resolvedIdentity, capability);
    if (candidates.isEmpty) throw unsupportedCapability();

    final attempts = <OnlineMusicRouteAttempt>[];
    OnlineMusicException? lastError;
    for (final provider in candidates) {
      try {
        final result = await run(provider);
        _record(platform, capability, attempts, provider.providerId, resolvedIdentity);
        return stamp == null ? result : stamp(result, provider.providerId);
      } on OnlineMusicException catch (error) {
        attempts.add(
          OnlineMusicRouteAttempt(
            providerId: provider.providerId,
            kind: error.kind,
          ),
        );
        lastError = error;
        if (!allowsProviderFallback(error.kind)) {
          _record(platform, capability, attempts, null, resolvedIdentity);
          rethrow;
        }
      }
    }
    _record(platform, capability, attempts, null, resolvedIdentity);
    throw lastError ?? unsupportedCapability();
  }

  void _record(
    MusicPlatform platform,
    OnlineMusicCapability capability,
    List<OnlineMusicRouteAttempt> attempts,
    String? winnerProviderId,
    PlatformIdentity? identity,
  ) {
    // P-56：档位清单/文案的**声明者**是候选里的第一个（`_qualityDeclaringProvider`）。
    // 正常情况下它就是服务者；一旦回落让二者分叉，就把它记下来 —— 否则用户看到的
    // 档位清单来自 A、实际请求却由 B 按自己的声明转换，且没有任何线索。
    final declaringProviderId = capability == OnlineMusicCapability.stream
        ? _qualityDeclaringProvider(platform)?.providerId
        : null;
    _routeLog.add(
      OnlineMusicRouteRecord(
        platform: platform,
        identity: identity,
        capability: capability,
        attempts: List.unmodifiable(attempts),
        winnerProviderId: winnerProviderId,
        qualityDeclarerProviderId: declaringProviderId,
      ),
    );
    if (_routeLog.length > _routeLogLimit) _routeLog.removeAt(0);
  }
}
