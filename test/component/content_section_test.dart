import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/content_section.dart';

/// 区块头与两种行内状态提示：区块头只在"标签 + 回调都在"时才给按钮；
/// 失败提示与空提示必须是**两种不同的组件**（文案与重试入口都不同）。
void main() {
  Future<void> pumpSection(
    WidgetTester tester, {
    String? subtitle,
    String? actionLabel,
    VoidCallback? onAction,
    Widget child = const Text('内容'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContentSection(
            title: '区块标题',
            subtitle: subtitle,
            actionLabel: actionLabel,
            onAction: onAction,
            child: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('标题与子内容总会渲染，副标题可选', (tester) async {
    await pumpSection(tester);
    expect(find.text('区块标题'), findsOneWidget);
    expect(find.text('内容'), findsOneWidget);

    await pumpSection(tester, subtitle: '一行说明');
    expect(find.text('一行说明'), findsOneWidget);
  });

  testWidgets('标签与回调都在时才有「查看全部」按钮', (tester) async {
    var taps = 0;
    await pumpSection(tester, actionLabel: '查看全部', onAction: () => taps++);

    expect(find.text('查看全部'), findsOneWidget);
    await tester.tap(find.text('查看全部'));
    expect(taps, 1);
  });

  testWidgets('只有标签没有回调时不渲染按钮（避免点了没反应的假入口）', (tester) async {
    await pumpSection(tester, actionLabel: '查看全部');

    expect(find.text('查看全部'), findsNothing);
  });

  testWidgets('失败提示带重试，空提示不带', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineFailureHint(
            message: '读取失败',
            onRetry: () => retried++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('读取失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, 1);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: InlineEmptyHint(icon: Icons.inbox, message: '还没有内容'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有内容'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });
}
