import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_errors.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_request_builder.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';

/// F4-S2（P-09 / D3 边界）：请求头的值可以来自**闭集输入**（动态头），
/// 但**敏感头绝不允许** —— 那等于把凭据放进普通输入通道 ⇒ 校验与构造期都明确拒绝。
void main() {
  group('★ F4-S2 动态请求头（P-09）', () {
    test('动态头：toJson 带上 source（value 仍按既有形状写出）', () {
      const header = OnlineMusicHeaderSpec(
        name: 'X-Keyword',
        value: '',
        source: OnlineMusicInputSource.keyword,
      );

      final json = header.toJson();

      expect(json['source'], 'keyword');
      expect(json['value'], '');
      expect(OnlineMusicHeaderSpec.fromJson(json), header);
    });

    test('旧配置（只有 name/value）解析与写回都不变', () {
      final json = <String, dynamic>{'name': 'X-Client', 'value': 'pure-music'};

      final parsed = OnlineMusicHeaderSpec.fromJson(json);

      expect(parsed.source, isNull);
      expect(parsed.toJson(), json, reason: '没有动态头时不得改变落盘形状');
    });

    test('校验：**敏感头不得来自输入**（硬约束）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'Cookie',
            value: '',
            source: OnlineMusicInputSource.keyword,
            sensitive: true,
            credentialReference: 'p/c/cookie',
          ),
        ],
      );

      final issues = spec.validationIssues();

      expect(
        issues.any((issue) => issue.contains('不能来自输入')),
        isTrue,
        reason: issues.join('；'),
      );
    });

    test('校验：动态头与凭据引用 / 固定值都互斥', () {
      const withReference = OnlineMusicRequestSpec(
        path: '/search',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'X-A',
            value: '',
            source: OnlineMusicInputSource.keyword,
            credentialReference: 'p/c/x-a',
          ),
        ],
      );
      const withValue = OnlineMusicRequestSpec(
        path: '/search',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'X-B',
            value: 'fixed',
            source: OnlineMusicInputSource.keyword,
          ),
        ],
      );

      expect(
        withReference.validationIssues().any(
          (issue) => issue.contains('不能再来自输入'),
        ),
        isTrue,
      );
      expect(
        withValue.validationIssues().any(
          (issue) => issue.contains('同时有固定值'),
        ),
        isTrue,
      );
    });

    test('构造请求：动态头的值来自输入；输入缺失则**不发送**该头', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'X-Keyword',
            value: '',
            source: OnlineMusicInputSource.keyword,
          ),
          OnlineMusicHeaderSpec(
            name: 'X-Quality',
            value: '',
            source: OnlineMusicInputSource.quality,
          ),
        ],
      );

      // ⚠️ F4-S8 起：**非 ASCII 头值**在构造期就明确报错（不再留给传输层）。
      // 本用例验的是"值来自输入 / 缺失则不发送" ⇒ 改用 ASCII 值。
      final request = buildDeclarativeRequest(
        spec: spec,
        inputs: const DeclarativeInputs(keyword: 'sea-sky'),
      );

      expect(request.headers['X-Keyword'], 'sea-sky');
      expect(
        request.headers.containsKey('X-Quality'),
        isFalse,
        reason: '输入缺失时该头本次不发送（与参数"值为空就省略"同一口径）',
      );
    });

    test('构造请求：敏感头即便配了 source 也**明确失败**（兜底，不静默）', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'Cookie',
            value: '',
            source: OnlineMusicInputSource.keyword,
            sensitive: true,
          ),
        ],
      );

      expect(
        () => buildDeclarativeRequest(
          spec: spec,
          inputs: const DeclarativeInputs(keyword: 'x'),
        ),
        throwsA(
          isA<DeclarativeRequestException>()
              .having(
                (error) => error.kind,
                'kind',
                DeclarativeRequestErrorKind.invalidParameterBinding,
              )
              .having(
                (error) => error.safeMessage,
                'message',
                contains('敏感值只能走安全凭据引用'),
              ),
        ),
      );
    });

    test('F0 边界未削弱：敏感头 + 明文值仍然在保存校验被拒', () {
      const spec = OnlineMusicRequestSpec(
        path: '/search',
        headers: [
          OnlineMusicHeaderSpec(
            name: 'Authorization',
            value: 'Bearer plaintext',
            sensitive: true,
          ),
        ],
      );

      expect(
        spec.validationIssues().any(
          (issue) => issue.contains('不能以明文值保存'),
        ),
        isTrue,
      );
    });
  });
}
