import 'package:flutter/widgets.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';

/// **按 key 分别加载**的一份远端列表数据。
///
/// 每个 key（通常是平台，或 `(平台, 分类)` 这样的组合）各自维护
/// **加载中 / 成功 / 失败**三态，互不影响 —— 这就是"单平台失败不影响其它平台"的
/// 落地形式。
///
/// 为什么要有它：主页、探索页、榜单页都需要同一件事（每个平台各自加载、各自报错、
/// 各自重试），这段状态机曾被复制过三遍；再添一种内容类型就是第四遍。
class RemoteLoadState<K, T> {
  /// [identity] 用来给分页**去重**：返回该项的稳定标识（例如 `'平台:ID'`）。
  ///
  /// 为什么需要它：分页**是否真的有效取决于用户怎么配置那个接口**
  /// （`playlistCollection` 的路径由用户在设置里填）。若填了一个**忽略 `offset`** 的接口，
  /// 点"加载更多"就会把同一批内容再追加一遍 —— 用户看到重复条目，按钮还永远点得动。
  /// 有了标识就能把重复项挡掉，并在"一条新的都没有"时判定为**没有更多**。
  ///
  /// 为空表示不做去重（保持既有行为）。
  RemoteLoadState({this.identity});

  final Object? Function(T item)? identity;

  final Map<K, List<T>> _items = {};
  final Map<K, String> _errors = {};
  final Set<K> _loading = {};

  /// 成功取回过的 key（**含空结果**）。用来区分"取过但是空"与"还没取"。
  final Set<K> _loaded = {};

  /// 最近一次取回**真正新增**的条数（首次加载即该页全部条数）。
  ///
  /// 用途：判断"还有没有更多"。真实服务的 `total` / `more` **不会**经能力层传上来
  /// （浏览类能力的返回值就是裸列表），因此只能按既有先例用
  /// "上一页是否取满"来推断 —— 与搜索页 `hasMore` 的第二重判定同源。
  final Map<K, int> _lastPageCount = {};

  /// 已取回的内容；没取过时为**空列表**（渲染层不必自己判 null）。
  List<T> items(K key) => _items[key] ?? const [];

  /// 最近一次取回**真正新增**的条数（见 [_lastPageCount] 的说明）。
  int lastPageCount(K key) => _lastPageCount[key] ?? 0;

  /// 加载中（此时应显示占位，而不是"空"）。
  bool isLoading(K key) => _loading.contains(key);

  /// 失败原因；没失败时为 null。**与"空结果"是两件事**，渲染层必须分开处理。
  String? error(K key) => _errors[key];

  /// 是否已经取回过（含空结果）。
  bool hasLoaded(K key) => _loaded.contains(key);

  bool get isEmpty => _items.isEmpty;

  void markLoading(K key) {
    _loading.add(key);
  }

  void succeed(K key, List<T> items) {
    _items[key] = List.unmodifiable(items);
    _errors.remove(key);
    _loading.remove(key);
    _loaded.add(key);
    _lastPageCount[key] = items.length;
  }

  /// **追加一页**（分页加载）：把新一页里**还没出现过的**条目接在已有内容之后。
  ///
  /// 两个刻意的行为：
  /// 1. **按 [identity] 去重** —— 接口若忽略 `offset`（分页路径由用户配置，未必真的支持翻页），
  ///    直接追加会让同一批内容出现两遍；
  /// 2. **`lastPageCount` 记的是"新增条数"** —— 所以"一条新的都没有"时它变成 0，
  ///    界面据此收敛为"没有更多了"，而不是让按钮永远点得动。
  void append(K key, List<T> items) {
    final existing = this.items(key);
    final seen = <Object>{};
    final extract = identity;
    if (extract != null) {
      for (final item in existing) {
        final id = extract(item);
        if (id != null) seen.add(id);
      }
    }
    final added = <T>[];
    for (final item in items) {
      if (extract != null) {
        final id = extract(item);
        // 标识取不到时保守放行：宁可多显示，也不要因为去重把真内容丢掉。
        if (id != null && !seen.add(id)) continue;
      }
      added.add(item);
    }
    _items[key] = List.unmodifiable([...existing, ...added]);
    _errors.remove(key);
    _loading.remove(key);
    _loaded.add(key);
    _lastPageCount[key] = added.length;
  }

  void fail(K key, String message) {
    // 失败**保留上一次的成功结果**：刷新失败不该把已经显示的内容清掉。
    _errors[key] = message;
    _loading.remove(key);
  }

  /// 请求被取消（通常因为页面已销毁）：**结束加载态，但不记错误、也不记成功**。
  ///
  /// 取消不是失败。把它记成失败会在界面上留下一条"请求已取消"的错误提示，
  /// 而用户其实只是离开了这一页。
  void cancel(K key) => _loading.remove(key);

  /// 清掉所有失败标记（"刷新"时用：重试前旧错误不该继续挂着）。
  void clearErrors() => _errors.clear();
}

/// 给页面 State 用的加载逻辑：把"记录三态 + 分类错误"收敛到一处。
///
/// **holder 由调用方传入**而不是混入持有：一个页面常常要同时管好几份互不相干的远端列表
/// （例如探索页的平台歌单 / 分类 / 榜单），它们的 key 与元素类型都不同。
mixin RemoteListLoading<W extends StatefulWidget> on State<W> {
  final List<OnlineMusicCancelToken> _tokens = [];

  /// 为一次加载取一个**由本页持有**的取消令牌。
  ///
  /// 页面销毁时这些令牌会被统一取消：否则用户离开后请求仍会跑完，
  /// 白白占用连接、并且结果只能被丢掉。
  OnlineMusicCancelToken newCancelToken() {
    final token = OnlineMusicCancelToken();
    _tokens.add(token);
    return token;
  }

  @override
  void dispose() {
    for (final token in _tokens) {
      token.cancel();
    }
    _tokens.clear();
    super.dispose();
  }

  /// 取一次并如实记录结果。
  ///
  /// - 成功 → [RemoteLoadState.succeed]（**空列表也是成功**）；
  /// - `cancelled` → [RemoteLoadState.cancel]（**不是失败**，不弹错误）；
  /// - 其它 [OnlineMusicException] → 记 [OnlineMusicException.safeMessage]（面向用户的安全文案）；
  /// - 未知异常 → [fallback]。
  ///
  /// **不在成功/失败之外编造状态**，也不把失败悄悄变成空结果 —— 这两种误判都会让用户
  /// 把一次网络失败读成"这个平台没有内容"。
  Future<void> loadRemoteList<K, T>(
    RemoteLoadState<K, T> state,
    K key,
    Future<List<T>> Function() fetch, {
    String fallback = '读取远端内容失败',
    bool append = false,
  }) async {
    if (!mounted) return;
    // 「加载更多」的**并发抑制**：同一 key 已有一笔追加在途时，再点一次不再发第二笔。
    // 只对 append 生效 —— 显式刷新（append: false）在加载中**仍允许**发出（用户正是在等它刷新）。
    if (append && state.isLoading(key)) return;
    setState(() => state.markLoading(key));
    try {
      final items = await fetch();
      if (!mounted) return;
      setState(() {
        if (append) {
          state.append(key, items);
        } else {
          state.succeed(key, items);
        }
      });
    } on OnlineMusicException catch (error) {
      if (!mounted) return;
      if (error.kind == OnlineMusicErrorKind.cancelled) {
        setState(() => state.cancel(key));
        return;
      }
      setState(() => state.fail(key, error.safeMessage));
    } catch (_) {
      if (!mounted) return;
      setState(() => state.fail(key, fallback));
    }
  }
}
