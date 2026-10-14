import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/home_greeting_header.dart';

/// **主页问候头**（2026-10-12 新增 ✓）。
///
/// 用户给定的六段时间与文案 ✓；这里把**每个边界**都钉住 ✓ ——
/// 时间段是那种"看一遍觉得对、边界差一分钟就错"的东西 ✗（尤其**深夜跨零点** ✓）。
void main() {
  /// 便捷构造：某天某时某分 ✓。
  DateTime at(int hour, int minute) => DateTime(2026, 10, 12, hour, minute);

  test('六段时间的边界（含深夜跨零点）都对得上', () {
    // 清晨 06:00–09:00
    expect(greetingFor(now: at(6, 0)).title, '早安，佬友');
    expect(greetingFor(now: at(6, 0)).eyebrow, 'MORNING VIBES');
    expect(greetingFor(now: at(8, 59)).title, '早安，佬友');
    // 上午 09:00–11:30
    expect(greetingFor(now: at(9, 0)).title, '上午好，佬友');
    expect(greetingFor(now: at(11, 29)).title, '上午好，佬友');
    // 正午 11:30–14:00
    expect(greetingFor(now: at(11, 30)).title, '午安，佬友');
    expect(greetingFor(now: at(13, 59)).title, '午安，佬友');
    // 下午 14:00–18:00
    expect(greetingFor(now: at(14, 0)).title, '下午好，佬友');
    expect(greetingFor(now: at(17, 59)).title, '下午好，佬友');
    // 傍晚 18:00–22:00
    expect(greetingFor(now: at(18, 0)).title, '晚上好，佬友');
    expect(greetingFor(now: at(21, 59)).title, '晚上好，佬友');
    // 深夜 22:00–05:59（**跨零点** ✓：顺序写反就会把凌晨判成"清晨" ✗）
    expect(greetingFor(now: at(22, 0)).title, '要来一首助眠曲吗？');
    expect(greetingFor(now: at(23, 59)).title, '要来一首助眠曲吗？');
    expect(greetingFor(now: at(0, 30)).title, '要来一首助眠曲吗？');
    expect(greetingFor(now: at(5, 59)).title, '要来一首助眠曲吗？');
    // 深夜的小字按用户给的文案 ✓（这一条**不带名字** ✓）。
    expect(greetingFor(now: at(2, 0)).eyebrow, '夜深了，世界安静下来了');
  });

  test('每个时段的小字与用户给的文案一致', () {
    expect(greetingFor(now: at(9, 30)).eyebrow, '准备进入状态了吗');
    expect(greetingFor(now: at(12, 0)).eyebrow, '小憩片刻，充个电吧');
    expect(greetingFor(now: at(15, 0)).eyebrow, '伴你度过专注时光');
    expect(greetingFor(now: at(19, 0)).eyebrow, '卸下一天的疲惫');
  });

  test('名字是可控参数（开发期占位「佬友」，将来换成账号昵称）', () {
    expect(greetingFor(now: at(10, 0)).title, '上午好，佬友');
    expect(greetingFor(now: at(10, 0), userName: '阿伟').title, '上午好，阿伟');
    expect(HomeGreetingHeader.defaultUserName, '佬友');
  });

  test('超过 3 天没打开 ⇒ 「好久不见」，压过时段文案；没超过就照常', () {
    final tooLong = greetingFor(
      now: at(10, 0),
      returningAfter: const Duration(days: 3, hours: 1),
    );
    expect(tooLong.title, '好久不见，甚是想念');
    expect(tooLong.eyebrow, '这段时间都没见你');

    // 刚好 3 天**不算**超过 ✓（口径：超过 3 天 ✓）。
    expect(
      greetingFor(now: at(10, 0), returningAfter: const Duration(days: 3)).title,
      '上午好，佬友',
    );
    expect(
      greetingFor(
        now: at(10, 0),
        returningAfter: const Duration(hours: 5),
      ).title,
      '上午好，佬友',
    );
  });

  testWidgets('渲染：小字在上、大字在下且加粗；不带头像', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeGreetingHeader(now: DateTime(2026, 10, 12, 10)),
        ),
      ),
    );

    expect(find.text('准备进入状态了吗'), findsOneWidget);
    expect(find.text('上午好，佬友'), findsOneWidget);

    final title = tester.widget<Text>(find.text('上午好，佬友'));
    expect(title.style?.fontWeight, FontWeight.bold, reason: '主标题必须加粗 ✓');
    expect(
      title.style!.fontSize! > tester.widget<Text>(find.text('准备进入状态了吗')).style!.fontSize!,
      isTrue,
      reason: '主标题必须比小字大 ✓',
    );
    // 无头像 ✓（组件里没有任何图片）。
    expect(find.byType(Image), findsNothing);
  });
}
