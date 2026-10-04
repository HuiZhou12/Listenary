import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';

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
    if (queryParameters.keys.any(
      (key) => key.toLowerCase() == defaultOnlineMusicCredentialParameter,
    )) {
      throw ArgumentError(
        '$defaultOnlineMusicCredentialParameter is injected by ChkszClient',
      );
    }
  }

  final String path;
  final ChkszHttpMethod method;
  final Map<String, String> queryParameters;

  /// 注入凭据；参数名由调用方的认证要求决定，默认沿用 ChkSz 的 `apikey`。
  ChkszAuthorizedRequest authorize(
    String apiKey, {
    String parameterName = defaultOnlineMusicCredentialParameter,
  }) {
    if (!isValidChkszApiKeyFormat(apiKey)) {
      throw const FormatException('Invalid ChKSz API Key format');
    }
    if (queryParameters.containsKey(parameterName)) {
      throw ArgumentError('$parameterName is injected by ChkszClient');
    }
    return ChkszAuthorizedRequest._(
      path: path,
      method: method,
      queryParameters: {...queryParameters, parameterName: apiKey},
    );
  }

  /// 不携带任何凭据的请求；Provider 声明 `auth.kind = none` 时使用。
  ChkszAuthorizedRequest withoutCredentials() => ChkszAuthorizedRequest._(
    path: path,
    method: method,
    queryParameters: queryParameters,
  );
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

typedef ChkszCancelToken = OnlineMusicCancelToken;

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
