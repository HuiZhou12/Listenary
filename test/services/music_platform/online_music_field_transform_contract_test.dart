import 'package:flutter_test/flutter_test.dart';
// 服务层的统一导出口：JsonPath / 绑定 / 能力 / 请求响应 spec / 领域模型都在其中。
import 'package:pure_music/services/music_platform/chksz/index.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';

JsonPath _p(String source) => JsonPath.tryParse(source)!;

OnlineMusicFieldSpec _field(
  OnlineMusicFieldTransform transform, {
  String path = 'value',
  bool required = false,
}) => OnlineMusicFieldSpec(
  candidates: [_p(path)],
  transform: transform,
  required: required,
);

void main() {
  // ======================================================== 契约本体（P-30）
  group('★ P-30 校验表由「映射读取器」派生', () {
    test('覆盖全部领域字段，且每个字段都有非空的可选转换', () {
      for (final field in OnlineMusicDomainField.values) {
        expect(
          expectedFieldKinds[field],
          isNotNull,
          reason: '${field.name} 必须出现在表里（以前"未列出 ⇒ 不限制"是缺陷通道）',
        );
        expect(expectedFieldKinds[field], isNotEmpty);
      }
      expect(
        expectedFieldKinds.length,
        OnlineMusicDomainField.values.length,
        reason: '表必须**完整**——缺一个就等于放行它的全部 9 种转换',
      );
    });

    test('每个字段的读取器类别是**明确声明**的（测试侧独立钉住）', () {
      // 这张表是"规格"：改 `fieldReaderOf` 必须同时改这里，改动因此不可能悄悄发生。
      const expectedReader = <OnlineMusicDomainField, OnlineMusicFieldReader>{
        OnlineMusicDomainField.trackId: OnlineMusicFieldReader.scalar,
        OnlineMusicDomainField.title: OnlineMusicFieldReader.scalar,
        OnlineMusicDomainField.artists: OnlineMusicFieldReader.textList,
        // 艺人 id 与"艺术家"同序（用于打开艺人页，2026-10-12）。
        OnlineMusicDomainField.artistIds: OnlineMusicFieldReader.textList,
        // 专辑 id（用于打开专辑页，2026-10-12）✓。
        OnlineMusicDomainField.albumIds: OnlineMusicFieldReader.textList,
        // album（专辑详情，2026-10-12）：名字/专辑艺人是文本、封面是 Uri、曲目数是整数。
        OnlineMusicDomainField.albumName: OnlineMusicFieldReader.text,
        // 专辑列表里的单个专辑 id（与 albumIds 不同：那是"曲目所属专辑"的同序列表 ✓）。
        OnlineMusicDomainField.albumId: OnlineMusicFieldReader.scalar,
        OnlineMusicDomainField.albumCoverUri: OnlineMusicFieldReader.uri,
        OnlineMusicDomainField.albumArtist: OnlineMusicFieldReader.text,
        // 专辑艺人 id 与其它 id 同类（scalar ✓）。
        OnlineMusicDomainField.albumArtistId: OnlineMusicFieldReader.scalar,
        OnlineMusicDomainField.albumTrackCount: OnlineMusicFieldReader.integer,
        // 发行时间是**毫秒**时间戳 ⇒ 专用语义读取器（2026-10-12）✓。
        OnlineMusicDomainField.albumReleaseTime:
            OnlineMusicFieldReader.epochMillis,
        OnlineMusicDomainField.album: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.coverUri: OnlineMusicFieldReader.uri,
        OnlineMusicDomainField.duration: OnlineMusicFieldReader.duration,
        OnlineMusicDomainField.playlistId: OnlineMusicFieldReader.scalar,
        OnlineMusicDomainField.playlistName: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.playlistCoverUri: OnlineMusicFieldReader.uri,
        OnlineMusicDomainField.playlistCreator: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.playlistTrackCount: OnlineMusicFieldReader.integer,
        OnlineMusicDomainField.playlistUpdateFrequency:
            OnlineMusicFieldReader.text,
        OnlineMusicDomainField.categoryId: OnlineMusicFieldReader.scalar,
        OnlineMusicDomainField.categoryName: OnlineMusicFieldReader.scalar,
        OnlineMusicDomainField.categoryCount: OnlineMusicFieldReader.integer,
        // artist（艺人详情，2026-10-12）：名字/简介是文本，头像是 Uri。
        OnlineMusicDomainField.artistName: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.artistAvatarUri: OnlineMusicFieldReader.uri,
        OnlineMusicDomainField.artistDescription: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.lyricOriginal: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.lyricTranslation: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.lyricRomanization: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.streamUrl: OnlineMusicFieldReader.uri,
        OnlineMusicDomainField.streamQuality: OnlineMusicFieldReader.text,
        OnlineMusicDomainField.streamBitrate: OnlineMusicFieldReader.integer,
        OnlineMusicDomainField.streamExpiresAt:
            OnlineMusicFieldReader.epochSeconds,
      };
      expect(expectedReader.keys.toSet(), OnlineMusicDomainField.values.toSet());
      for (final entry in expectedReader.entries) {
        expect(
          fieldReaderOf(entry.key),
          entry.value,
          reason: '${entry.key.name} 的读取器类别',
        );
      }
    });

    test('流地址**只允许原样解析**（有意的收紧，防 http 被改写成 https）', () {
      expect(expectedFieldKinds[OnlineMusicDomainField.streamUrl], {
        OnlineMusicFieldTransform.asUri,
      });
    });

    test('编辑器的默认转换是"读取器真能消费"的那一个（封面不再是 asString）', () {
      // 默认值 = 派生表的第一项；这条钉住"新建字段不会再默认成读不出来的转换"。
      for (final field in OnlineMusicDomainField.values) {
        final first = expectedFieldKinds[field]!.first;
        expect(
          expectedFieldKinds[field],
          contains(first),
          reason: '${field.name} 的默认转换必须在允许集合内',
        );
      }
      expect(
        expectedFieldKinds[OnlineMusicDomainField.playlistCoverUri]!.first,
        OnlineMusicFieldTransform.asUri,
        reason: '封面读取器只认 Uri ⇒ 默认必须是 asUri（以前默认 asString ⇒ 封面恒 null）',
      );
      expect(
        expectedFieldKinds[OnlineMusicDomainField.categoryCount]!.first,
        OnlineMusicFieldTransform.asInt,
        reason: '数量的读取器只认 int',
      );
    });

    test('此前放行、必然静默 null 的组合现在都被拦下', () {
      const rejected = <OnlineMusicDomainField, List<OnlineMusicFieldTransform>>{
        // 读取器是 `_readIntField`，却允许 asString
        OnlineMusicDomainField.playlistTrackCount: [
          OnlineMusicFieldTransform.asString,
        ],
        OnlineMusicDomainField.categoryCount: [
          OnlineMusicFieldTransform.asString,
        ],
        OnlineMusicDomainField.streamExpiresAt: [
          OnlineMusicFieldTransform.asString,
        ],
        // 读取器只要 Uri/非空 String，以前**完全不在表里**（任何转换都放行）
        OnlineMusicDomainField.playlistCoverUri: [
          OnlineMusicFieldTransform.asString,
          OnlineMusicFieldTransform.asInt,
          OnlineMusicFieldTransform.asStringList,
        ],
        OnlineMusicDomainField.playlistCreator: [
          OnlineMusicFieldTransform.asUri,
          OnlineMusicFieldTransform.asInt,
        ],
        // 身份字段：`asStringList`/`asDurationMs` 会写出 '[a]' / '0:03:00' 这类垃圾 id
        OnlineMusicDomainField.categoryId: [
          OnlineMusicFieldTransform.asStringList,
          OnlineMusicFieldTransform.asDurationMs,
          OnlineMusicFieldTransform.asBool,
        ],
        OnlineMusicDomainField.lyricOriginal: [
          OnlineMusicFieldTransform.asInt,
          OnlineMusicFieldTransform.asUri,
        ],
      };
      rejected.forEach((field, transforms) {
        for (final transform in transforms) {
          expect(
            expectedFieldKinds[field],
            isNot(contains(transform)),
            reason: '${field.name} + ${transform.name} 不该放行',
          );
        }
      });
    });

    test('校验层真的会拒绝这些组合（不是只改了常量）', () {
      final binding = OnlineMusicDeclarativeCapabilityBinding(
        request: const OnlineMusicRequestSpec(path: '/x'),
        response: OnlineMusicResponseSpec(
          listPath: _p('data'),
          fields: {
            OnlineMusicDomainField.categoryId: _field(
              OnlineMusicFieldTransform.asSingleStringList,
              path: 'id',
              required: true,
            ),
            OnlineMusicDomainField.categoryName: _field(
              OnlineMusicFieldTransform.asString,
              path: 'name',
              required: true,
            ),
            OnlineMusicDomainField.categoryCount: _field(
              OnlineMusicFieldTransform.asString,
              path: 'count',
            ),
          },
        ),
      );
      final issues = binding.validationIssues(
        OnlineMusicCapability.playlistCategories,
      );
      expect(issues, isNotEmpty);
      expect(issues.join('\n'), contains('categoryId'));
      expect(issues.join('\n'), contains('categoryCount'));
    });
  });

  // ======================================================== 真映射证明
  group('★ P-30 放行的转换在映射层**真能读出来**（逐读取器类别）', () {
    test('uri：playlistCoverUri 用 asUri ⇒ 封面非空（以前恒 null）', () {
      final playlist = mapDeclarativePlaylistResponse(
        spec: OnlineMusicResponseSpec(
          fieldsRootPath: _p('playlist'),
          fields: {
            OnlineMusicDomainField.playlistName: _field(
              OnlineMusicFieldTransform.asString,
              path: 'name',
            ),
            OnlineMusicDomainField.playlistCoverUri: _field(
              OnlineMusicFieldTransform.asUri,
              path: 'coverImgUrl',
            ),
          },
        ),
        body: const {
          'playlist': {
            'name': 'P',
            'coverImgUrl': 'https://img.invalid/a.jpg',
          },
        },
        platform: MusicPlatform.netease,
        requestedPlaylistId: '1',
      );
      expect(playlist.coverUri, isNotNull);
    });

    test('text：playlistCreator 用 asString ⇒ 创建者非空', () {
      final playlist = mapDeclarativePlaylistResponse(
        spec: OnlineMusicResponseSpec(
          fieldsRootPath: _p('playlist'),
          fields: {
            OnlineMusicDomainField.playlistName: _field(
              OnlineMusicFieldTransform.asString,
              path: 'name',
            ),
            OnlineMusicDomainField.playlistCreator: _field(
              OnlineMusicFieldTransform.asString,
              path: 'creator',
            ),
          },
        ),
        body: const {
          'playlist': {'name': 'P', 'creator': '某人'},
        },
        platform: MusicPlatform.netease,
        requestedPlaylistId: '1',
      );
      expect(playlist.creator, '某人');
    });

    test('integer：categoryCount 用 asInt ⇒ 数量非空（asString 时恒 null）', () {
      final categories = mapDeclarativePlaylistCategoriesResponse(
        spec: OnlineMusicResponseSpec(
          listPath: _p('data'),
          fields: {
            OnlineMusicDomainField.categoryId: _field(
              OnlineMusicFieldTransform.asString,
              path: 'id',
              required: true,
            ),
            OnlineMusicDomainField.categoryName: _field(
              OnlineMusicFieldTransform.asString,
              path: 'name',
              required: true,
            ),
            OnlineMusicDomainField.categoryCount: _field(
              OnlineMusicFieldTransform.asInt,
              path: 'count',
            ),
          },
        ),
        body: const {
          'data': [
            {'id': 'a', 'name': 'N', 'count': 7},
          ],
        },
        platform: MusicPlatform.netease,
      );
      expect(categories.single.count, 7);
    });

    test('epochSeconds：streamExpiresAt 用 asInt ⇒ 过期时间非空（否则"永不过期"）', () {
      final stream = mapDeclarativeResolveResponse(
        spec: OnlineMusicResponseSpec(
          fieldsRootPath: _p('data'),
          fields: {
            OnlineMusicDomainField.streamUrl: _field(
              OnlineMusicFieldTransform.asUri,
              path: 'url',
            ),
            // P-42：播放解析必须能证明身份 ⇒ 夹具补上 trackId 映射（与请求的 id 一致）。
            OnlineMusicDomainField.trackId: _field(
              OnlineMusicFieldTransform.asString,
              path: 'id',
            ),
            OnlineMusicDomainField.streamExpiresAt: _field(
              OnlineMusicFieldTransform.asInt,
              path: 'exp',
            ),
          },
        ),
        body: const {
          'data': {
            'id': '1',
            'url': 'https://media.invalid/a.flac',
            'exp': 1765000000,
          },
        },
        expectedRef: const PlatformTrackRef(
          platform: MusicPlatform.netease,
          trackId: '1',
        ),
        requestedQuality: 'lossless',
        resolvedAt: DateTime.utc(2026, 1, 1),
      );
      expect(stream.expiresAt, isNotNull);
    });

    test('textList：artists 用 asStringList ⇒ 艺术家列表非空', () {
      final page = mapDeclarativeSearchResponse(
        spec: OnlineMusicResponseSpec(
          listPath: _p('data'),
          fields: {
            OnlineMusicDomainField.trackId: _field(
              OnlineMusicFieldTransform.asInt,
              path: 'id',
              required: true,
            ),
            OnlineMusicDomainField.title: _field(
              OnlineMusicFieldTransform.asString,
              path: 'name',
              required: true,
            ),
            OnlineMusicDomainField.artists: _field(
              OnlineMusicFieldTransform.asStringList,
              path: 'artists',
            ),
          },
        ),
        body: const {
          'data': [
            {
              'id': 1,
              'name': 'T',
              'artists': ['A', 'B'],
            },
          ],
        },
        platform: MusicPlatform.netease,
        limit: 10,
        offset: 0,
      );
      expect(page.items.single.artists, ['A', 'B']);
    });

    test('duration：duration 用 asDurationMs ⇒ 时长非零', () {
      final page = mapDeclarativeSearchResponse(
        spec: OnlineMusicResponseSpec(
          listPath: _p('data'),
          fields: {
            OnlineMusicDomainField.trackId: _field(
              OnlineMusicFieldTransform.asInt,
              path: 'id',
              required: true,
            ),
            OnlineMusicDomainField.title: _field(
              OnlineMusicFieldTransform.asString,
              path: 'name',
              required: true,
            ),
            OnlineMusicDomainField.duration: _field(
              OnlineMusicFieldTransform.asDurationMs,
              path: 'duration',
            ),
          },
        ),
        body: const {
          'data': [
            {'id': 1, 'name': 'T', 'duration': 233560},
          ],
        },
        platform: MusicPlatform.netease,
        limit: 10,
        offset: 0,
      );
      expect(page.items.single.duration, const Duration(milliseconds: 233560));
    });

    test('scalar：trackId 用 asInt 也能读出身份（会被插值成字符串）', () {
      final page = mapDeclarativeSearchResponse(
        spec: OnlineMusicResponseSpec(
          listPath: _p('data'),
          fields: {
            OnlineMusicDomainField.trackId: _field(
              OnlineMusicFieldTransform.asInt,
              path: 'id',
              required: true,
            ),
            OnlineMusicDomainField.title: _field(
              OnlineMusicFieldTransform.asString,
              path: 'name',
              required: true,
            ),
          },
        ),
        body: const {
          'data': [
            {'id': 42, 'name': 'T'},
          ],
        },
        platform: MusicPlatform.netease,
        limit: 10,
        offset: 0,
      );
      expect(page.items.single.ref.trackId, '42');
    });
  });
}
