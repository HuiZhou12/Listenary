import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/entry.dart';
import 'package:pure_music/services/music_platform/chksz/chksz_credential_provider.dart';

void main() {
  test('Entry keeps the explicitly injected credential provider', () {
    final provider = InMemoryChkszCredentialProvider();
    final entry = Entry(welcome: true, credentialProvider: provider);

    expect(entry.credentialProvider, same(provider));
  });
}
