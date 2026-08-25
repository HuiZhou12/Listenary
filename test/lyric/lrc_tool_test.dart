import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/online_lyric/api/krc_extract_decode.dart';
import 'package:pure_music/services/online_lyric/models/lyric_entry.dart';
import 'package:pure_music/services/online_lyric/parsers/lrc_tool.dart';

void main() {
  test('recognizes a short enhanced LRC response', () {
    final lyric = LrcTool.parse('[00:01.000] <00:01.000>Hi<00:01.300>')!;

    expect(lyric.hasWordByWord, isTrue);
    expect(lyric.lines.single.words, isNotNull);
    expect(lyric.lines.single.words!.single.content, 'Hi');
  });

  test('clamps offset timestamps crossing zero', () {
    final lyric = LrcTool.parse(
      '[00:00.100]early\n[00:01.000]later',
      offset: const Duration(milliseconds: -500),
    )!;

    expect(lyric.lines.first.start, Duration.zero);
    expect(lyric.lines[1].start, const Duration(milliseconds: 500));
  });

  test('removes standalone QRC timing markers from romanization', () {
    final lyric = LrcTool.parse(
      '[52000,3000]もっと釣られて踊れるように(52000,3000)',
      romanizationText:
          '[52000,3000]mo (52000,100)\'tto (52100,323)'
          '(52423,0)tsu (52423,100)ra (52523,100)re (52623,100)'
          'te (52723,100)o (52823,100)do (52923,100)re (53023,100)'
          'ru (53123,100)yo (53223,100)u (53323,100)ni (53423,100)',
    );

    final line = lyric!.lines.firstWhere(
      (line) => line.content == 'もっと釣られて踊れるように',
    );
    expect(line.romanization, "mo 'tto tsu ra re te o do re ru yo u ni");
    expect(line.romanization, isNot(contains('(52423,0)')));
  });

  test('preserves romanization around punctuation for YRC lyrics', () {
    final lyric = LrcTool.parse(
      '[16780,3860](16780,330,0)な(17110,440,0)あ(17550,270,0)元'
      '(17820,610,0)気(18430,30,0)？　(18460,470,0)調(18930,290,0)子'
      '(19220,240,0)は(19460,180,0)ど(19640,90,0)う(19730,160,0)だ'
      '(19890,240,0)い(20130,510,0)？\n'
      '[20640,3390](20640,260,0)あ(20900,360,0)あ(21260,140,0)も'
      '(21400,160,0)う(21560,500,0)ね',
      romanizationText:
          '[00:16.332]na a ge n ki? cho u shi wa do u da i?\n'
          '[00:20.172]a a mo u ne',
    );

    final firstLyricLine = lyric!.lines.firstWhere(
      (line) => line.content.isNotEmpty,
    );
    expect(
      firstLyricLine.romanization,
      'na a ge n ki ? cho u shi wa do u da i ?',
    );
  });

  test('does not reuse timed subtitles across adjacent LRC lines', () {
    final lyric = LrcTool.parse(
      '[10104,1104]Luv (10104,232)me (10336,231)luv (10567,305)me(10872,336)\n'
      '[12545,1160]Hate (12545,198)me (12743,282)hate (13025,359)me(13384,321)\n'
      '[15007,1161]Luv (15007,256)me (15263,290)luv (15553,311)me(15864,304)\n'
      '[17512,1208]Kill (17512,281)me (17793,302)kill (18095,274)me(18369,351)\n'
      '[21303,2477]愛(21303,328)憎(21631,223)愛(21854,336)憎(22190,305)'
      '渦(22495,489)巻(22984,151)い(23135,180)て(23315,465)',
      transText: '[00:21.300]爱恨交织 在心里翻腾',
      romanizationText: '[00:21.302]a i zo u a i zo u u zu ma i te',
    );

    final killMe = lyric!.lines.firstWhere(
      (line) => line.content == 'Kill me kill me',
    );
    final aizo = lyric.lines.firstWhere((line) => line.content == '愛憎愛憎渦巻いて');
    expect(killMe.translation, isNull);
    expect(killMe.romanization, isNull);
    expect(aizo.translation, '爱恨交织 在心里翻腾');
    expect(aizo.romanization, 'a i zo u a i zo u u zu ma i te');
  });

  test('matches timed subtitles to the nearest closely spaced line', () {
    final lyric = LrcTool.parse(
      '[00:28.962]erase\n'
      '[00:29.121]remain',
      transText:
          '[00:28.960]remove\n'
          '[00:29.120]stays',
      romanizationText:
          '[00:28.961]e ra se\n'
          '[00:29.119]re ma in',
    )!;

    final erase = lyric.lines.firstWhere((line) => line.content == 'erase');
    final remain = lyric.lines.firstWhere((line) => line.content == 'remain');
    expect(erase.translation, 'remove');
    expect(erase.romanization, 'e ra se');
    expect(remain.translation, 'stays');
    expect(remain.romanization, 're ma in');
  });

  test(
    'keeps embedded KRC translations and romanization on their source line',
    () {
      final language = base64Encode(
        utf8.encode(
          jsonEncode({
            'content': [
              {
                'type': 0,
                'lyricContent': [
                  ['kyo ku', ':', 'sa ku sha'],
                  ['i chi'],
                  ['ni'],
                  ['sa n'],
                ],
              },
              {
                'type': 1,
                'lyricContent': [
                  [''],
                  ['第一译'],
                  [''],
                  ['第三译'],
                ],
              },
            ],
          }),
        ),
      );
      final main =
          '[language:$language]\n'
          '[0,900]<0,900,0>曲：作者\n'
          '[1000,900]<0,900,0>第一行\n'
          '[2000,900]<0,900,0>第二行\n'
          '[3000,900]<0,900,0>第三行';
      final languageData = extractKrcLanguage(main)!;
      final lyric = LrcTool.parse(
        main,
        transText: languageData.translation,
        romanizationText: languageData.romanization,
      )!;

      final first = lyric.lines.firstWhere((line) => line.content == '第一行');
      final second = lyric.lines.firstWhere((line) => line.content == '第二行');
      final third = lyric.lines.firstWhere((line) => line.content == '第三行');
      expect(first.translation, '第一译');
      expect(first.romanization, 'i chi');
      expect(second.translation, isNull);
      expect(second.romanization, 'ni');
      expect(third.translation, '第三译');
      expect(third.romanization, 'sa n');
    },
  );

  test('applies the [offset:] tag like the local parser', () {
    const base = '[00:10.00]line one\n[00:20.00]line two';
    int lineOneStart(ParsedLyricResult? r) => r!.lines
        .firstWhere((e) => e.content == 'line one')
        .start
        .inMilliseconds;

    final noTag = LrcTool.parse('[ti:test]\n[ar:test]\n$base');
    expect(lineOneStart(noTag), 10000);

    // 正 offset：行起点整体提前
    final positive = LrcTool.parse('[offset:1000]\n$base');
    expect(lineOneStart(positive), 9000);

    // 负 offset：行起点整体延后
    final negative = LrcTool.parse('[offset:-500]\n$base');
    expect(lineOneStart(negative), 10500);

    // offset 后 nextTime 与 start 同步偏移，行间长度保持一致
    final shifted = LrcTool.parse('[offset:1000]\n$base')!;
    final lineOne = shifted.lines.firstWhere((e) => e.content == 'line one');
    final lineTwo = shifted.lines.firstWhere((e) => e.content == 'line two');
    expect(lineTwo.start.inMilliseconds - lineOne.start.inMilliseconds, 10000);
  });
}
