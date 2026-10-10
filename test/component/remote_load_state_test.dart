import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/remote_load_state.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';

/// 按 key 分别加载的那份状态：**"没取过"、"取到空"、"失败"** 必须是三种可区分的状态。
/// 把失败渲染成空，用户就会把一次网络抖动读成"这个平台没有内容"。
void main() {
  test('初始状态：没取过、不在加载、没有错误', () {
    final state = RemoteLoadState<String, int>();

    expect(state.items('netease'), isEmpty);
    expect(state.isLoading('netease'), isFalse);
    expect(state.error('netease'), isNull);
    expect(state.hasLoaded('netease'), isFalse);
    expect(state.isEmpty, isTrue);
  });

  test('加载中：只有 loading 置位，其它 key 不受影响', () {
    final state = RemoteLoadState<String, int>()..markLoading('netease');

    expect(state.isLoading('netease'), isTrue);
    expect(state.error('netease'), isNull);
    expect(state.hasLoaded('netease'), isFalse);
    // 另一个 key 完全不受影响（这就是"单平台失败/加载不影响其它平台"）。
    expect(state.isLoading('qq'), isFalse);
  });

  test('成功：写入内容、清掉错误、结束加载、标记已取过', () {
    final state = RemoteLoadState<String, int>()
      ..markLoading('netease')
      ..fail('netease', '上一次失败')
      ..markLoading('netease')
      ..succeed('netease', [1, 2, 3]);

    expect(state.items('netease'), [1, 2, 3]);
    expect(state.error('netease'), isNull);
    expect(state.isLoading('netease'), isFalse);
    expect(state.hasLoaded('netease'), isTrue);
  });

  test('★ 空列表是"成功"：hasLoaded 为真 ⇒ 界面可以说"没有内容"而不是"还没加载"', () {
    final state = RemoteLoadState<String, int>()
      ..markLoading('netease')
      ..succeed('netease', const []);

    expect(state.items('netease'), isEmpty);
    expect(state.hasLoaded('netease'), isTrue);
    expect(state.error('netease'), isNull);
  });

  test('★ 失败不是空：有错误文案，且不动"没取过"的判定', () {
    final state = RemoteLoadState<String, int>()
      ..markLoading('netease')
      ..fail('netease', '网络不可用');

    expect(state.error('netease'), '网络不可用');
    expect(state.isLoading('netease'), isFalse);
    // 失败**不算**取回过：不能因此显示"该平台没有内容"。
    expect(state.hasLoaded('netease'), isFalse);
    expect(state.items('netease'), isEmpty);
  });

  test('★ 刷新失败保留上一次的内容（不把已经显示的东西清掉）', () {
    final state = RemoteLoadState<String, int>()
      ..succeed('netease', [7])
      ..markLoading('netease')
      ..fail('netease', '刷新失败');

    expect(state.items('netease'), [7], reason: '失败不该清空已有内容');
    expect(state.error('netease'), '刷新失败');
    expect(state.isLoading('netease'), isFalse);
  });

  test('clearErrors 只清错误，不动内容与已取过标记', () {
    final state = RemoteLoadState<String, int>()
      ..succeed('netease', [1])
      ..fail('qq', '失败')
      ..clearErrors();

    expect(state.error('qq'), isNull);
    expect(state.items('netease'), [1]);
    expect(state.hasLoaded('netease'), isTrue);
  });

  test('取回的内容是不可变列表（防止调用方就地改坏缓存）', () {
    final state = RemoteLoadState<String, int>()..succeed('netease', [1, 2]);

    expect(() => state.items('netease').add(3), throwsUnsupportedError);
  });

  test('★ cancel 只结束加载态：既不记错误、也不算取回过', () {
    final state = RemoteLoadState<String, int>()
      ..markLoading('netease')
      ..cancel('netease');

    expect(state.isLoading('netease'), isFalse);
    expect(state.error('netease'), isNull, reason: '取消不是失败');
    expect(state.hasLoaded('netease'), isFalse);
    expect(state.items('netease'), isEmpty);
  });

  group('分页：append 与 lastPageCount', () {
    test('succeed 是**替换**并记下原始条数', () {
      final state = RemoteLoadState<String, int>()
        ..succeed('netease', [1, 2, 3])
        ..succeed('netease', [9]);

      expect(state.items('netease'), [9]);
      expect(state.lastPageCount('netease'), 1);
    });

    test('★ append 是**追加**，并更新原始条数（判断"还有没有更多"靠它）', () {
      final state = RemoteLoadState<String, int>()
        ..succeed('netease', [1, 2])
        ..append('netease', [3, 4]);

      expect(state.items('netease'), [1, 2, 3, 4]);
      expect(state.lastPageCount('netease'), 2);
      expect(state.hasLoaded('netease'), isTrue);
      expect(state.error('netease'), isNull);
    });

    test('★ 追加一页**短页**时原始条数变小 ⇒ 界面据此判定"没有更多了"', () {
      final state = RemoteLoadState<String, int>()
        ..succeed('netease', [1, 2])
        ..append('netease', [3]);

      expect(state.lastPageCount('netease'), 1, reason: '不能沿用上一页的条数');
    });

    test('没取过时 lastPageCount 是 0（不假装取满）', () {
      expect(RemoteLoadState<String, int>().lastPageCount('netease'), 0);
    });

    test('append 也清掉错误、结束加载态', () {
      final state = RemoteLoadState<String, int>()
        ..fail('netease', '上一页失败')
        ..markLoading('netease')
        ..append('netease', [1]);

      expect(state.error('netease'), isNull);
      expect(state.isLoading('netease'), isFalse);
    });

    test('append 后的内容同样是不可变列表', () {
      final state = RemoteLoadState<String, int>()
        ..succeed('netease', [1])
        ..append('netease', [2]);

      expect(() => state.items('netease').add(3), throwsUnsupportedError);
    });
  });

  group('分页去重（接口未必真的支持翻页）', () {
    RemoteLoadState<String, Map<String, String>> withIdentity() =>
        RemoteLoadState<String, Map<String, String>>(
          identity: (item) => item['id'],
        );

    test('★ 接口忽略 offset（返回同一批）时：不追加重复项，并判定为没有更多', () {
      final state = withIdentity()
        ..succeed('k', [
          {'id': 'a'},
          {'id': 'b'},
        ])
        // 第二页要回来的是**同一批**（典型的"忽略 offset"）。
        ..append('k', [
          {'id': 'a'},
          {'id': 'b'},
        ]);

      expect(state.items('k'), hasLength(2), reason: '不能出现重复条目');
      expect(
        state.lastPageCount('k'),
        0,
        reason: '一条新的都没有 ⇒ 界面据此收敛为"没有更多了"（否则按钮永远点得动）',
      );
    });

    test('部分重复时只接上真正新的那些', () {
      final state = withIdentity()
        ..succeed('k', [
          {'id': 'a'},
          {'id': 'b'},
        ])
        ..append('k', [
          {'id': 'b'},
          {'id': 'c'},
        ]);

      expect(state.items('k').map((item) => item['id']), ['a', 'b', 'c']);
      expect(state.lastPageCount('k'), 1);
    });

    test('没有 identity 时不做去重（保持既有行为）', () {
      final state = RemoteLoadState<String, Map<String, String>>()
        ..succeed('k', [
          {'id': 'a'},
        ])
        ..append('k', [
          {'id': 'a'},
        ]);

      expect(state.items('k'), hasLength(2));
      expect(state.lastPageCount('k'), 1);
    });

    test('标识取不到时保守放行：宁可多显示，也不要因为去重丢掉真内容', () {
      final state = withIdentity()
        ..succeed('k', [
          {'id': 'a'},
        ])
        ..append('k', [
          <String, String>{}, // 没有 id
          {'id': 'a'}, // 重复
        ]);

      expect(state.items('k'), hasLength(2));
      expect(state.lastPageCount('k'), 1);
    });
  });

  group('页面里的加载语义（经 RemoteListLoading）', () {
    testWidgets('★ 连点两次「加载更多」只发一次请求（同一 key 的追加在途时被抑制）', (
      tester,
    ) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      final host = key.currentState!;
      var calls = 0;
      final completer = Completer<List<int>>();

      final first = host.loadRemoteList(host.state, 'netease', () {
        calls++;
        return completer.future;
      }, append: true);
      await tester.pump();
      final second = host.loadRemoteList(host.state, 'netease', () {
        calls++;
        return completer.future;
      }, append: true);
      await tester.pump();

      // 第二次点击**不该**再发一笔（去重能挡住重复条目，但挡不住白跑一趟网络）。
      expect(calls, 1);
      completer.complete([1, 2]);
      await first;
      await second;
      await tester.pump();
      expect(host.state.items('netease'), [1, 2]);
    });

    testWidgets('★ 正对照：显式刷新（append: false）在加载中**仍会**发出', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      final host = key.currentState!;
      var calls = 0;
      final completers = <Completer<List<int>>>[];

      for (final _ in [1, 2]) {
        final completer = Completer<List<int>>();
        completers.add(completer);
        // 不 await：两笔都要在途。
        host.loadRemoteList(host.state, 'netease', () {
          calls++;
          return completer.future;
        });
        await tester.pump();
      }

      expect(calls, 2, reason: '刷新不该被抑制');
      for (final completer in completers) {
        if (!completer.isCompleted) completer.complete(const [7]);
      }
      await tester.pump();
    });

    testWidgets('★ 正对照：另一个 key 的追加不会被抑制', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      final host = key.currentState!;
      var calls = 0;

      for (final platform in ['netease', 'qq']) {
        final completer = Completer<List<int>>();
        host.loadRemoteList(host.state, platform, () {
          calls++;
          return completer.future;
        }, append: true);
        await tester.pump();
        completer.complete(const [1]);
      }

      expect(calls, 2, reason: '不同 key 互不影响');
      await tester.pump();
    });

    testWidgets('cancelled 例外**不会**变成一条可见错误', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));

      await key.currentState!.loadRemoteList(
        key.currentState!.state,
        'netease',
        () async => throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.cancelled,
          safeMessage: '播放请求已取消',
        ),
      );
      await tester.pump();

      // 用户只是离开了这一页 —— 界面上不该出现"请求已取消"。
      expect(key.currentState!.state.error('netease'), isNull);
      expect(key.currentState!.state.isLoading('netease'), isFalse);
      expect(find.text('播放请求已取消'), findsNothing);
    });

    testWidgets('真实失败会被如实记录（与取消区分开）', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));

      await key.currentState!.loadRemoteList(
        key.currentState!.state,
        'netease',
        () async => throw const OnlineMusicException(
          kind: OnlineMusicErrorKind.network,
          safeMessage: '在线音乐网络请求失败',
        ),
      );
      await tester.pump();

      expect(key.currentState!.state.error('netease'), '在线音乐网络请求失败');
      expect(key.currentState!.state.hasLoaded('netease'), isFalse);
    });

    testWidgets('未知异常用 fallback 文案，而不是空错误', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));

      await key.currentState!.loadRemoteList(
        key.currentState!.state,
        'netease',
        () async => throw StateError('boom'),
        fallback: '读取该平台歌单失败',
      );
      await tester.pump();

      expect(key.currentState!.state.error('netease'), '读取该平台歌单失败');
    });

    testWidgets('★ 页面销毁会取消它自己发出的请求', (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      final token = key.currentState!.newCancelToken();

      expect(token.isCancelled, isFalse);

      // 换掉整棵树 ⇒ 页面销毁
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(
        token.isCancelled,
        isTrue,
        reason: '否则用户离开后请求仍会跑完，连接白白占用、结果只能丢掉',
      );
    });
  });
}

/// 最小宿主：用来在真实 State 生命周期里验证 [RemoteListLoading]。
class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with RemoteListLoading<_Host> {
  final RemoteLoadState<String, int> state = RemoteLoadState<String, int>();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
