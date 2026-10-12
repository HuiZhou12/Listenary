import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/page/page_scaffold.dart';

/// **标题层级语义**（2026-10-12，依据 `docs/reference/ytmusic/` 的本地可访问性树 ✓）。
///
/// 参考产品里：
/// - **页面标题 = `heading [level=1]`** —— 专辑页「世界」、艺人页「G.E.M. 鄧紫棋」✓；
/// - **区块标题 = `heading [level=2]`** —— Home **13 个货架**、Explore **4 区块**、
///   艺人页的「热门歌曲 / 专辑 / 单曲和迷你专辑 / 视频 / 现场表演」✓。
///
/// 我们此前两者都是**纯文本** ✗ ⇒ 读屏用户读不出层级 ✓。这条测试把"必须标成 header"钉住 ✓；
/// 副标题与说明行**不是** header 也一并钉住（别把层级标错 ✓）。
void main() {
  testWidgets('页面标题带 header 语义（对应参考的 level=1）', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PageScaffold(
            title: '世界',
            actions: [],
            body: SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.text('世界')),
      isSemantics(isHeader: true, label: '世界'),
      reason: '页面标题必须是 heading（参考产品是 level=1）',
    );
    handle.dispose();
  });

  testWidgets('带副标题时标题仍是 header，副标题不是（宽窄两种布局都算）', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PageScaffold(
            title: '故里逢春',
            subtitle: '来源：网易云 · 2 首曲目',
            actions: [],
            body: SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.text('故里逢春')),
      isSemantics(isHeader: true, label: '故里逢春'),
      reason: '有副标题时标题同样要标 header',
    );
    expect(
      tester.getSemantics(find.text('来源：网易云 · 2 首曲目')),
      isNot(isSemantics(isHeader: true)),
      reason: '副标题**不是**标题，标成 header 会把层级说错',
    );
    handle.dispose();
  });

  testWidgets('区块标题带 header 语义（对应参考的 level=2）', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ContentSection(title: '热门歌曲', child: SizedBox.shrink()),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.text('热门歌曲')),
      isSemantics(isHeader: true, label: '热门歌曲'),
      reason: '区块标题必须是 heading（参考产品是 level=2）',
    );
    handle.dispose();
  });

  testWidgets('区块的说明行不是 header（与标题分开）', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ContentSection(
            title: '曲目',
            subtitle: '专辑曲目有顺序 ⇒ 行首给序号',
            child: SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.text('曲目')),
      isSemantics(isHeader: true, label: '曲目'),
      reason: '区块标题要标 header',
    );
    expect(
      tester.getSemantics(find.text('专辑曲目有顺序 ⇒ 行首给序号')),
      isNot(isSemantics(isHeader: true)),
      reason: '说明行是正文，不该被当成标题',
    );
    handle.dispose();
  });
}
