import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// **Map 值投影 + 标量单元素解包**（QQ 播放解析 `data.playUrl.<songmid>.url` 需要）。
///
/// 背景：有些接口把结果放进"键是动态 id"的对象里，键名事先无法写进路径 ⇒ 只能投影。
/// 旧实现 `[*]` **只对 List 生效**，对 Map 直接落空 ⇒ 这类服务无法配置（QQ 就是一例）。
void main() {
  group('JsonPath：投影语义', () {
    test('数组投影：`[*]` 展开每个元素（既有语义不变）', () {
      final path = JsonPath.tryParse('ar[*].name')!;
      expect(
        path.read(const {
          'ar': [
            {'name': 'A'},
            {'name': 'B'},
          ],
        }),
        ['A', 'B'],
      );
    });

    test('★ Map 值投影：`[*]` 展开对象的值（顺序 = 书写顺序）', () {
      final path = JsonPath.tryParse('playUrl[*].url')!;
      final value = path.read(const {
        'playUrl': {
          'mid1': {'url': 'http://a/1.mp3'},
          'mid2': {'url': 'http://a/2.mp3'},
        },
      });

      expect(value, ['http://a/1.mp3', 'http://a/2.mp3']);
    });

    test('Map 投影只有一个键时**仍是数组**（"投影 = 列表字段"这条不变）', () {
      final path = JsonPath.tryParse('playUrl[*].url')!;
      final value = path.read(const {
        'playUrl': {
          'mid1': {'url': 'http://a/1.mp3'},
        },
      });

      expect(value, isA<List<Object?>>());
      expect(value, ['http://a/1.mp3']);
    });
  });

  group('映射器：投影结果的取值规则（用搜索形状，避开身份护栏的干扰）', () {
    OnlineMusicResponseSpec searchSpec() => OnlineMusicResponseSpec(
      success: const OnlineMusicSuccessSpec(),
      listPath: JsonPath.tryParse('data.items'),
      fields: {
        OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
          candidates: [JsonPath.tryParse('id')!],
          transform: OnlineMusicFieldTransform.asString,
          required: true,
        ),
        // 标量字段 + **投影路径**：单键 Map 应解包成该值。
        OnlineMusicDomainField.title: OnlineMusicFieldSpec(
          candidates: [JsonPath.tryParse('names[*].value')!],
          transform: OnlineMusicFieldTransform.asString,
          required: true,
        ),
        // 列表字段 + 投影：**绝不解包**。
        OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
          candidates: [JsonPath.tryParse('singers[*].name')!],
          transform: OnlineMusicFieldTransform.asStringList,
          required: true,
        ),
      },
    );

    Map<String, Object?> bodyWith({
      required Map<String, Object?> names,
      required List<Object?> singers,
    }) => {
      'data': {
        'items': [
          {'id': 'x1', 'names': names, 'singers': singers},
        ],
      },
    };

    MusicSearchPage mapWith(Map<String, Object?> body) =>
        mapDeclarativeSearchResponse(
          spec: searchSpec(),
          body: body,
          platform: MusicPlatform.qq,
          limit: 1,
          offset: 0,
        );

    test('★ 单键 Map + 标量字段 ⇒ 解包成该值', () {
      final page = mapWith(
        bodyWith(
          names: {
            'anything': {'value': '标题'},
          },
          singers: [
            {'name': '只有一位'},
          ],
        ),
      );

      expect(page.items.single.title, '标题');
    });

    test('★ 多键 Map + 标量字段 ⇒ **不解包**，fail-closed 报缺少必填字段', () {
      expect(
        () => mapWith(
          bodyWith(
            names: {
              'k1': {'value': 'A'},
              'k2': {'value': 'B'},
            },
            singers: [
              {'name': 'S'},
            ],
          ),
        ),
        throwsA(
          isA<DeclarativeMappingException>().having(
            (e) => e.reason,
            'reason',
            contains('title'),
          ),
        ),
      );
    });

    test('★ 列表字段**绝不被解包**：单元素投影仍是 [x]', () {
      final page = mapWith(
        bodyWith(
          names: {
            'k': {'value': 'T'},
          },
          singers: [
            {'name': '只有一位'},
          ],
        ),
      );

      expect(page.items.single.artists, ['只有一位']);
    });
  });

  group('QQ 播放解析的真实形状（现状记录）', () {
    const ref = PlatformTrackRef(platform: MusicPlatform.qq, trackId: 'mid1');
    // 与准备写入配置的绑定一致：`trackId` **非必填**（接口不回显），靠身份护栏兜底。
    // ⚠️ 路径必须**从根写全**：JsonPath 的 `[*]` 只能作**后缀**段（段首方括号只接受引号键），
    // 所以不能写成 `fieldsRootPath: data.playUrl` + `[*].url`。
    final spec = OnlineMusicResponseSpec(
      success: const OnlineMusicSuccessSpec(),
      fields: {
        OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
          candidates: [JsonPath.tryParse('data.playUrl[*].songmid')!],
          transform: OnlineMusicFieldTransform.asString,
        ),
        OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
          candidates: [JsonPath.tryParse('data.playUrl[*].url')!],
          transform: OnlineMusicFieldTransform.asUri,
          required: true,
        ),
      },
    );

    test('★ 单键 + 有 songmid ⇒ 能取出 url（形状本身可通过）', () {
      final stream = mapDeclarativeResolveResponse(
        spec: spec,
        body: const {
          'data': {
            'playUrl': {
              'mid1': {
                'songmid': 'mid1',
                'url': 'http://ws.stream.qqmusic.qq.com/a.mp3',
              },
            },
          },
        },
        expectedRef: ref,
        requestedQuality: '128',
        resolvedAt: DateTime.utc(2026),
      );

      expect(stream.uri.toString(), contains('ws.stream.qqmusic.qq.com'));
    });

    test('★ 真实响应**不含 songmid** ⇒ 身份护栏明确拦下（不静默采信请求身份）', () {
      expect(
        () => mapDeclarativeResolveResponse(
          spec: spec,
          body: const {
            'data': {
              'playUrl': {
                'mid1': {'url': 'http://a/1.mp3', 'error': ''},
              },
            },
          },
          expectedRef: ref,
          requestedQuality: '128',
          resolvedAt: DateTime.utc(2026),
        ),
        throwsA(
          isA<DeclarativeMappingException>().having(
            (e) => e.reason,
            'reason',
            contains('无法证明'),
          ),
        ),
      );
    });
  });
}
