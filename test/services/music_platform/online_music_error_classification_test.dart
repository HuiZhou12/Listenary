import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// `chksz/index.dart` 是服务层的统一导出口（含统一错误层与设置控制器）。
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// 固定的状态码集合：覆盖唯一表的**每一格**，外加两个"表里没列"的边界（405/418）。
const _statuses = <int>[400, 401, 402, 403, 404, 405, 418, 429, 500, 502, 503];

/// 用脚本化状态码替换 chksz 传输层：让真实客户端 + 真实 `_mapError` 跑完整条链路。
final class _ScriptedChkszTransport implements ChkszTransport {
  _ScriptedChkszTransport(this.statusCode);

  final int statusCode;

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) async => ChkszTransportResponse(
    statusCode: statusCode,
    data: const {'msg': 'test'},
  );
}

ChkszOnlineMusicProvider _builtinProvider(int statusCode) =>
    ChkszOnlineMusicProvider(
      runtime: ChkszRuntime(
        transport: _ScriptedChkszTransport(statusCode),
        authResolver: (capability) => const OnlineMusicNoAuth(),
      ),
    );

void main() {
  // =========================================================== P-16
  group('★ P-16 唯一的状态码分类表', () {
    test('内置层：每个状态码都按统一表分类（端到端，经真实 chksz 客户端）', () async {
      for (final status in _statuses) {
        final provider = _builtinProvider(status);
        addTearDown(provider.dispose);
        await expectLater(
          provider.search(
            platform: MusicPlatform.netease,
            keyword: 'x',
            cancelToken: OnlineMusicCancelToken(),
          ),
          throwsA(
            isA<OnlineMusicException>().having(
              (error) => error.kind,
              'kind',
              classifyHttpStatus(
                status,
                origin: OnlineMusicErrorOrigin.builtin,
              ),
            ),
          ),
          reason: 'HTTP $status：内置层分类必须等于唯一表给出的结论',
        );
      }
    });

    test('两层只在 404 上分歧（那是"路径谁拥有"的差别，不是分类不一致）', () {
      // 这是 P-16 的核心不变量：把"同一状态两层不同结论"压缩到**唯一一个**已知差异。
      for (final status in _statuses) {
        final builtin = classifyHttpStatus(
          status,
          origin: OnlineMusicErrorOrigin.builtin,
        );
        final declarative = classifyHttpStatus(
          status,
          origin: OnlineMusicErrorOrigin.declarative,
        );
        if (status == 404) {
          expect(builtin, OnlineMusicErrorKind.notFound);
          expect(declarative, OnlineMusicErrorKind.endpointMismatch);
          continue;
        }
        expect(
          declarative,
          builtin,
          reason: 'HTTP $status：除 404 之外两层必须同结论',
        );
      }
    });

    test('声明式遇到不可读响应 ⇒ endpointMismatch（Spec §6.5）', () {
      for (final status in _statuses) {
        expect(
          classifyHttpStatus(
            status,
            origin: OnlineMusicErrorOrigin.declarative,
            readableJson: false,
          ),
          OnlineMusicErrorKind.endpointMismatch,
          reason: 'HTTP $status：响应不是对象/数组 ⇒ 接口定义对不上服务端',
        );
        // 内置层不受"可读性"影响（它有自己的 invalidResponse 分类）。
        expect(
          classifyHttpStatus(
            status,
            origin: OnlineMusicErrorOrigin.builtin,
            readableJson: false,
          ),
          classifyHttpStatus(status, origin: OnlineMusicErrorOrigin.builtin),
        );
      }
    });

    test('404 的两种归属都**不允许**换 Provider（Spec §6.3/§6.5）', () {
      for (final origin in OnlineMusicErrorOrigin.values) {
        final kind = classifyHttpStatus(404, origin: origin);
        expect(kind, isNot(OnlineMusicErrorKind.unavailable));
        expect(
          allowsProviderFallback(kind),
          isFalse,
          reason: '${origin.name} 的 404 换 Provider 会掩盖问题',
        );
      }
    });

    test('回退列与 Spec §6.3 一致（含 5xx 统一可回退这条行为变化）', () {
      // 行为变化留证：内置层此前 5xx（非 503）是 `unknown`（**不**回退），
      // 现在与声明式统一为 `unavailable`（**可**回退）——服务端 5xx 是 Provider 级故障，
      // 换个候选是合理出路（Spec §6.3 的白名单语义）。
      for (final status in [500, 502, 503]) {
        final kind = classifyHttpStatus(
          status,
          origin: OnlineMusicErrorOrigin.builtin,
        );
        expect(kind, OnlineMusicErrorKind.unavailable);
        expect(allowsProviderFallback(kind), isTrue);
      }
      const fallbackable = {
        OnlineMusicErrorKind.network,
        OnlineMusicErrorKind.unavailable,
        OnlineMusicErrorKind.notConfigured,
        OnlineMusicErrorKind.quotaExhausted,
        OnlineMusicErrorKind.rateLimited,
      };
      for (final kind in OnlineMusicErrorKind.values) {
        expect(
          allowsProviderFallback(kind),
          fallbackable.contains(kind),
          reason: '${kind.name} 的回退资格',
        );
      }
    });

    test('试跑层的大类是统一表的**纯函数**（同一失败不会两套说法）', () {
      for (final status in _statuses) {
        for (final readable in [true, false]) {
          final body = readable ? const <String, Object?>{'a': 1} : '<html>';
          expect(
            classifyUnsuccessfulTestResponse(status, body),
            declarativeTestFailureKindFor(
              classifyHttpStatus(
                status,
                origin: OnlineMusicErrorOrigin.declarative,
                readableJson: readable,
              ),
            ),
            reason: 'HTTP $status（readable=$readable）的试跑大类必须由统一分类派生',
          );
        }
      }
    });

    test('两层都不再自带状态码表（委派给唯一表）', () {
      // 行为已由上面几条钉住；这条防"以后又在某一层写第二张表"。
      final declarative = File(
        'lib/services/music_platform/declarative/declarative_music_provider.dart',
      ).readAsStringSync();
      final builtin = File(
        'lib/services/music_platform/chksz/chksz_online_music_provider.dart',
      ).readAsStringSync();

      expect(declarative, contains('classifyHttpStatus('));
      expect(builtin, contains('classifyHttpStatus('));
      expect(
        declarative,
        isNot(contains('_errorKindForStatus')),
        reason: '声明式层曾经自带一张状态码表（P-16 的成因之一）',
      );
    });
  });
}
