import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/entry.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

void main() {
  test('Entry keeps the explicitly injected service and settings controller', () {
    final runtime = ChkszRuntime(
      credentialProvider: InMemoryChkszCredentialProvider(),
      transport: _UnexpectedTransport(),
    );
    final provider = ChkszOnlineMusicProvider(runtime: runtime);
    final service = CompositeOnlineMusicService(
      registry: OnlineMusicProviderRegistry(providers: [provider]),
    );
    final settings = OnlineMusicProviderSettingsController(
      activeSettings: OnlineMusicSettings.defaults,
      store: _MemorySettingsStore(),
      fallbackCredentials: _UnusedCredentialAccess(),
    );
    final entry = Entry(
      welcome: true,
      onlineMusicService: service,
      onlineMusicSettings: settings,
    );

    expect(entry.onlineMusicService, same(service));
    expect(entry.onlineMusicSettings, same(settings));
    settings.dispose();
    service.dispose();
  });
}

final class _MemorySettingsStore implements OnlineMusicSettingsStore {
  OnlineMusicSettings value = OnlineMusicSettings.defaults;

  @override
  OnlineMusicSettings read() => value;

  @override
  Future<bool> write(OnlineMusicSettings settings) async {
    value = settings;
    return true;
  }
}

final class _UnusedCredentialAccess implements OnlineMusicCredentialAccess {
  @override
  String get credentialDisplayName => 'API Key';

  @override
  String get inputHint => 'chksz_...';

  @override
  bool isValidFormat(String value) => value.startsWith('chksz_');

  @override
  Future<bool> isConfigured(String reference) async => false;

  @override
  Future<void> save(String reference, String value) async {}

  @override
  Future<void> clear(String reference) async {}
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
