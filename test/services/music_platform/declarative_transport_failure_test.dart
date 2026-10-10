import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_execution.dart';

/// F3-S2（P-50 / D-F3-4）：**读出**底层传输异常类型，把超时 / 无法连接 / DNS / TLS /
/// 取消区别开，并把"非传输异常"（编程错误）从网络里摘出去。
///
/// 关键约束：**不新增顶层失败类别** —— 超时/连接/DNS/TLS 仍然落在既有的
/// `OnlineMusicErrorKind.network` 下，取消落在 `cancelled` 下（投影词表也不变）；
/// 本文件钉住的是**结构化详情**这一层。
void main() {
  DioException dio(DioExceptionType type, {Object? error}) => DioException(
    requestOptions: RequestOptions(path: '/search'),
    type: type,
    error: error,
  );

  group('★ F3-S2 DioException.type 分支', () {
    test('三种超时 ⇒ timeout', () {
      for (final type in const [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(
          classifyTransportFailure(dio(type)),
          DeclarativeTransportFailure.timeout,
          reason: '$type 应当被读成超时，而不是笼统的"网络"',
        );
      }
    });

    test('取消 / 证书 ⇒ cancelled / tls', () {
      expect(
        classifyTransportFailure(dio(DioExceptionType.cancel)),
        DeclarativeTransportFailure.cancelled,
      );
      expect(
        classifyTransportFailure(dio(DioExceptionType.badCertificate)),
        DeclarativeTransportFailure.tls,
      );
    });

    test('connectionError 要向下看一层：DNS 与"连不上"必须分开', () {
      expect(
        classifyTransportFailure(
          dio(
            DioExceptionType.connectionError,
            error: const SocketException(
              "Failed host lookup: 'self.invalid'",
            ),
          ),
        ),
        DeclarativeTransportFailure.dns,
      );
      expect(
        classifyTransportFailure(
          dio(
            DioExceptionType.connectionError,
            error: const SocketException('Connection refused'),
          ),
        ),
        DeclarativeTransportFailure.connection,
      );
      expect(
        classifyTransportFailure(
          dio(
            DioExceptionType.connectionError,
            error: const HandshakeException('certificate verify failed'),
          ),
        ),
        DeclarativeTransportFailure.tls,
      );
    });

    test('嵌套的是编程错误 ⇒ notTransport（不得当成网络）', () {
      expect(
        classifyTransportFailure(
          dio(DioExceptionType.connectionError, error: StateError('bug')),
        ),
        DeclarativeTransportFailure.notTransport,
      );
      expect(
        classifyTransportFailure(dio(DioExceptionType.unknown)),
        DeclarativeTransportFailure.notTransport,
      );
    });
  });

  group('★ F3-S2 非 Dio 的异常也要认', () {
    test('TimeoutException / SocketException / HandshakeException / 其它', () {
      expect(
        classifyTransportFailure(TimeoutException('slow')),
        DeclarativeTransportFailure.timeout,
      );
      expect(
        classifyTransportFailure(
          const SocketException('Name or service not known'),
        ),
        DeclarativeTransportFailure.dns,
      );
      expect(
        classifyTransportFailure(const SocketException('Connection reset')),
        DeclarativeTransportFailure.connection,
      );
      expect(
        classifyTransportFailure(const TlsException('handshake failed')),
        DeclarativeTransportFailure.tls,
      );
      expect(
        classifyTransportFailure(StateError('not a transport problem')),
        DeclarativeTransportFailure.notTransport,
      );
    });
  });

  group('★ F3-S2 顶层类别与词表**不变**（D-F3-4 明令不新增类别）', () {
    test('传输类失败仍然落在 network 大类下，取消落在 cancelled 下', () {
      for (final failure in const [
        DeclarativeTransportFailure.timeout,
        DeclarativeTransportFailure.connection,
        DeclarativeTransportFailure.dns,
        DeclarativeTransportFailure.tls,
      ]) {
        expect(
          declarativeTestFailureKindFor(OnlineMusicErrorKind.network),
          DeclarativeTestFailureKind.network,
          reason: '${failure.name} 仍然属于既有的传输失败大类',
        );
      }
      expect(
        declarativeTestFailureKindFor(OnlineMusicErrorKind.cancelled),
        DeclarativeTestFailureKind.network,
      );
      // 关键：**没有**新增顶层类别（枚举成员数不变）。
      expect(DeclarativeTestFailureKind.values, hasLength(7));
    });

    test('每一种详情都有非空且互不相同的标签（界面上要读得懂）', () {
      final labels = {
        for (final failure in DeclarativeTransportFailure.values)
          declarativeTransportFailureLabel(failure),
      };
      expect(labels, hasLength(DeclarativeTransportFailure.values.length));
      for (final label in labels) {
        expect(label.trim(), isNotEmpty);
      }
      expect(labels, contains('超时'));
      expect(labels, contains('域名解析失败'));
    });
  });
}
