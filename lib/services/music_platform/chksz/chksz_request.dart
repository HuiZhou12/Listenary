import 'dart:async';

enum ChkszHttpMethod { get, post }

final class ChkszRequest {
  ChkszRequest({
    required this.path,
    this.method = ChkszHttpMethod.get,
    Map<String, String> queryParameters = const {},
  }) : queryParameters = Map.unmodifiable(queryParameters) {
    if (!path.startsWith('/api/') || path.contains('?') || path.contains('#')) {
      throw ArgumentError.value(path, 'path', 'Must be a clean /api/ path');
    }
    if (queryParameters.keys.any((key) => key.toLowerCase() == 'apikey')) {
      throw ArgumentError('apikey is injected by ChkszClient');
    }
  }

  final String path;
  final ChkszHttpMethod method;
  final Map<String, String> queryParameters;

  ChkszAuthorizedRequest authorize(String apiKey) {
    if (!isValidChkszApiKeyFormat(apiKey)) {
      throw const FormatException('Invalid ChKSz API Key format');
    }
    return ChkszAuthorizedRequest._(
      path: path,
      method: method,
      queryParameters: {...queryParameters, 'apikey': apiKey},
    );
  }
}

final class ChkszAuthorizedRequest {
  ChkszAuthorizedRequest._({
    required this.path,
    required this.method,
    required Map<String, String> queryParameters,
  }) : queryParameters = Map.unmodifiable(queryParameters);

  final String path;
  final ChkszHttpMethod method;
  final Map<String, String> queryParameters;

  @override
  String toString() =>
      'ChkszAuthorizedRequest(method=${method.name}, path=$path, query=[redacted])';
}

bool isValidChkszApiKeyFormat(String value) {
  return RegExp(r'^chksz_\S+$').hasMatch(value);
}

final class ChkszCancelToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

abstract interface class ChkszTransport {
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  });
}

final class ChkszTransportResponse {
  ChkszTransportResponse({
    required this.statusCode,
    required this.data,
    Map<String, List<String>> headers = const {},
  }) : headers = Map<String, List<String>>.unmodifiable(
         headers.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       );

  final int statusCode;
  final Object? data;
  final Map<String, List<String>> headers;
}
