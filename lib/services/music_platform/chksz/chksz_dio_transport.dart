import 'dart:async';

import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';

final class ChkszDioTransport implements ChkszTransport {
  ChkszDioTransport({required Dio dio}) : _dio = dio;

  final Dio _dio;

  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
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
      queryParameters: request.queryParameters,
      options: Options(
        method: request.method.name.toUpperCase(),
        responseType: ResponseType.json,
        validateStatus: (_) => true,
      ),
      cancelToken: dioCancelToken,
    );
    final statusCode = response.statusCode;
    if (statusCode == null) {
      throw StateError('Dio response did not include an HTTP status');
    }
    return ChkszTransportResponse(
      statusCode: statusCode,
      data: response.data,
      headers: response.headers.map,
    );
  }
}
