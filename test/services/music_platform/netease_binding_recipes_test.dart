import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_response_mapper.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/provider/online_music_binding.dart';
import 'package:pure_music/services/music_platform/provider/online_music_capability.dart';
import 'package:pure_music/services/music_platform/provider/online_music_json_path.dart';
import 'package:pure_music/services/music_platform/provider/online_music_request_spec.dart';
import 'package:pure_music/services/music_platform/provider/online_music_response_spec.dart';

import 'live_response_fixtures.g.dart';

/// 网易云七项发现类能力的**可直接粘贴配置**（人工验收清单 §1.1 的配套件）。
///
/// 为什么要有这个文件：人工验收里最费事、最容易配错的一步，是照着文档手动配七项能力
/// （请求路径 + 列表路径 + 每个字段映射）。配错的特征恰恰是"**不报错、但内容少了/错了**"。
/// 这里把七项配置**写成代码**，因此：
///   1. **字段与转换必须通过应用自己的校验**（`domainFieldsFor` + `expectedFieldKinds`）——
///      配错会直接编译期/测试期失败，而不是等你到界面上踩；
///   2. 它们能**往返 JSON**（`toJson` → `fromJson`），即"粘进设置页的 JSON 一定能被解析"；
///   3. 用**真实响应节选**跑一遍映射，证明取到的是对的值（不是"路径看着像"）。
///
/// 打印出来的 JSON 直接对应设置页"能力绑定的 JSON"输入框。
/// 样本来源均为 2026-10-08 的实测响应（`http://127.0.0.1:3000`）。
JsonPath _p(String source) => JsonPath.tryParse(source)!;

/// 网易云七项能力的**统一成功谓词**：业务码必须是 `200`。
///
/// 为什么必须写它（能力映射 §6.9 的硬性要求）：真实服务在**上游风控**时会返回
/// **`code 2001` + 列表全空** —— 若不校验业务码，界面就会把"被挡下"渲染成"**这个平台没有内容**"，
/// 而那正是本阶段一直要防的"把失败当空"。
/// 实测这六个接口在正常时**都**返回 `code = 200`（2026-10-08 逐个请求过）⇒ 这条谓词是安全的。
OnlineMusicSuccessSpec _neteaseSuccess() => OnlineMusicSuccessSpec(
  allOf: [
    OnlineMusicSuccessPredicate(
      path: _p('code'),
      op: OnlineMusicPredicateOp.eq,
      value: 200,
    ),
  ],
);

