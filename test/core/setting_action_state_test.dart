import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/setting_action_state.dart';

void main() {
  test('minimum-only window snapshots fall back to the default size', () {
    expect(
      normalizedWindowSizeSetting('360,240'),
      equals(defaultWindowSizeSetting),
    );
    expect(
      normalizedWindowSizeSetting('320,200'),
      equals(defaultWindowSizeSetting),
    );
  });

  test('usable custom window sizes remain unchanged apart from minimum clamp', () {
    expect(
      normalizedWindowSizeSetting('720,480'),
      equals((width: 720.0, height: 480.0)),
    );
    expect(
      normalizedWindowSizeSetting('400,200'),
      equals((width: 400.0, height: 240.0)),
    );
  });
}
