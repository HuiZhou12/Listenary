import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_binding_diff.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// **F3-5a 验收**：探测初稿是**建议** —— 应用前必须能说清"改了什么"。
///
/// 为什么要有 diff：旧行为是探测成功后**静默覆盖**用户正在编辑的内容
///（P-20 的教训：破坏性操作必须可见、可拒绝）。这里把"说得清"这条钉死。
void main() {
  OnlineMusicDeclarativeCapabilityBinding bindingOf({
    String path = '/search',
    List<OnlineMusicParamBinding> query = const [],
    List<OnlineMusicHeaderSpec> headers = const [],
    OnlineMusicAuthPlacement auth = const OnlineMusicNoAuthPlacement(),
    String? listPath = 'data.songs',
    Map<OnlineMusicDomainField, OnlineMusicFieldSpec> fields = const {},
  }) => OnlineMusicDeclarativeCapabilityBinding(
    request: OnlineMusicRequestSpec(
      path: path,
      query: query,
      headers: headers,
      auth: auth,
    ),
    response: OnlineMusicResponseSpec(
      listPath: listPath == null ? null : JsonPath.tryParse(listPath),
      fields: fields,
    ),
  );

  List<String> diffOf(
    OnlineMusicDeclarativeCapabilityBinding a,
    OnlineMusicDeclarativeCapabilityBinding b,
  ) => describeDeclarativeBindingDiff(current: a, next: b);

  test('完全相同 ⇒ 空列表（界面据此说"没有差异"）', () {
    expect(diffOf(bindingOf(), bindingOf()), isEmpty);
  });

  test('请求路径变化 ⇒ 说出前后值', () {
    final lines = diffOf(bindingOf(), bindingOf(path: '/api/163_search'));

    expect(lines, hasLength(1));
    expect(lines.single, contains('请求路径'));
    expect(lines.single, contains('/search'));
    expect(lines.single, contains('/api/163_search'));
  });

  test('查询参数变化 ⇒ 按名字列出', () {
    final lines = diffOf(
      bindingOf(),
      bindingOf(
        query: const [
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
          ),
        ],
      ),
    );

    expect(lines.single, contains('查询参数'));
    expect(lines.single, contains('keywords'));
  });

  test('★ 敏感标记变化单独说明（它决定要不要走安全凭据引用）', () {
    final lines = diffOf(
      bindingOf(
        headers: const [OnlineMusicHeaderSpec(name: 'Cookie', value: '')],
      ),
      bindingOf(
        headers: const [
          OnlineMusicHeaderSpec(name: 'Cookie', value: '', sensitive: true),
        ],
      ),
    );

    expect(lines.join('|'), contains('标记为敏感的请求头'));
    expect(lines.join('|'), contains('Cookie'));
  });

  test('响应侧：列表路径与字段映射的新增/移除/修改都能说清', () {
    final lines = diffOf(
      bindingOf(),
      bindingOf(
        listPath: 'data.result',
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [JsonPath.tryParse('id')!],
            transform: OnlineMusicFieldTransform.asInt,
          ),
        },
      ),
    );

    final text = lines.join('\n');
    expect(text, contains('列表路径'));
    expect(text, contains('新增字段映射'));
    expect(text, contains('trackId'));
  });

  test('认证放置变化 ⇒ 说出前后形态', () {
    final lines = diffOf(
      bindingOf(),
      bindingOf(
        auth: const OnlineMusicQueryAuthPlacement(parameterName: 'apikey'),
      ),
    );

    expect(lines.single, contains('认证放置'));
    expect(lines.single, contains('apikey'));
  });

  test('★ 差异落在未覆盖的字段里 ⇒ 如实提示用 JSON 视图对比（不给空列表）', () {
    // 分页的"默认每页数量"变化（kind 不变）⇒ 当前 diff 不逐项比较它，
    // 于是走到兜底分支；此时**必须**提示，而不能让用户以为"没有差异"。
    final withDefaultLimit = OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/search'),
      response: OnlineMusicResponseSpec(
        listPath: JsonPath.tryParse('data.songs'),
        pagination: const OnlineMusicPaginationSpec(defaultLimit: 50),
      ),
    );

    final lines = diffOf(bindingOf(), withDefaultLimit);

    expect(lines, isNotEmpty, reason: '不得给空列表掩盖差异');
    expect(lines.single, contains('JSON 视图'));
  });
}
