import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/page/online_music_page.dart';

void main() {
  testWidgets('renders online destination and exposes search command', (
    tester,
  ) async {
    var searchCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OnlineMusicPage(onSearch: () => searchCount++),
        ),
      ),
    );

    expect(find.text('在线音乐'), findsOneWidget);
    expect(find.text('搜索在线音乐'), findsOneWidget);

    await tester.tap(find.text('搜索在线音乐'));
    expect(searchCount, 1);
  });
}
