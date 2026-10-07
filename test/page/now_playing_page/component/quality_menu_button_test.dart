import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/page/now_playing_page/component/quality_menu_button.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// S8：播放页档位菜单 —— 只列**当前 Track 所属平台**声明的档位，用**平台自己的文案**
/// （D2:A / D10:A / I4），回落时明确写出"已回落为 X"。
void main() {
  // 一个"像 QQ 那样"的平台档位集合：内部键与平台文案并不一一对应。
  const qqTiers = [
    PlatformQualityTier(
      internalLevel: 'standard',
      displayLabel: '标准',
      requestValue: '1',
    ),
    PlatformQualityTier(
      internalLevel: 'lossless',
      displayLabel: 'SQ',
      requestValue: 'sq',
    ),
    PlatformQualityTier(
      internalLevel: 'hires',
      displayLabel: 'Hi-Res',
      requestValue: 'hires',
    ),
  ];

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Symbols.high_quality));
    await tester.pumpAndSettle();
  }

  testWidgets('只列该平台声明的档位，并用平台自己的文案', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlatformQualityMenuButton(
            tiers: qqTiers,
            selection: selectPlatformQuality(
              tiers: qqTiers,
              preference: 'lossless',
            ),
            iconColor: Colors.white,
            onSelected: selected.add,
          ),
        ),
      ),
    );

    await openMenu(tester);

    // 平台自己的名字在；内部键不作文案出现。
    expect(find.text('SQ'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    expect(find.text('Hi-Res'), findsOneWidget);
    expect(find.text('lossless'), findsNothing);
    expect(find.text('exhigh'), findsNothing);
    // 平台没有声明的档位不出现（D2/D10 的核心要求）。
    expect(find.text('母带'), findsNothing);
    expect(find.text('沉浸声'), findsNothing);

    await tester.tap(find.text('SQ'));
    await tester.pumpAndSettle();
    // 选中回传的是**内部偏好档位**（跨平台语义）。
    expect(selected, ['lossless']);
  });

  testWidgets('解析结果落回更低档时，菜单里明确写出"已回落为 X"', (tester) async {
    final selection = selectPlatformQuality(
      tiers: qqTiers,
      // 用户偏好"母带"，QQ 只有到 Hi-Res。
      preference: 'jymaster',
    );
    expect(selection.fellBack, isTrue);
    expect(selection.displayLabel, 'Hi-Res');

    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlatformQualityMenuButton(
            tiers: qqTiers,
            selection: selection,
            iconColor: Colors.white,
            onOpened: () => opened++,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    await openMenu(tester);

    expect(find.text('已回落为 Hi-Res'), findsOneWidget);
    // 回落提示出现时，仍然照常列出该平台支持的档位。
    expect(find.text('SQ'), findsOneWidget);
    expect(opened, 1);
  });

  testWidgets('没有回落时不出现回落提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlatformQualityMenuButton(
            tiers: qqTiers,
            selection: selectPlatformQuality(
              tiers: qqTiers,
              preference: 'hires',
            ),
            iconColor: Colors.white,
            onSelected: (_) {},
          ),
        ),
      ),
    );

    await openMenu(tester);

    expect(find.textContaining('已回落为'), findsNothing);
  });

  testWidgets('平台没有档位声明时，菜单回到内部档位列表（既有行为不变）', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InternalQualityMenuButton(
            preference: 'lossless',
            iconColor: Colors.white,
            onSelected: selected.add,
          ),
        ),
      ),
    );

    await openMenu(tester);

    for (final quality in MusicQuality.values) {
      expect(find.text(quality.label), findsOneWidget);
    }

    await tester.tap(find.text('高品'));
    await tester.pumpAndSettle();
    expect(selected, ['exhigh']);
  });

  test('解析不到同档时取"不高于期望"的最接近档（确定性规则）', () {
    // 平台只有 standard / SQ / Hi-Res：偏好母带 → Hi-Res；偏好高品 → 标准。
    expect(
      selectPlatformQuality(
        tiers: qqTiers,
        preference: 'jymaster',
      ).displayLabel,
      'Hi-Res',
    );
    expect(
      selectPlatformQuality(tiers: qqTiers, preference: 'exhigh').displayLabel,
      '标准',
    );
    // 完全识别不了的偏好 → 落在平台**最低档**，并标记为回落。
    final lowest = selectPlatformQuality(
      tiers: qqTiers,
      preference: 'unknown-level',
    );
    expect(lowest.displayLabel, '标准');
    expect(lowest.fellBack, isTrue);
  });
}
