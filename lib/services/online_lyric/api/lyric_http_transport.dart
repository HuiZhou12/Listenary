import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// 歌词下载的 HTTP 动作。
///
/// 只区分现状用到的 GET / POST，不引入方法枚举之外的能力。
enum LyricHttpMethod { get, post }

/// 歌词下载请求：method / 绝对 URL / headers / body。
///
/// 不含凭据、代理与取消参数：歌词源是匿名公共接口，传输抽象不扩张语义。
@immutable
class LyricHttpRequest {
  const LyricHttpRequest({
    required this.method,
    required this.url,
    this.headers,
    this.body,
  });

  final LyricHttpMethod method;

  /// 绝对 URL；query 由调用侧按改造前的方式拼好，避免两处编码规则。
  final Uri url;

  /// `null` 表示「不加任何自定义 header」，与改造前 GET 的可空形态一致。
  final Map<String, String>? headers;

  final String? body;
}

/// 原文响应：`statusCode` 与严格 UTF-8 解码后的原始 body。
///
/// body **不**由传输层解析成对象，各源仍自行 `jsonDecode`。
@immutable
class LyricHttpResponse {
  const LyricHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// 歌词专用最小 transport：发出请求，返回状态码与**原文** body。
///
/// 与 `music_platform` 的 `DeclarativeHttpTransport` / `ChkszTransport` 不合流：
/// 那两套面向相对路径、凭据引用与 JSON 自动解码，而歌词下载是 5 个第三方域的
/// 绝对 URL、匿名访问、原文响应。新建最小接口是保持现状语义的唯一方式。
///
/// 契约：
/// - 成功：返回对端状态码 + 严格 UTF-8 解码后的原文 body（**不**预先解析）；
/// - 非 200：仍返回状态码，但**不读取响应体**，`body` 为空串 —— 与改造前
///   「判到非 200 立即关闭 client」一致；`null` 哨兵由调用侧统一产生；
/// - 传输异常（连接失败、严格 UTF-8 解码失败等）：返回 `null`；
/// - 失败**不产生**任何日志或回调（失败可观测性保持改造前的全静默）。
abstract interface class LyricHttpTransport {
  Future<LyricHttpResponse?> send(LyricHttpRequest request);
}

/// 进程级工厂：调用方 isolate 读取后随 [Isolate.run] 闭包进入执行 isolate，
/// transport 实例在**执行 isolate 内**构造，实例本身不跨界。
typedef LyricHttpTransportFactory = LyricHttpTransport Function();

/// 严格 UTF-8 解码（`allowMalformed: false`），非法字节抛 [FormatException]。
///
/// 改造前由 `response.transform(utf8.decoder).join()` 提供同样的严格性；
/// 抽成函数使「严格」可以离线断言，不需要真实 socket。
String decodeLyricBodyStrict(List<int> bytes) =>
    utf8.decode(bytes, allowMalformed: false);

/// 默认实现：逐字照搬改造前 `isolate_helpers.dart` 私有 client 的形态。
///
/// 每个 [send] 自建 `HttpClient` 并设 4s 连接超时；GET 先移除 `Accept-Encoding`
/// 再挂自定义 header（不协商 gzip）；任何异常都吞成 `null`，不新增日志。
final class IoLyricHttpTransport implements LyricHttpTransport {
  const IoLyricHttpTransport();

  @override
  Future<LyricHttpResponse?> send(LyricHttpRequest request) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 4);
      final httpRequest = switch (request.method) {
        LyricHttpMethod.get => await client.getUrl(request.url),
        LyricHttpMethod.post => await client.postUrl(request.url),
      };
      if (request.method == LyricHttpMethod.get) {
        httpRequest.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      }
      final headers = request.headers;
      if (headers != null) {
        for (final entry in headers.entries) {
          httpRequest.headers.add(entry.key, entry.value);
        }
      }
      if (request.method == LyricHttpMethod.post) {
        httpRequest.write(request.body ?? '');
      }
      final response = await httpRequest.close();
      if (response.statusCode != 200) {
        // 与改造前一致：判到非 200 立即关闭，不读取响应体。
        client.close();
        return LyricHttpResponse(statusCode: response.statusCode, body: '');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      final res = decodeLyricBodyStrict(bytes.takeBytes());
      client.close();
      return LyricHttpResponse(statusCode: response.statusCode, body: res);
    } catch (_) {
      return null;
    }
  }
}

LyricHttpTransportFactory _lyricHttpTransportFactory = IoLyricHttpTransport.new;

/// 当前进程级工厂；默认返回生产实现 [IoLyricHttpTransport]。
LyricHttpTransportFactory get lyricHttpTransportFactory =>
    _lyricHttpTransportFactory;

/// 只允许测试改写工厂；传 `null` 复位为生产实现。
///
/// 传入的工厂必须**可跨 isolate 发送**：顶层/静态函数 tear-off，或只捕获
/// 可发送数据（`SendPort`、`String`、`List`、`Map` 等）的闭包。带原生资源的
/// 对象（`HttpClient`、`ReceivePort`、`Dio`）不可捕获，否则 `Isolate.run`
/// 运行期失败 —— 这正是「transport 实例不跨界」的强制点。
@visibleForTesting
void setLyricHttpTransportFactoryForTest(LyricHttpTransportFactory? factory) {
  _lyricHttpTransportFactory = factory ?? IoLyricHttpTransport.new;
}
