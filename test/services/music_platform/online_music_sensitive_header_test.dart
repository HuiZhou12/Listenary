import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// F0 切片 1：**敏感请求头的模型与"保存时拒绝"**（决策 A，用户 2026-10-09 裁定）。
///
/// 覆盖三件事：
/// 1. 新增的可选 `sensitive` 字段**不影响旧配置**（缺省 false，且 false 时不写盘）；
/// 2. 明确标记为敏感的请求头**不得**以明文值保存（保存时拒绝）；
/// 3. 运行期不得以明文发送（本文件只验校验层；发送层在后续切片）。
void main() {
  OnlineMusicRequestSpec specWithHeader(OnlineMusicHeaderSpec header) =>
      OnlineMusicRequestSpec(path: '/api/x', headers: [header]);

  List<String> issuesOf(OnlineMusicRequestSpec spec) => spec.validationIssues();

  group('sensitive 字段与旧配置兼容', () {
    test('旧配置（无 sensitive 键）读入后为 false，且写回时不新增该键', () {
      const legacy = OnlineMusicHeadersLegacySample.map;

      final parsed = OnlineMusicHeaderSpec.fromJson(legacy);
      expect(parsed.sensitive, isFalse);
      expect(
        parsed.toJson().containsKey('sensitive'),
        isFalse,
        reason: 'false 时不写盘 —— 旧配置往返后字节语义不变',
      );
      expect(parsed.toJson(), legacy);
    });

    test('显式标记敏感会被保留（往返不丢）', () {
      const header = OnlineMusicHeaderSpec(
        name: 'Cookie',
        value: '',
        sensitive: true,
      );

      final json = header.toJson();
      expect(json['sensitive'], isTrue);
      expect(OnlineMusicHeaderSpec.fromJson(json), header);
    });

    test('相等性把 sensitive 计入（避免"标记后被当成同一份配置"）', () {
      const plain = OnlineMusicHeaderSpec(name: 'X-Token', value: '');
      const marked = OnlineMusicHeaderSpec(
        name: 'X-Token',
        value: '',
        sensitive: true,
      );

      expect(plain == marked, isFalse);
      expect(plain.hashCode == marked.hashCode, isFalse);
    });
  });

  group('保存时拒绝：敏感头不得用明文值', () {
    test('★ sensitive + 明文 ⇒ 校验报错（保存会被拦下）', () {
      final issues = issuesOf(
        specWithHeader(
          const OnlineMusicHeaderSpec(
            name: 'Cookie',
            value: 'session=abc',
            sensitive: true,
          ),
        ),
      );

      expect(issues, hasLength(1));
      expect(issues.single, contains('已标记为敏感'));
      expect(
        issues.single,
        contains('Cookie'),
        reason: '报错必须指出是哪个请求头，否则用户无从下手',
      );
    });

    test('sensitive + 空值 ⇒ 允许（"待填凭据"的中间态不能被拦）', () {
      final issues = issuesOf(
        specWithHeader(
          const OnlineMusicHeaderSpec(
            name: 'Cookie',
            value: '',
            sensitive: true,
          ),
        ),
      );

      expect(issues, isEmpty);
    });

    test('未标记敏感 + 明文 ⇒ 与旧行为一致（不报错）', () {
      final issues = issuesOf(
        specWithHeader(
          const OnlineMusicHeaderSpec(name: 'Referer', value: 'https://a.b/'),
        ),
      );

      expect(issues, isEmpty);
    });
  });

  group('端到端：带敏感头的配置整体校验', () {
    test('声明式绑定校验会带出该错误（保存路径确实会拦）', () {
      final binding = OnlineMusicDeclarativeCapabilityBinding(
        request: specWithHeader(
          const OnlineMusicHeaderSpec(
            name: 'Authorization',
            value: 'Bearer abc',
            sensitive: true,
          ),
        ),
        response: OnlineMusicResponseSpec(
          listPath: JsonPath.tryParse('data.items'),
        ),
      );

      final issues = binding.validationIssues(OnlineMusicCapability.search);

      expect(issues.any((issue) => issue.contains('已标记为敏感')), isTrue);
    });
  });
}

class OnlineMusicHeadersLegacySample {
  /// 旧版本写出来的形态：**只有 name 与 value**。
  static const Map<String, dynamic> map = {
    'name': 'Referer',
    'value': 'https://example.com/',
  };
}