OnlineMusicDeclarativeCapabilityBinding _search() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/search',
        query: [
          OnlineMusicParamBinding(
            name: 'keywords',
            source: OnlineMusicInputSource.keyword,
            required: true,
          ),
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
          ),
          OnlineMusicParamBinding(
            name: 'offset',
            source: OnlineMusicInputSource.offset,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        success: _neteaseSuccess(),
        listPath: _p('result.songs'),
        fields: {
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          // 艺人 id（与 artists 同序）：曲目行据此打开艺人页（2026-10-12）✓。
          OnlineMusicDomainField.artistIds: OnlineMusicFieldSpec(
            candidates: [_p('artists[*].id')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
            candidates: [_p('artists[*].name')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.album: OnlineMusicFieldSpec(
            candidates: [_p('album.name')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
            candidates: [_p('duration')],
            transform: OnlineMusicFieldTransform.asDurationMs,
          ),
        },
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.offsetLimit,
        ),
      ),
    );

OnlineMusicDeclarativeCapabilityBinding _playlist() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/playlist/detail',
        query: [
          OnlineMusicParamBinding(
            name: 'id',
            source: OnlineMusicInputSource.playlistId,
            required: true,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        success: _neteaseSuccess(),
        listPath: _p('playlist.tracks'),
        fields: {
          // 歌单自身的字段（读根上的 playlist.*）
          OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
            candidates: [_p('playlist.name')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.playlistCoverUri: OnlineMusicFieldSpec(
            candidates: [_p('playlist.coverImgUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.playlistCreator: OnlineMusicFieldSpec(
            candidates: [_p('playlist.creator.nickname')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.playlistTrackCount: OnlineMusicFieldSpec(
            candidates: [_p('playlist.trackCount')],
            transform: OnlineMusicFieldTransform.asInt,
          ),
          // 曲目字段（读每个列表项）——注意这批必须用**新形状** `ar`/`al`/`dt`
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.artistIds: OnlineMusicFieldSpec(
            candidates: [_p('ar[*].id')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
            candidates: [_p('ar[*].name')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.album: OnlineMusicFieldSpec(
            candidates: [_p('al.name')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.coverUri: OnlineMusicFieldSpec(
            candidates: [_p('al.picUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
            candidates: [_p('dt')],
            transform: OnlineMusicFieldTransform.asDurationMs,
          ),
        },
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.none,
        ),
      ),
    );

OnlineMusicDeclarativeCapabilityBinding _playlistCollection() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/top/playlist',
        query: [
          OnlineMusicParamBinding(
            name: 'cat',
            source: OnlineMusicInputSource.categoryId,
          ),
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
          ),
          OnlineMusicParamBinding(
            name: 'offset',
            source: OnlineMusicInputSource.offset,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        success: _neteaseSuccess(),
        listPath: _p('playlists'),
        fields: {
          OnlineMusicDomainField.playlistId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.playlistCoverUri: OnlineMusicFieldSpec(
            candidates: [_p('coverImgUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.playlistCreator: OnlineMusicFieldSpec(
            candidates: [_p('creator.nickname')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.playlistTrackCount: OnlineMusicFieldSpec(
            candidates: [_p('trackCount')],
            transform: OnlineMusicFieldTransform.asInt,
          ),
        },
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.offsetLimit,
        ),
      ),
    );

OnlineMusicDeclarativeCapabilityBinding _playlistCategories() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/playlist/catlist'),
      response: OnlineMusicResponseSpec(
        success: _neteaseSuccess(),
        listPath: _p('sub'),
        fields: {
          // 网易云用**分类名**当请求值（`/top/playlist?cat=华语`）⇒ id 与名字同取 `name`。
          OnlineMusicDomainField.categoryId: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.categoryName: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.categoryCount: OnlineMusicFieldSpec(
            candidates: [_p('resourceCount')],
            transform: OnlineMusicFieldTransform.asInt,
          ),
        },
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.none,
        ),
      ),
    );

OnlineMusicDeclarativeCapabilityBinding _chartList() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(path: '/toplist'),
      response: OnlineMusicResponseSpec(
        success: _neteaseSuccess(),
        listPath: _p('list'),
        fields: {
          OnlineMusicDomainField.playlistId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.playlistName: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.playlistCoverUri: OnlineMusicFieldSpec(
            candidates: [_p('coverImgUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.playlistTrackCount: OnlineMusicFieldSpec(
            candidates: [_p('trackCount')],
            transform: OnlineMusicFieldTransform.asInt,
          ),
          OnlineMusicDomainField.playlistUpdateFrequency: OnlineMusicFieldSpec(
            candidates: [_p('updateFrequency')],
            transform: OnlineMusicFieldTransform.asString,
          ),
        },
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.none,
        ),
      ),
    );

OnlineMusicDeclarativeCapabilityBinding _newSongs() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/personalized/newsong',
        query: [
          OnlineMusicParamBinding(
            name: 'limit',
            source: OnlineMusicInputSource.limit,
          ),
          OnlineMusicParamBinding(
            name: 'offset',
            source: OnlineMusicInputSource.offset,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        success: _neteaseSuccess(),
        listPath: _p('result'),
        fields: {
          // ⚠️ 必须写 `song.*`：顶层也有同名的 id/name，写错不会报错、只会取到"看着对"的值。
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('song.id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('song.name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.artistIds: OnlineMusicFieldSpec(
            candidates: [_p('song.artists[*].id')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
            candidates: [_p('song.artists[*].name')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.album: OnlineMusicFieldSpec(
            candidates: [_p('song.album.name')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.coverUri: OnlineMusicFieldSpec(
            candidates: [_p('song.album.picUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
            candidates: [_p('song.duration')],
            transform: OnlineMusicFieldTransform.asDurationMs,
          ),
        },
        // 实测 `offset` 被忽略 ⇒ 配置里**如实**声明"不可分页"，界面就不会给假按钮。
        pagination: const OnlineMusicPaginationSpec(
          kind: OnlineMusicPaginationKind.none,
        ),
      ),
    );

/// **艺人详情**（`artist`，2026-10-12 实测形状）：
/// `/artists?id=` 返回 `{code, artist, hotSongs, more}` —— 标量在 `artist` 下、
/// 热门曲目在 `hotSongs` 下（用新形状 `ar`/`al`/`dt`）。
OnlineMusicDeclarativeCapabilityBinding _artist() =>
    OnlineMusicDeclarativeCapabilityBinding(
      request: const OnlineMusicRequestSpec(
        path: '/artists',
        query: [
          OnlineMusicParamBinding(
            name: 'id',
            source: OnlineMusicInputSource.artistId,
          ),
        ],
      ),
      response: OnlineMusicResponseSpec(
        success: _neteaseSuccess(),
        fieldsRootPath: _p('artist'),
        listPath: _p('hotSongs'),
        fields: {
          OnlineMusicDomainField.artistName: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.artistAvatarUri: OnlineMusicFieldSpec(
            candidates: [_p('picUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.artistDescription: OnlineMusicFieldSpec(
            candidates: [_p('briefDesc')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.trackId: OnlineMusicFieldSpec(
            candidates: [_p('id')],
            transform: OnlineMusicFieldTransform.asInt,
            required: true,
          ),
          OnlineMusicDomainField.title: OnlineMusicFieldSpec(
            candidates: [_p('name')],
            transform: OnlineMusicFieldTransform.asString,
            required: true,
          ),
          OnlineMusicDomainField.artistIds: OnlineMusicFieldSpec(
            candidates: [_p('ar[*].id')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.artists: OnlineMusicFieldSpec(
            candidates: [_p('ar[*].name')],
            transform: OnlineMusicFieldTransform.asStringList,
          ),
          OnlineMusicDomainField.album: OnlineMusicFieldSpec(
            candidates: [_p('al.name')],
            transform: OnlineMusicFieldTransform.asString,
          ),
          OnlineMusicDomainField.coverUri: OnlineMusicFieldSpec(
            candidates: [_p('al.picUrl')],
            transform: OnlineMusicFieldTransform.asHttpsUri,
          ),
          OnlineMusicDomainField.duration: OnlineMusicFieldSpec(
            candidates: [_p('dt')],
            transform: OnlineMusicFieldTransform.asDurationMs,
          ),
        },
      ),
    );

Map<OnlineMusicCapability, OnlineMusicDeclarativeCapabilityBinding>
_recipe() => {
  OnlineMusicCapability.search: _search(),
  OnlineMusicCapability.playlist: _playlist(),
  OnlineMusicCapability.playlistCollection: _playlistCollection(),
  OnlineMusicCapability.playlistCategories: _playlistCategories(),
  OnlineMusicCapability.chartList: _chartList(),
  OnlineMusicCapability.newSongs: _newSongs(),
  // 艺人详情（2026-10-12）：第七份可直接粘贴的配置 ✓。
  OnlineMusicCapability.artist: _artist(),
};

void main() {
  // ---- 真实响应节选（2026-10-08 实测）----
  //
  // `/playlist/detail?id=19723756`：曲目用**新形状** `ar`/`al`/`dt`（与 `/search` 的老形状并存且不重叠）。
  const realPlaylistSample = <String, Object?>{
    'playlist': {
      'id': 19723756,
      'name': '飙升榜',
      'coverImgUrl': 'http://p1.music.126.net/x.jpg',
      'trackCount': 98,
      'creator': {'nickname': '网易云音乐'},
      'tracks': [
        {
          'id': 3436855494,
          'name': '偷心',
          'ar': [
            {'id': 1, 'name': 'SASIOVERLXRD'},
          ],
          'al': {'id': 2, 'name': '偷心', 'picUrl': 'http://p1.music.126.net/y.jpg'},
          'dt': 188000,
        },
      ],
    },
  };

  // `/personalized/newsong?limit=3`：曲目**嵌在 `song` 里**，顶层另有同名的 id/name。
  const realNewSongSample = <String, Object?>{
    'result': [
      {
        'id': 999,
        'name': '（顶层这个 name 是错的，不能取）',
        'song': {
          'id': 3436855494,
          'name': '偷心',
          'duration': 188000,
          'artists': [
            {'id': 1, 'name': 'SASIOVERLXRD'},
          ],
          'album': {'id': 2, 'name': '偷心', 'picUrl': 'http://p1.music.126.net/y.jpg'},
        },
      },
    ],
  };

  // `/toplist`：`tracks` 恒为 null（预览曲目在 `/toplist/detail` 里才有）。
  const realChartSample = <String, Object?>{
    'list': [
      {
        'id': 19723756,
        'name': '飙升榜',
        'coverImgUrl': 'http://p1.music.126.net/x.jpg',
        'trackCount': 98,
        'updateFrequency': '刚刚更新',
        'tracks': null,
      },
    ],
  };

  // `/playlist/catlist`：分类在 `sub`，数量字段是 `resourceCount`。
  const realCategorySample = <String, Object?>{
    'sub': [
      {'name': '华语', 'resourceCount': 1945, 'category': 1},
    ],
  };

  group('网易云七项能力的可直接粘贴配置', () {
    test('★ 每项只使用该能力允许的领域字段，且转换合法（配错会直接失败）', () {
      _recipe().forEach((capability, binding) {
        final allowed = domainFieldsFor(capability);
        for (final entry in binding.response.fields.entries) {
          expect(
            allowed,
            contains(entry.key),
            reason: '${capability.name} 不允许字段 ${entry.key.name}',
          );
          final kinds = expectedFieldKinds[entry.key];
          final transform = entry.value.transform;
          if (kinds != null) {
            expect(
              kinds,
              contains(transform),
              reason: '${capability.name} 的 ${entry.key.name} 不接受 $transform',
            );
          }
        }
      });
    });

    test('★ 每项都能往返 JSON —— 粘贴进设置页一定能被解析', () {
      _recipe().forEach((capability, binding) {
        final encoded = jsonEncode(binding.toJson());
        final decoded = OnlineMusicCapabilityBinding.fromJson(
          jsonDecode(encoded),
        );
        expect(decoded, isA<OnlineMusicDeclarativeCapabilityBinding>());
        final round = decoded as OnlineMusicDeclarativeCapabilityBinding;
        expect(round.response.listPath, binding.response.listPath);
        expect(round.response.pagination.kind, binding.response.pagination.kind);
        expect(
          round.response.fields.keys.toSet(),
          binding.response.fields.keys.toSet(),
          reason: '${capability.name} 往返后字段集合变了',
        );
        expect(round.request.path, binding.request.path);
      });
    });

    test('★ 歌单详情配置取的是**新形状** ar/al/dt（老形状会静默丢艺人/专辑/时长）', () {
      final playlist = mapDeclarativePlaylistResponse(
        spec: _playlist().response,
        body: realPlaylistSample,
        platform: MusicPlatform.netease,
        requestedPlaylistId: '19723756',
      );
      expect(playlist.name, '飙升榜');
      expect(playlist.trackCount, 98);
      expect(playlist.tracks, hasLength(1));
      final track = playlist.tracks.single;
      expect(track.title, '偷心');
      expect(track.artistDisplay, 'SASIOVERLXRD');
      expect(track.album, '偷心');
      expect(track.duration, const Duration(milliseconds: 188000));
    });

    test('★ 新歌配置必须取 song.* —— 顶层同名 id/name 会被静默取错', () {
      // 新歌的字段集与搜索相同，复用搜索映射取曲目列表。
      final tracks = mapDeclarativeSearchResponse(
        spec: _newSongs().response,
        body: realNewSongSample,
        platform: MusicPlatform.netease,
        limit: 30,
        offset: 0,
      ).items;
      expect(tracks, hasLength(1));
      expect(tracks.single.ref.trackId, '3436855494');
      expect(tracks.single.title, '偷心');
      expect(tracks.single.artistDisplay, 'SASIOVERLXRD');
      expect(tracks.single.duration, const Duration(milliseconds: 188000));
    });

    test('★ 榜单索引配置取出名字/数量/更新节奏（tracks 为 null 不影响）', () {
      final charts = mapDeclarativePlaylistCollectionResponse(
        spec: _chartList().response,
        body: realChartSample,
        platform: MusicPlatform.netease,
      );
      expect(charts, hasLength(1));
      expect(charts.single.name, '飙升榜');
      expect(charts.single.trackCount, 98);
      expect(charts.single.updateFrequency, '刚刚更新');
    });

    test('★ 分类配置的分类 id 用分类名（网易云就是这么收参的）', () {
      final categories = mapDeclarativePlaylistCategoriesResponse(
        spec: _playlistCategories().response,
        body: realCategorySample,
        platform: MusicPlatform.netease,
      );
      expect(categories, hasLength(1));
      expect(categories.single.id, '华语');
      expect(categories.single.name, '华语');
      expect(categories.single.count, 1945);
    });

    test('★ 跨接口一致性：同一首歌经「搜索」与「歌单详情」两条链路拿到**同一个身份**', () {
      // R4 / F14 承诺过的那条不变量：`(platform, trackId)` 是收藏/历史/歌单的主键，
      // 同一首歌若在不同接口得到不同 trackId，就会在各处产生**两条记录**。
      // 网易云两套字段形状**并存且不重叠**（老形状 `artists/album/duration` 与
      // 新形状 `ar/al/dt`），所以这条必须实测，不能靠"看起来一样"。
      const sameId = 3436855494;

      // 老形状（`/search` 的 `result.songs[*]`）
      final fromSearch = mapDeclarativeSearchResponse(
        spec: _search().response,
        body: const <String, Object?>{
          'result': {
            'songs': [
              {
                'id': sameId,
                'name': '偷心',
                'duration': 188000,
                'artists': [
                  {'name': 'SASIOVERLXRD'},
                ],
                'album': {'name': '偷心'},
              },
            ],
          },
        },
        platform: MusicPlatform.netease,
        limit: 30,
        offset: 0,
      ).items.single;

      // 新形状（`/playlist/detail` 的 `playlist.tracks[*]`）
      final fromPlaylist = mapDeclarativePlaylistResponse(
        spec: _playlist().response,
        body: const <String, Object?>{
          'playlist': {
            'name': '飙升榜',
            'trackCount': 1,
            'tracks': [
              {
                'id': sameId,
                'name': '偷心',
                'dt': 188000,
                'ar': [
                  {'name': 'SASIOVERLXRD'},
                ],
                'al': {'name': '偷心'},
              },
            ],
          },
        },
        platform: MusicPlatform.netease,
        requestedPlaylistId: '19723756',
      ).tracks.single;

      expect(fromSearch.title, fromPlaylist.title);
      expect(fromSearch.ref.platform, MusicPlatform.netease);
      expect(fromPlaylist.ref.platform, MusicPlatform.netease);
      // ★ 核心断言：两条链路给出同一个身份 ⇒ 收藏/历史里**不会**出现两条。
      expect(fromSearch.ref.trackId, fromPlaylist.ref.trackId);
      expect(fromSearch.ref.trackId, '$sameId');
    });

    test('★ 正对照：**不同**的 id 必须给出**不同**的身份（否则"一致"是假的一致）', () {
      final fromSearch = mapDeclarativeSearchResponse(
        spec: _search().response,
        body: const <String, Object?>{
          'result': {
            'songs': [
              {
                'id': 111,
                'name': 'A',
                'artists': [
                  {'name': 'X'},
                ],
                'album': {'name': 'M'},
              },
            ],
          },
        },
        platform: MusicPlatform.netease,
        limit: 30,
        offset: 0,
      ).items.single;

      final fromPlaylist = mapDeclarativePlaylistResponse(
        spec: _playlist().response,
        body: const <String, Object?>{
          'playlist': {
            'name': 'P',
            'trackCount': 1,
            'tracks': [
              {
                'id': 222,
                'name': 'B',
                'ar': [
                  {'name': 'Y'},
                ],
                'al': {'name': 'N'},
              },
            ],
          },
        },
        platform: MusicPlatform.netease,
        requestedPlaylistId: '1',
      ).tracks.single;

      expect(fromSearch.ref.trackId, isNot(fromPlaylist.ref.trackId));
    });

    test('★ §6.9：业务码非成功（如风控 code 2001 + 空列表）必须判为**失败**，不是"空"', () {
      // 上游风控的真实形状：HTTP 200、业务码 2001、列表存在但为空。
      const blocked = <String, Object?>{
        'code': 2001,
        'result': {'songs': <Object?>[]},
        'playlists': <Object?>[],
        'list': <Object?>[],
        'sub': <Object?>[],
        'playlist': {'tracks': <Object?>[]},
      };
      _recipe().forEach((capability, binding) {
        expect(
          declarativeResponseIsSuccess(
            spec: binding.response.success,
            statusCode: 200,
            body: blocked,
          ),
          isFalse,
          reason: '${capability.name} 不能把"被上游挡下"渲染成"这个平台没有内容"',
        );
      });

      // 反向证据（比"删掉谓词看它红不红"更持久）：**空**成功谓词会把同一条响应判成**成功** ——
      // 这正是"不写业务码校验"的后果，也是 §6.9 要求必须写它的原因。
      expect(
        declarativeResponseIsSuccess(
          spec: const OnlineMusicSuccessSpec(),
          statusCode: 200,
          body: blocked,
        ),
        isTrue,
        reason: '空谓词会放过风控响应 ⇒ 说明上面那条断言确实在守着东西',
      );
    });

    test('★ 正对照：正常响应（code 200）必须判为成功', () {
      _recipe().forEach((capability, binding) {
        expect(
          declarativeResponseIsSuccess(
            spec: binding.response.success,
            statusCode: 200,
            body: const {'code': 200},
          ),
          isTrue,
          reason: '${capability.name} 的正常响应应判成功',
        );
      });
    });

    // ── R67：用**真实响应**（固件）核这六份配置 ────────────────────────────────
    //
    // 上面几条用的是**手写样本**；手写样本可能"恰好成立"，而真实数据不成立。
    // 这里改用脚本抓下来的真实响应（`live_response_fixtures.g.dart`，只把列表裁到前 2 条），
    // 断言**映射结果与原始 JSON 里的值一致** —— 也就是"这份配置在真实数据上取对了"。
    test('★ 真实响应：七项配置的成功谓词都接受（业务码 200）', () {
      final fixtures = <String, Map<String, Object?>>{
        'search': rawSearch,
        'playlist': rawPlaylist,
        'chartList': rawChartList,
        'playlistCategories': rawCategories,
        'newSongs': rawNewSongs,
        'playlistCollection': rawCollection,
        // 艺人详情（2026-10-12）：真实 `/artists?id=` 的响应 ✓。
        'artist': rawArtist,
      };
      _recipe().forEach((capability, binding) {
        final body = fixtures[capability.name];
        expect(body, isNotNull, reason: '缺少 ${capability.name} 的真实固件');
        expect(
          declarativeResponseIsSuccess(
            spec: binding.response.success,
            statusCode: 200,
            body: body,
          ),
          isTrue,
          reason: '${capability.name} 的真实响应（code=200）必须判为成功',
        );
      });
    });

    test('★ 真实响应：搜索配置取到的标题/艺人/专辑/时长与原始 JSON 一致', () {
      final raw = rawSearch;
      final firstSong =
          (raw['result']! as Map<String, Object?>)['songs']! as List<Object?>;
      final rawFirst = firstSong.first! as Map<String, Object?>;
      final rawArtists = rawFirst['artists']! as List<Object?>;

      final mapped = mapDeclarativeSearchResponse(
        spec: _search().response,
        body: raw,
        platform: MusicPlatform.netease,
        limit: 2,
        offset: 0,
      ).items;
      expect(mapped, hasLength(firstSong.length));
      expect(mapped.first.title, rawFirst['name']);
      expect(mapped.first.album, (rawFirst['album']! as Map<String, Object?>)['name']);
      expect(
        mapped.first.duration,
        Duration(milliseconds: (rawFirst['duration']! as num).toInt()),
      );
      expect(
        mapped.first.artists,
        rawArtists.map((item) => (item! as Map<String, Object?>)['name']),
      );
      expect(mapped.first.ref.trackId, '${rawFirst['id']}');
    });

    test('★ 真实响应：歌单详情配置取的是新形状 ar/al/dt（与原始 JSON 一致）', () {
      final raw = rawPlaylist;
      final rawPlaylistBody = raw['playlist']! as Map<String, Object?>;
      final rawTracks = rawPlaylistBody['tracks']! as List<Object?>;
      final rawFirst = rawTracks.first! as Map<String, Object?>;

      final mapped = mapDeclarativePlaylistResponse(
        spec: _playlist().response,
        body: raw,
        platform: MusicPlatform.netease,
        requestedPlaylistId: '${rawPlaylistBody['id']}',
      );
      expect(mapped.name, rawPlaylistBody['name']);
      expect(mapped.trackCount, rawPlaylistBody['trackCount']);
      expect(mapped.tracks, hasLength(rawTracks.length));
      expect(mapped.tracks.first.title, rawFirst['name']);
      expect(mapped.tracks.first.album, (rawFirst['al']! as Map<String, Object?>)['name']);
      expect(
        mapped.tracks.first.duration,
        Duration(milliseconds: (rawFirst['dt']! as num).toInt()),
      );
      expect(
        mapped.tracks.first.artists,
        (rawFirst['ar']! as List<Object?>)
            .map((item) => (item! as Map<String, Object?>)['name']),
      );
    });

    test('★ 真实响应：榜单配置取到的名字/数量/更新节奏与原始 JSON 一致', () {
      final raw = rawChartList;
      final rawList = raw['list']! as List<Object?>;
      final rawFirst = rawList.first! as Map<String, Object?>;

      final mapped = mapDeclarativePlaylistCollectionResponse(
        spec: _chartList().response,
        body: raw,
        platform: MusicPlatform.netease,
      );
      expect(mapped, hasLength(rawList.length));
      expect(mapped.first.name, rawFirst['name']);
      expect(mapped.first.trackCount, rawFirst['trackCount']);
      expect(mapped.first.updateFrequency, rawFirst['updateFrequency']);
    });

    test('★ 真实响应：分类配置的分类 id 就是分类名、数量取自 resourceCount', () {
      final raw = rawCategories;
      final rawSub = raw['sub']! as List<Object?>;
      final rawFirst = rawSub.first! as Map<String, Object?>;

      final mapped = mapDeclarativePlaylistCategoriesResponse(
        spec: _playlistCategories().response,
        body: raw,
        platform: MusicPlatform.netease,
      );
      expect(mapped, hasLength(rawSub.length));
      expect(mapped.first.id, rawFirst['name']);
      expect(mapped.first.name, rawFirst['name']);
      expect(mapped.first.count, rawFirst['resourceCount']);
    });

    test('★ 真实响应：新歌配置取的是 song.* —— 顶层同名字段不会被取到', () {
      final raw = rawNewSongs;
      final rawResult = raw['result']! as List<Object?>;
      final wrapper = rawResult.first! as Map<String, Object?>;
      final rawSong = wrapper['song']! as Map<String, Object?>;

      final mapped = mapDeclarativeSearchResponse(
        spec: _newSongs().response,
        body: raw,
        platform: MusicPlatform.netease,
        limit: 2,
        offset: 0,
      ).items;
      expect(mapped, hasLength(rawResult.length));
      // 取的是 `song.*` 的值，而不是包装层顶部的同名值。
      expect(mapped.first.title, rawSong['name']);
      expect(mapped.first.ref.trackId, '${rawSong['id']}');
      expect(
        mapped.first.duration,
        Duration(milliseconds: (rawSong['duration']! as num).toInt()),
      );
      if (wrapper['id'] != rawSong['id']) {
        expect(mapped.first.ref.trackId, isNot('${wrapper['id']}'), reason: '不能取到顶层 id');
      }
    });

    test('★ 真实响应：平台歌单配置取到的名字/数量与原始 JSON 一致', () {
      final raw = rawCollection;
      final rawPlaylists = raw['playlists']! as List<Object?>;
      final rawFirst = rawPlaylists.first! as Map<String, Object?>;

      final mapped = mapDeclarativePlaylistCollectionResponse(
        spec: _playlistCollection().response,
        body: raw,
        platform: MusicPlatform.netease,
      );
      expect(mapped, hasLength(rawPlaylists.length));
      expect(mapped.first.name, rawFirst['name']);
      expect(mapped.first.trackCount, rawFirst['trackCount']);
    });

    test('★ 真实响应：艺人配置取到的名字/简介/热门曲目与原始 JSON 一致', () {
      final raw = rawArtist;
      final rawArtistMap = raw['artist']! as Map<String, Object?>;
      final rawSongs = raw['hotSongs']! as List<Object?>;

      final mapped = mapDeclarativeArtistResponse(
        spec: _artist().response,
        body: raw,
        platform: MusicPlatform.netease,
        // 艺人 id 在**请求**里（响应里没有）⇒ 由调用方回填 ✓。
        requestedArtistId: '7763',
      );

      expect(mapped.id, '7763', reason: '身份来自请求，不靠响应编造');
      expect(mapped.name, rawArtistMap['name'], reason: '艺人名取自 artist.name');
      expect(
        mapped.description,
        rawArtistMap['briefDesc'],
        reason: '简介取自 artist.briefDesc',
      );
      expect(mapped.hotSongs, hasLength(rawSongs.length));

      final first = rawSongs.first! as Map<String, Object?>;
      final firstAr = (first['ar']! as List<Object?>).first! as Map<String, Object?>;
      final firstAl = first['al']! as Map<String, Object?>;
      expect(mapped.hotSongs.first.title, first['name']);
      expect(mapped.hotSongs.first.artists.first, firstAr['name']);
      expect(mapped.hotSongs.first.artistIds.first, '${firstAr['id']}');
      expect(mapped.hotSongs.first.album, firstAl['name']);
    });

    test('把七项配置写成可直接复制的 JSON 文件（人工验收清单配套，并当场校验可解析）', () {
      const encoder = JsonEncoder.withIndent('  ');
      final directory = Directory('docs/dev/netease-bindings');
      directory.createSync(recursive: true);

      final written = <String>[];
      _recipe().forEach((capability, binding) {
        final json = encoder.convert(binding.toJson());
        final file = File('${directory.path}/${capability.name}.json');
        file.writeAsStringSync('$json\n');
        written.add(file.path);

        // 写出去的必须能被应用自己解析回来（否则这份"可直接粘贴"的承诺就是假的）。
        final parsed = OnlineMusicCapabilityBinding.fromJson(
          jsonDecode(file.readAsStringSync()),
        );
        expect(parsed, isA<OnlineMusicDeclarativeCapabilityBinding>());
      });

      expect(written, hasLength(7));
      // ignore: avoid_print
      print('已写出 ${written.length} 个配置：${written.join(', ')}');
    });
  });
}
