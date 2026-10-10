import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/declarative/provider_templates.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

/// **内置 Provider 模板**的字段路径守卫。
///
/// 为什么单独测：模板是用户"从模板开始配"的起点，而模板里的字段路径
/// （`result.songs[*].artists[*].name` 这类）**一旦写错不会报错** ——
/// 只会让每个搜索结果**丢掉艺人**（或丢掉专辑/时长），页面照样出内容。
/// 查过一遍：模板虽然在测试里被引用过，但都只是拿它跑**错误路由/序列化**，
/// **没有任何测试用真实响应形状验证过它的字段路径**。
///
/// 下面的样本是 `GET http://127.0.0.1:3000/search?keywords=海阔天空&limit=2`
/// 的**实际响应**（2026-10-08 实测）的忠实节选：`result.songs[*]` 里
/// `artists` 是**对象数组**（不是字符串数组）、`album` 是**对象**、`duration` 是**毫秒**。
void main() {
  const realSearchSample = <String, Object?>{
    'code': 200,
    'result': {
      'songs': [
        {
          'id': 1357375695,
          'name': '海阔天空',
          'duration': 239560,
          'artists': [
            {'id': 11127, 'name': 'Beyond', 'alias': <Object?>[]},
          ],
          'album': {'id': 1, 'name': '华纳廿三周年纪念精选系列 - Beyond'},
        },
      ],
      'hasMore': true,
      'songCount': 306,
    },
  };

  group('内置模板的字段路径（对真实响应形状）', () {
    test('★ msapi 搜索模板：从 result.songs[*] 正确取出身份/标题/艺人/专辑/时长', () {
      final tracks = mapDeclarativeSearchResponse(
        spec: msapiSearchTemplate.response,
        body: realSearchSample,
        platform: MusicPlatform.netease,
        limit: 30,
        offset: 0,
      ).items;

      expect(tracks, hasLength(1));
      final track = tracks.single;
      // 身份
      expect(track.ref.trackId, '1357375695');
      expect(track.ref.platform, MusicPlatform.netease);
      // 标题
      expect(track.title, '海阔天空');
      // **艺人**：这一条是最容易静默坏掉的 —— `artists` 是对象数组，
      // 路径写成 `artists` 或 `artists[*]` 都会**悄悄**得到一个空艺人。
      expect(track.artistDisplay, 'Beyond');
      expect(track.artists, ['Beyond']);
      // 专辑
      expect(track.album, '华纳廿三周年纪念精选系列 - Beyond');
      // 时长：模板用 asDurationMs，而该接口给的确实是毫秒。
      expect(track.duration, const Duration(milliseconds: 239560));
    });

    test('★ 模板的请求路径与分页语义没被改坏', () {
      expect(msapiSearchTemplate.request.path, '/search');
      // 搜索是 limit/offset 分页（应用要用它做"加载更多"）。
      expect(
        msapiSearchTemplate.response.pagination.kind,
        OnlineMusicPaginationKind.offsetLimit,
      );
      // 必填字段：能确定"是哪首歌、叫什么"。
      final required = msapiSearchTemplate.response.fields.entries
          .where((entry) => entry.value.required)
          .map((entry) => entry.key)
          .toSet();
      expect(required, {
        OnlineMusicDomainField.trackId,
        OnlineMusicDomainField.title,
      });
    });

    test('内置模板都不是空壳：有 id / 标签 / 搜索绑定，且带好字段映射', () {
      final templates = onlineMusicProviderTemplates();
      expect(templates, isNotEmpty);

      final ids = <String>{};
      for (final template in templates) {
        expect(ids.add(template.id), isTrue, reason: '模板 id 不能重复');
        expect(template.label.trim(), isNotEmpty);

        final fields = template.search.response.fields;
        expect(fields, contains(OnlineMusicDomainField.trackId));
        expect(fields, contains(OnlineMusicDomainField.title));
      }
    });
  });
}
