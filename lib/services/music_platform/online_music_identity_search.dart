import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';

/// **按平台身份**聚合搜索的只读出口（2.2 / G3）。
///
/// 为什么单独一个窄接口，而不是 [OnlineMusicService] 的成员：Dart 的 `implements`
/// 不继承实现，加一个成员会让全部测试替身编译失败（与 `OnlineMusicDiagnosticsSource`
/// 同一取舍）。实现了它的服务（`CompositeOnlineMusicService`）按**身份**请求：
///
/// - [OnlineMusicService.searchAggregated] 以**枚举**为键 ⇒ 一个枚举键只能带一个身份，
///   两个自定义平台同时请求时会互相覆盖（旧 `perPlatform` 守卫会移除该键）；
/// - 本接口以**身份**为单位请求，结果按身份索引
///   （[AggregatedSearchResult.perPlatformIdentity]），因此多个自定义平台可以同时出现在
///   一次搜索里、各自独立失败、不串台。
///
/// 只请求 ∈ [OnlineMusicCapabilities.searchableIdentities] 的身份；被挡下的身份
/// **不发请求**、也不出现在结果的任一 map 里。参数语义（并行、各自分页、不去重、
/// 单平台失败隔离、取消向上传播）与 [OnlineMusicService.searchAggregated] 一致。
///
/// 调用方拿不到它时（测试替身 / 单平台嵌入）应回落到 `searchAggregated`，
/// 那正是"只有内置平台"的既有行为。
abstract interface class OnlineMusicIdentitySearchSource {
  Future<AggregatedSearchResult> searchIdentities({
    required Iterable<PlatformIdentity> identities,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  });
}
