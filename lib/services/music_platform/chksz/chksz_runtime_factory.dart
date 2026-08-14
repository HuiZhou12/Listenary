import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_dio_transport.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime.dart';

const chkszBaseUrl = 'https://api.chksz.com';
const chkszConnectTimeout = Duration(seconds: 8);
const chkszSendTimeout = Duration(seconds: 8);
const chkszReceiveTimeout = Duration(seconds: 10);

Dio createChkszDio() => Dio(
  BaseOptions(
    baseUrl: chkszBaseUrl,
    connectTimeout: chkszConnectTimeout,
    sendTimeout: chkszSendTimeout,
    receiveTimeout: chkszReceiveTimeout,
  ),
);

ChkszRuntime createChkszRuntime({
  required ChkszCredentialProvider credentialProvider,
  Dio? dio,
}) {
  final ownedDio = dio ?? createChkszDio();
  return ChkszRuntime(
    credentialProvider: credentialProvider,
    transport: ChkszDioTransport(dio: ownedDio),
    disposeTransport: () => ownedDio.close(force: true),
  );
}
