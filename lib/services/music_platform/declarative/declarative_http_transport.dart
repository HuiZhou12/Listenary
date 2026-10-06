/// 声明式能力的通用 HTTP 出口。
///
/// 与 ChkSz 的 `ChkszDioTransport` 平行但**协议中立**：不注入 api key、不解析配额头、
/// 不认识 `code/msg` 信封——这些差异现在都由配置描述。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';

final class DeclarativeHttpResponse {
  const DeclarativeHttpResponse({required this.statusCode, required this.data});

  final int statusCode;
  final Object? data;
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
      data: response.data,
    );
  }
}
