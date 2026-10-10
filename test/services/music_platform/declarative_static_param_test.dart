import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// F4-S1（P-08 / D1:A）：模型支持**静态常量参数**——
/// 取值要么来自闭集输入来源，要么写死成常量，两者**互斥**且**不静默取其一**。
void main() {
  group('★ F4-S1 静态常量参数（来源封闭 + 允许静态常量）', () {
    test('只给固定值：toJson 只写 value（不写 source），往返不变', () {
      const binding = OnlineMusicParamBinding(name: 'limit', value: '30');

      final json = binding.toJson();

      expect(json['value'], '30');
      expect(
        json.containsKey('source'),
        isFalse,
        reason: '两者互斥：固定值模式不得再写来源',
      );
      expect(OnlineMusicParamBinding.fromJson(json), binding);
      expect(binding.toString(), contains('固定值'));
    });

    test('只给来源：仍按老样子写 source（旧配置字节不变）', () {
      const binding = OnlineMusicParamBinding(
        name: 'keywords',
        source: OnlineMusicInputSource.keyword,
        required: true,
      );

      final json = binding.toJson();

      expect(json['source'], 'keyword');
      expect(json.containsKey('value'), isFalse);
      expect(OnlineMusicParamBinding.fromJson(json), binding);
    });

    test('老配置（只有 source）解析结果与逐字节写回都不变', () {
      final json = <String, dynamic>{
        'name': 'keywords',
        'source': 'keyword',
        'required': true,
      };

      final parsed = OnlineMusicParamBinding.fromJson(json);

      expect(parsed.source, OnlineMusicInputSource.keyword);
      expect(parsed.value, isNull);
      expect(parsed.toJson(), json, reason: '没有新增字段时不得改变落盘形状');
    });

    test('校验：来源与固定值**同给** ⇒ 明确报错（不静默取其一）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
            value: '30',
          ),
        ],
      );

      final issues = spec.validationIssues();

      expect(
        issues.any((issue) => issue.contains('只能留一个')),
        isTrue,
        reason: issues.join('；'),
      );
    });

    test('校验：两者**都不给** ⇒ 明确报错', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        query: [OnlineMusicParamBinding(name: 'limit')],
      );

      expect(
        spec.validationIssues().any(
          (issue) => issue.contains('既没有取值来源也没有固定值'),
        ),
        isTrue,
      );
    });

    test('校验：请求体字段同样受"恰好一种取值"约束', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        verb: OnlineMusicHttpVerb.post,
        body: OnlineMusicRequestBodySpec(
          fields: [
            OnlineMusicParamBinding(
              name: 'type',
              source: OnlineMusicInputSource.keyword,
              value: '1',
            ),
          ],
        ),
      );

      expect(
        spec.validationIssues().any(
          (issue) =>
              issue.contains('请求体字段') && issue.contains('只能留一个'),
        ),
        isTrue,
      );
    });

    test('构造请求：固定值真的写进 query 与 body', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        verb: OnlineMusicHttpVerb.post,
        query: [
          OnlineMusicParamBinding(name: 'limit', value: '30'),
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
            required: true,
          ),
        ],
        body: OnlineMusicRequestBodySpec(
          fields: [OnlineMusicParamBinding(name: 'type', value: '1')],
        ),
      );

      final request = buildDeclarativeRequest(
        spec: spec,
        inputs: const DeclarativeInputs(keyword: '海阔天空'),
      );

      expect(request.query['limit'], '30', reason: '常量必须原样进 query');
      expect(request.query['keywords'], '海阔天空');
      expect(
        (request.body! as Map<String, Object?>)['type'],
        '1',
        reason: '常量必须原样进 body',
      );
    });

    test('构造请求：两者同给 ⇒ invalidParameterBinding（运行期兜底也不静默）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
            value: '30',
          ),
        ],
      );

      expect(
        () => buildDeclarativeRequest(
          spec: spec,
          inputs: const DeclarativeInputs(limit: 5),
        ),
        throwsA(
          isA<DeclarativeRequestException>().having(
            (error) => error.kind,
            'kind',
            DeclarativeRequestErrorKind.invalidParameterBinding,
          ),
        ),
        reason: '不得静默取"来源"或"常量"任意一个',
      );
    });

    test('构造请求：两者都不给 ⇒ 也明确失败（不得悄悄少发一个参数）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        query: [OnlineMusicParamBinding(name: 'limit')],
      );

      expect(
        () => buildDeclarativeRequest(
          spec: spec,
          inputs: const DeclarativeInputs(limit: 5),
        ),
        throwsA(
          isA<DeclarativeRequestException>().having(
            (error) => error.kind,
            'kind',
            DeclarativeRequestErrorKind.invalidParameterBinding,
          ),
        ),
      );
    });

    test('有常量时 required / 默认值都不参与（常量优先）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'limit',
            value: '30',
            required: true,
            defaultValue: 7,
          ),
        ],
      );

      final request = buildDeclarativeRequest(
        spec: spec,
        inputs: const DeclarativeInputs(),
      );

      expect(
        request.query['limit'],
        '30',
        reason: '常量优先；也不会因为没有输入而报"缺少必填输入"',
      );
    });
  });
}
