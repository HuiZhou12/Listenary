/// 声明式能力的通用 HTTP 出口。
///
/// 与 ChkSz 的 `ChkszDioTransport` 平行但**协议中立**：不注入 api key、不解析配额头、
/// 不认识 `code/msg` 信封——这些差异现在都由配置描述。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';

final class DeclarativeHttpResponse {
  const DeclarativeHttpResponse({required this.statusCode, required this.data});

  final int statusCode;
  final Object? data;
}

/// F4-S6（P-40）：**按内容**判断响应体是不是 JSON，而不是只看 `Content-Type`。
///
/// Dio 的 `ResponseType.json` 在 `Content-Type` 不是 JSON 时会把响应体作为**字符串**
/// 返回；有些服务明明返回 JSON 却标成 `text/plain` —— 以前这份字符串会一路传到映射阶段，
/// 被误报成"接口不匹配"（P-40），用户看到的结论与真实原因不符。
///
/// 规则（刻意**不误放宽**）：
/// - 只有"看起来像 JSON"的字符串才会尝试解析（对象 / 数组 / 带引号的标量）；
/// - 解析失败 ⇒ **原样保留字符串** ⇒ 真正的非 JSON 响应（HTML 错误页、纯文本）
///   仍会在映射阶段**明确失败**，不会被悄悄当成成功；
/// - 已经是结构化数据（Map / List / num / bool / null）时原样返回。
Object? decodeDeclarativeResponseBody(Object? data) {
  if (data is! String) return data;
  final text = data.trim();
  if (text.isEmpty) return data;
  final looksLikeJson =
      (text.startsWith('{') && text.endsWith('}')) ||
      (text.startsWith('[') && text.endsWith(']')) ||
      (text.length >= 2 && text.startsWith('"') && text.endsWith('"'));
  if (!looksLikeJson) return data;
  try {
    return jsonDecode(text);
  } on FormatException {
    return data;
  }
}

abstract interface class DeclarativeHttpTransport {
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  });
}

final class DioDeclarativeHttpTransport implements DeclarativeHttpTransport {
  DioDeclarativeHttpTransport({required Dio dio, this.followRedirects = true})
    : _dio = dio;

  final Dio _dio;

  /// 探测请求会把它设为 false，确保不会跟随到用户没有提供的主机。
  final bool followRedirects;

  @override
  Future<DeclarativeHttpResponse> send(
    BuiltDeclarativeRequest request, {
    required OnlineMusicCancelToken cancelToken,
  }) async {
    final dioCancelToken = CancelToken();
    if (cancelToken.isCancelled) dioCancelToken.cancel();
    unawaited(
      cancelToken.whenCancelled.then((_) {
        if (!dioCancelToken.isCancelled) dioCancelToken.cancel();
      }),
    );

    final response = await _dio.request<Object?>(
      request.path,
      queryParameters: request.query.isEmpty ? null : request.query,
      data: request.body,
      options: Options(
        method: request.method,
        headers: request.headers.isEmpty ? null : request.headers,
        responseType: ResponseType.json,
        contentType: request.isForm ? Headers.formUrlEncodedContentType : null,
        followRedirects: followRedirects,
        validateStatus: (_) => true,
      ),
      cancelToken: dioCancelToken,
    );
    final statusCode = response.statusCode;
    if (statusCode == null) {
      throw StateError('Dio response did not include an HTTP status');
    }
    return DeclarativeHttpResponse(
      statusCode: statusCode,
      // F4-S6（P-40）：按**内容**兜一次 JSON 解析（Dio 在 Content-Type 非 JSON 时给字符串）。
      data: decodeDeclarativeResponseBody(response.data),
    );
  }
}
