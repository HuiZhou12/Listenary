import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';

JsonPath _p(String source) => JsonPath.tryParse(source)!;

/// search 绑定：只映射必填的 trackId + title，便于单独构造"转换错/字段缺"两种情形。
OnlineMusicResponseSpec _searchSpec({
  OnlineMusicFieldTransform trackIdTransform = OnlineMusicFieldTransform.asInt,
  List<String> trackIdPaths = const ['id'],
  String titlePath = 'name',
}) => OnlineMusicResponseSpec(
  listPath: _p('data'),
  fields: {
    OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
      candidates: [for (final path in trackIdPaths) _p(path)],
      transform: trackIdTransform,
      required: true,
    ),
    OnlineMusicDomainField.title: OnlineMusicFieldSpec(
      candidates: [_p(titlePath)],
      transform: OnlineMusicFieldTransform.asString,
      required: true,
    ),
  },
);

MusicSearchPage _map(OnlineMusicResponseSpec spec, Object? body) =>
    mapDeclarativeSearchResponse(
      spec: spec,
      body: body,
      platform: MusicPlatform.netease,
      limit: 10,
      offset: 0,
    );

void main() {
  // ======================================================== P-31
  group('★ P-31 类型不匹配与"字段缺失"给出不同结论', () {
    test('路径命中了值但转换解析不出来 ⇒ 报"转换选错"，不是"缺少必填字段"', () {
      // id 是字符串 'abc'，配置却要求 asInt ⇒ 旧实现报「缺少必填字段 trackId」，
      // 用户会去补字段，而字段其实**就在那儿**。
      late final DeclarativeMappingException error;
      try {
        _map(
          _searchSpec(),
          const {
            'data': [
              {'id': 'abc', 'name': 'T'},
            ],
          },
        );
        fail('应当抛出映射异常');
      } on DeclarativeMappingException catch (caught) {
        error = caught;
      }

      expect(error.reason, contains('trackId'));
      expect(error.reason, contains('asInt'));
      expect(error.reason, contains('字符串'));
      expect(
        error.reason,
        isNot(contains('缺少必填字段')),
        reason: '取到值却解析不出来，不是"缺少字段"',
      );
      expect(
        error.reason,
        isNot(contains('abc')),
        reason: '错误文案会进界面 ⇒ 不得带出响应内容（只给类型）',
      );
    });

    test('路径确实没有值 ⇒ 仍然报"缺少必填字段"（旧结论保留）', () {
      late final DeclarativeMappingException error;
      try {
        _map(
          _searchSpec(),
          const {
            'data': [
              {'name': 'T'},
            ],
          },
        );
        fail('应当抛出映射异常');
      } on DeclarativeMappingException catch (caught) {
        error = caught;
      }
      expect(error.reason, '缺少必填字段 trackId');
    });

    test('候选路径之间仍然按序回退（一个转换失败不影响后面的候选）', () {
      // 第一个候选命中但转换失败，第二个候选可用 ⇒ 必须取第二个的值。
      final page = _map(
        _searchSpec(trackIdPaths: const ['badId', 'id']),
        const {
          'data': [
            {'badId': 'not-a-number', 'id': 42, 'name': 'T'},
          ],
        },
      );
      expect(page.items.single.ref.trackId, '42');
    });

    test('多个候选都失败时，文案指向**第一个**失败点（便于定位）', () {
      late final DeclarativeMappingException error;
      try {
        _map(
          _searchSpec(trackIdPaths: const ['badId', 'worseId']),
          const {
            'data': [
              {'badId': 'x', 'worseId': 'y', 'name': 'T'},
            ],
          },
        );
        fail('应当抛出映射异常');
      } on DeclarativeMappingException catch (caught) {
        error = caught;
      }
      expect(error.reason, contains('badId'));
      expect(error.reason, isNot(contains('worseId')));
    });

    test('布尔/数组/对象位置也给出各自的类型名（只给类型，不给值）', () {
      final cases = <(Object, String)>[
        (true, '布尔值'),
        (<Object?>[1, 2], '数组'),
        (<String, Object?>{'a': 1}, '对象'),
      ];
      for (final (value, typeName) in cases) {
        late final DeclarativeMappingException error;
        try {
          _map(
            _searchSpec(),
            {
              'data': [
                {'id': value, 'name': 'T'},
              ],
            },
          );
          fail('应当抛出映射异常');
        } on DeclarativeMappingException catch (caught) {
          error = caught;
        }
        expect(error.reason, contains(typeName), reason: '$value 的类型名应为 $typeName');
      }
    });
  });

  // ======================================================== P-42
  group('★ P-42 播放解析必须能证明身份（否则直接失败）', () {
    const requested = PlatformTrackRef(
      platform: MusicPlatform.netease,
      trackId: '123456',
    );

    OnlineMusicResponseSpec resolveSpec({
      bool withTrackId = true,
      OnlineMusicFieldTransform trackIdTransform = OnlineMusicFieldTransform.asString,
      String trackIdPath = 'id',
    }) => OnlineMusicResponseSpec(
      fieldsRootPath: _p('data'),
      fields: {
        OnlineMusicDomainField.streamUrl: OnlineMusicFieldSpec(
          candidates: [_p('url')],
          transform: OnlineMusicFieldTransform.asUri,
          required: true,
        ),
        if (withTrackId)
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p(trackIdPath)],
            transform: trackIdTransform,
          ),
      },
    );

    DeclarativeMappingException resolveError(
      OnlineMusicResponseSpec spec,
      Object? body,
    ) {
      try {
        mapDeclarativeResolveResponse(
          spec: spec,
          body: body,
          expectedRef: requested,
          requestedQuality: 'lossless',
          resolvedAt: DateTime.utc(2026, 1, 1),
        );
      } on DeclarativeMappingException catch (caught) {
        return caught;
      }
      fail('应当抛出映射异常');
    }

    test('没有配置 trackId 映射 ⇒ 明确失败（不再静默回填请求身份）', () {
      final error = resolveError(
        resolveSpec(withTrackId: false),
        const {
          'data': {'url': 'https://media.invalid/a.flac'},
        },
      );

      expect(error.reason, contains('无法证明'));
      expect(error.reason, contains('曲目 ID'));
    });

    test('配了 trackId 但读不到 ⇒ 说明是"路径/转换"问题', () {
      final error = resolveError(
        resolveSpec(trackIdTransform: OnlineMusicFieldTransform.asInt),
        const {
          'data': {'id': 'not-a-number', 'url': 'https://media.invalid/a.flac'},
        },
      );

      expect(error.reason, contains('无法证明'));
      expect(error.reason, contains('asInt'));
      expect(error.reason, contains('字符串'));
    });

    test('返回的不是同一首 ⇒ 文案同时给出两个 id', () {
      final error = resolveError(
        resolveSpec(),
        const {
          'data': {'id': '999999', 'url': 'https://media.invalid/a.flac'},
        },
      );

      expect(error.reason, contains('不是同一首'));
      expect(error.reason, contains('123456'));
      expect(error.reason, contains('999999'));
    });

    test('身份一致 ⇒ 正常返回，且 ref 是**请求方**的（不由 Provider 回填）', () {
      final stream = mapDeclarativeResolveResponse(
        spec: resolveSpec(),
        body: const {
          'data': {'id': '123456', 'url': 'https://media.invalid/a.flac'},
        },
        expectedRef: requested,
        requestedQuality: 'lossless',
        resolvedAt: DateTime.utc(2026, 1, 1),
      );

      expect(stream.ref, requested);
      expect(stream.uri, Uri.parse('https://media.invalid/a.flac'));
    });
  });
}
