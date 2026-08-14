import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/utils.dart';

const _fakeApiKey = 'chksz_TEST_ONLY';

void main() {
  test('redacts ChKSz keys and common credential fields', () {
    const input =
        'apikey=$_fakeApiKey | '
        'api_key=$_fakeApiKey | '
        'Authorization: Bearer $_fakeApiKey | '
        'cookie=session=$_fakeApiKey';

    final redacted = redactDiagnosticData(input);

    expect(redacted, isNot(contains(_fakeApiKey)));
    expect(redacted, contains('apikey=[redacted]'));
    expect(redacted, contains('api_key=[redacted]'));
    expect(redacted, contains('Authorization=[redacted]'));
    expect(redacted, contains('cookie=[redacted]'));
  });

  test('removes the complete query from diagnostic URLs', () {
    const input =
        'GET https://api.chksz.invalid/api/search?keyword=test&apikey=$_fakeApiKey';

    final redacted = redactDiagnosticData(input);

    expect(redacted, 'GET https://api.chksz.invalid/api/search?[redacted]');
    expect(redacted, isNot(contains(_fakeApiKey)));
    expect(redacted, isNot(contains('keyword=test')));
  });
}
