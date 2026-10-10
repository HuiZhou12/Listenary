import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_http_transport.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';

/// F4-S6（P-40）：响应体**按内容**判断是不是 JSON ——
/// 服务返回 JSON 却把 `Content-Type` 标成 `text/plain` 时不能再被误报成"接口不匹配"；
/// 但真正的非 JSON 响应（HTML / 纯文本）必须**原样保留**、在映射阶段明确失败（不得误放宽）。
void main() {
  group('★ F4-S6 响应体按内容判断 JSON（P-40）', () {
    test('JSON 对象被标成 text/plain ⇒ 仍按 JSON 解析', () {
      final decoded = decodeDeclarativeResponseBody(
        '{"code":200,"result":{"songs":[{"id":1,"name":"A"}]}}',
      );

      expect(decoded, isA<Map<String, Object?>>());
      expect((decoded! as Map)['code'], 200);
    });

    test('JSON 数组 / 带引号的标量同样按内容解析', () {
      expect(decodeDeclarativeResponseBody('[1,2,3]'), isA<List<Object?>>());
      expect(decodeDeclarativeResponseBody('"abc"'), 'abc');
    });

    test('HTML / 纯文本 ⇒ **原样保留字符串**（不得悄悄当成成功）', () {
      const html = '<!DOCTYPE html><html><body>oops</body></html>';

      expect(decodeDeclarativeResponseBody(html), html);
      expect(decodeDeclarativeResponseBody('plain text'), 'plain text');
      expect(
        decodeDeclarativeResponseBody('{oops}'),
        '{oops}',
        reason: '看起来像 JSON 但解析失败 ⇒ 原样保留，交给映射阶段明确失败',
      );
      expect(decodeDeclarativeResponseBody(''), '');
    });

    test('已经是结构化数据 ⇒ 原样返回（不重复解析）', () {
      final map = <String, Object?>{'a': 1};
      final list = <Object?>[1, 2];
      expect(decodeDeclarativeResponseBody(map), same(map));
      expect(decodeDeclarativeResponseBody(list), same(list));
      expect(decodeDeclarativeResponseBody(200), 200);
      expect(decodeDeclarativeResponseBody(true), true);
      expect(decodeDeclarativeResponseBody(null), isNull);
    });

    test('内容判定之后映射阶段照常工作（端到端一小步）', () {
      final decoded = decodeDeclarativeResponseBody(
        '{"result":{"songs":[{"id":1,"name":"A"}]}}',
      );
      final page = mapDeclarativeSearchResponse(
        spec: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('result.songs'),
          fields: {
            OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
              candidates: [JsonPath.tryParse('id')!],
              transform: OnlineMusicFieldTransform.asInt,
              required: true,
            ),
            OnlineMusicDomainField.title: OnlineMusicFieldSpec(
              candidates: [JsonPath.tryParse('name')!],
              transform: OnlineMusicFieldTransform.asString,
              required: true,
            ),
          },
        ),
        body: decoded,
        platform: MusicPlatform.netease,
        limit: 10,
        offset: 0,
      );

      expect(page.items.single.title, 'A');
    });

    test('源码守卫：真传输必须走"内容判定"这条路径', () {
      final source = File(
        'lib/services/music_platform/declarative/declarative_http_transport.dart',
      ).readAsStringSync();

      expect(source, contains('data: decodeDeclarativeResponseBody(response.data)'));
    });
  });
}
