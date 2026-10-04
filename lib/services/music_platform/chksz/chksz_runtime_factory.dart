import 'package:dio/dio.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_dio_transport.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_provider_config.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_runtime.dart';
import 'package:pure_music/services/music_platform/provider/online_music_provider_auth.dart';

Dio createChkszDio({
  ChkszProviderConfig config = ChkszProviderConfig.defaults,
}) {
  return Dio(
    BaseOptions(
      baseUrl: config.baseUrl,
      connectTimeout: config.connectTimeout,
      sendTimeout: config.sendTimeout,
      receiveTimeout: config.receiveTimeout,
    ),
  );
}

ChkszRuntime createChkszRuntime({
  ChkszCredentialProvider? credentialProvider,
  ChkszProviderConfig config = ChkszProviderConfig.defaults,
  OnlineMusicAuthResolver authResolver = defaultOnlineMusicAuthResolver,
  Dio? dio,
}) {
  final ownedDio = dio ?? createChkszDio(config: config);
  return ChkszRuntime(
    credentialProvider: credentialProvider,
    transport: ChkszDioTransport(dio: ownedDio),
    disposeTransport: () => ownedDio.close(force: true),
    authResolver: authResolver,
  );
}
