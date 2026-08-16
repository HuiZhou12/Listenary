import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

void main() {
  test('online destination is first without changing local start pages', () {
    expect(destinations.first.label, '在线音乐');
    expect(destinations.first.desPath, app_paths.ONLINE_MUSIC_PAGE);
    expect(destinations.first.startPageIndex, isNull);

    final localDestinations = destinations
        .where((destination) => destination.startPageIndex != null)
        .toList(growable: false);
    expect(
      localDestinations.map((destination) => destination.desPath),
      app_paths.START_PAGES,
    );
    expect(
      localDestinations.map((destination) => destination.startPageIndex),
      [0, 1, 2, 3, 4],
    );
  });

  test('non-start destinations do not map to a local start page', () {
    for (final path in [
      app_paths.ONLINE_MUSIC_PAGE,
      app_paths.STATS_PAGE,
      app_paths.SETTINGS_PAGE,
    ]) {
      expect(
        destinations.singleWhere((destination) => destination.desPath == path)
            .startPageIndex,
        isNull,
      );
    }
  });
}
