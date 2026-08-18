import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/entry.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

void main() {
  test('Entry keeps the explicitly injected ChKSz runtime', () {
    final runtime = ChkszRuntime(
      credentialProvider: InMemoryChkszCredentialProvider(),
      transport: _UnexpectedTransport(),
    );
    final provider = ChkszOnlineMusicProvider(runtime: runtime);
    final entry = Entry(
      welcome: true,
      onlineMusicService: provider,
      onlineMusicCredentials: provider,
    );

    expect(entry.onlineMusicService, same(provider));
    expect(entry.onlineMusicCredentials, same(provider));
    provider.dispose();
  });
}

final class _UnexpectedTransport implements ChkszTransport {
  @override
  Future<ChkszTransportResponse> send(
    ChkszAuthorizedRequest request, {
    required ChkszCancelToken cancelToken,
  }) {
    throw StateError('Entry construction must not send a request');
  }
}
