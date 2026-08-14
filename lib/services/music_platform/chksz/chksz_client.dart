import 'dart:async';

import 'package:pure_music/services/music_platform/chksz/chksz_error.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_quota.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_request.dart';

typedef ChkszApiKeyProvider = String? Function();
typedef ChkszBusinessSuccess = bool Function(Map<String, dynamic> body);
typedef ChkszDelay = Future<void> Function(Duration duration);
typedef ChkszClock = DateTime Function();

final class ChkszJsonResponse {
  const ChkszJsonResponse({
    required this.body,
    required this.quota,
    this.message,
  });

  final Map<String, dynamic> body;
  final ChkszQuotaSnapshot quota;
  final String? message;
}

final class ChkszClient {
  ChkszClient({
    required ChkszTransport transport,
    required ChkszApiKeyProvider apiKeyProvider,
    ChkszDelay? delay,
    ChkszClock? clock,
  }) : _transport = transport,
       _apiKeyProvider = apiKeyProvider,
       _delay = delay ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now;

  final ChkszTransport _transport;
  final ChkszApiKeyProvider _apiKeyProvider;
  final ChkszDelay _delay;
  final ChkszClock _clock;

  Future<ChkszJsonResponse> sendJson(
    ChkszRequest request, {
    required ChkszBusinessSuccess isBusinessSuccess,
    ChkszCancelToken? cancelToken,
  }) async {
    final token = cancelToken ?? ChkszCancelToken();
    _throwIfCancelled(token);
    final key = _apiKeyProvider();
    if (key == null || !isValidChkszApiKeyFormat(key)) {
      throw const ChkszException(
        kind: ChkszErrorKind.unauthorized,
        safeMessage: '请先配置有效的 ChKSz API Key',
      );
    }
    final authorized = request.authorize(key);

    for (var attempt = 0; attempt < 2; attempt++) {
      _throwIfCancelled(token);
      final response = await _send(authorized, token);
      final retryAfter = _retryAfter(response.headers);
      if (response.statusCode == 429 && attempt == 0 && retryAfter != null) {
        await _waitForRetry(retryAfter, token);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ChkszException.fromResponse(
          statusCode: response.statusCode,
          data: response.data,
          retryAfter: retryAfter,
        );
      }
      final body = _jsonObject(response.data);
      if (!isBusinessSuccess(body)) {
        throw ChkszException.businessFailure(body);
      }
      return ChkszJsonResponse(
        body: body,
        quota: ChkszQuotaSnapshot.fromHeaders(response.headers),
        message: chkszSafeBusinessMessage(body),
      );
    }
    throw StateError('Unreachable ChKSz retry state');
  }

  Future<ChkszTransportResponse> _send(
    ChkszAuthorizedRequest request,
    ChkszCancelToken token,
  ) async {
    try {
      return await _transport.send(request, cancelToken: token);
    } on ChkszException {
      rethrow;
    } catch (_) {
      _throwIfCancelled(token);
      throw ChkszException.network();
    }
  }

  Future<void> _waitForRetry(
    Duration retryAfter,
    ChkszCancelToken token,
  ) async {
    await Future.any<void>([
      _delay(retryAfter),
      token.whenCancelled.then((_) => throw ChkszException.cancelled()),
    ]);
    _throwIfCancelled(token);
  }

  Duration? _retryAfter(Map<String, List<String>> headers) {
    final raw = chkszHeaderValue(headers, 'Retry-After');
    if (raw == null || raw.isEmpty) return null;
    final seconds = int.tryParse(raw);
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    final date = DateTime.tryParse(raw)?.toUtc();
    if (date == null) return null;
    final duration = date.difference(_clock().toUtc());
    return duration.isNegative ? Duration.zero : duration;
  }

  Map<String, dynamic> _jsonObject(Object? data) {
    if (data is! Map) {
      throw const ChkszException(
        kind: ChkszErrorKind.invalidResponse,
        safeMessage: '音乐服务返回了无法识别的数据',
      );
    }
    return data.map((key, value) => MapEntry(key.toString(), value));
  }

  void _throwIfCancelled(ChkszCancelToken token) {
    if (token.isCancelled) throw ChkszException.cancelled();
  }
}
