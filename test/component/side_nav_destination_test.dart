import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/side_nav.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

void main() {
  test('home is first and local start pages keep their stored indices', () {
    // 主页放在第一位：它是多平台聚合的统一入口。
    expect(destinations.first.label, '主页');
    expect(destinations.first.desPath, app_paths.HOME_PAGE);
    // 主页**追加**在 START_PAGES 表尾（不能往中间插：startPage 存的是下标，
    // 插到中间会让老用户已选的启动页漂移到别的页面上）。
    expect(destinations.first.startPageIndex, app_paths.HOME_START_PAGE_INDEX);
    expect(
      app_paths.START_PAGES[app_paths.HOME_START_PAGE_INDEX],
      app_paths.HOME_PAGE,
    );

    final localDestinations = destinations
        .where((destination) => destination.startPageIndex != null)
        .toList(growable: false);
    // 每个可作启动页的路径都有一个目的页，且下标与 START_PAGES 对齐
    // （显示顺序可以不同：主页显示在最前，但它的启动页下标仍排在表尾）。
    final byIndex = {
      for (final destination in localDestinations)
        destination.startPageIndex!: destination.desPath,
    };
    expect(byIndex.length, app_paths.START_PAGES.length);
    for (var index = 0; index < app_paths.START_PAGES.length; index++) {
      expect(byIndex[index], app_paths.START_PAGES[index]);
    }
  });

  test('non-start destinations do not map to a local start page', () {
    for (final path in [
      app_paths.ONLINE_MUSIC_PAGE,
      app_paths.FAVORITES_PAGE,
      app_paths.STATS_PAGE,
      app_paths.SETTINGS_PAGE,
    ]) {
      expect(
        destinations
            .singleWhere((destination) => destination.desPath == path)
            .startPageIndex,
        isNull,
      );
    }
  });

  test('start pages are unique and every destination path is distinct', () {
    // 启动页按下标存储：重复项会让两个目的页抢同一个启动页下标。
    expect(
      app_paths.START_PAGES.toSet().length,
      app_paths.START_PAGES.length,
      reason: 'START_PAGES 不允许出现重复路径',
    );
    final paths = destinations.map((d) => d.desPath).toList(growable: false);
    expect(
      paths.toSet().length,
      paths.length,
      reason: '侧边栏目的页不允许重复，否则 currentIndex 语义有歧义',
    );
  });

  test('navigation groups cover every destination once in route order', () {
    expect(destinationGroups.map((group) => group.label), [
      '聚合',
      '本地曲库',
      '收藏与回顾',
      '系统',
    ]);
    expect(
      destinationGroups.expand((group) => group.destinationIndices),
      List.generate(destinations.length, (index) => index),
    );
  });
}
