import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/online_search_state.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// 在线搜索的**纯逻辑**测试（Spec §7.3）。
///
/// 这一层不需要 pump 任何 widget：摊平顺序、`hasMore` 的双重判定、同名平台的
/// 短 ID 规则都是纯函数/纯类型 —— 面板只是把它们渲染出来。这样"顺序错了"
/// 与"渲染错了"是两类失败，不会混在一条 widget 断言里。
void main() {
  const netease = PlatformIdentity.builtin(MusicPlatform.netease);
  const qq = PlatformIdentity.builtin(MusicPlatform.qq);

  group('OnlineSearchPlatformState', () {
    test('hasMore 需要"上一页满页"且"未加载完"两个条件同时成立', () {
      final group = OnlineSearchPlatformState(identity: netease, label: '网易云');

      // 还没搜过 ⇒ 没有下一页。
      expect(group.hasMore, isFalse);

      // 满页返回（30 条）且 total 还有 ⇒ 可以继续。
      group.page = _page(_tracks(0, 30), total: 60);
      group.lastPageCount = 30;
      expect(group.hasMore, isTrue);

      // 已加载数量 == total ⇒ 到底。
      group.page = _page(_tracks(0, 30), total: 30);
      expect(group.hasMore, isFalse);
    });

    test('hasMore: 上一页不足一页时即使 total 很大也停止', () {
      final group = OnlineSearchPlatformState(identity: netease, label: '网易云');
      // total 声明 500，但服务只回了 10 条 ⇒ 接口不可靠，不能无限翻。
      group.page = _page(_tracks(0, 10), total: 500);
      group.lastPageCount = 10;
      expect(group.hasMore, isFalse);
    });

    test('hasMore: 空结果不提供下一页入口', () {
      final group = OnlineSearchPlatformState(identity: netease, label: '网易云');
      group.page = _page(const [], total: 100);
      group.lastPageCount = 30;
      expect(group.hasMore, isFalse);
    });

    test('keySuffix 对内置平台用枚举名、对自定义平台带稳定 ID', () {
      final builtin = OnlineSearchPlatformState(identity: netease, label: '网易云');
      expect(builtin.keySuffix, 'netease');
      expect(builtin.platform, MusicPlatform.netease);

      // 两个自定义平台共用 `MusicPlatform.custom` —— 只有带上稳定 ID 才不会撞 key。
      const alpha = PlatformIdentity.custom('0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      const beta = PlatformIdentity.custom('a1b2c3d4-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      final a = OnlineSearchPlatformState(identity: alpha, label: 'X');
      final b = OnlineSearchPlatformState(identity: beta, label: 'X');
      expect(a.keySuffix, 'custom-${alpha.platformId}');
      expect(b.keySuffix, 'custom-${beta.platformId}');
      expect(a.keySuffix, isNot(b.keySuffix));
    });

    test('items / total 在未取回结果时是安全的空值', () {
      final group = OnlineSearchPlatformState(identity: netease, label: '网易云');
      expect(group.items, isEmpty);
      expect(group.total, 0);
    });
  });

  group('disambiguatedPlatformLabel', () {
    const alpha = PlatformIdentity.custom('0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    const beta = PlatformIdentity.custom('a1b2c3d4-bbbb-4bbb-8bbb-bbbbbbbbbbbb');

    test('内置平台不加短 ID（基础文案已唯一）', () {
      expect(disambiguatedPlatformLabel(netease, const [netease, qq]), '网易云');
    });

    test('同名自定义平台 ≥2 个时附短 ID 才能分辨', () {
      // 两个都没登记 platformName ⇒ 基础文案同为「自定义平台」。
      final alphaLabel = disambiguatedPlatformLabel(alpha, const [alpha, beta]);
      final betaLabel = disambiguatedPlatformLabel(beta, const [alpha, beta]);
      expect(alphaLabel, '自定义平台（${alpha.shortId}）');
      expect(betaLabel, '自定义平台（${beta.shortId}）');
      expect(alphaLabel, isNot(betaLabel));
    });

    test('同名自定义平台只有 1 个时不加噪声', () {
      expect(disambiguatedPlatformLabel(alpha, const [alpha]), '自定义平台');
    });

    test('无效身份不附短 ID（没有可用的稳定性依据）', () {
      const invalid = PlatformIdentity.custom('');
      // 基础文案走 `platformLabelForIdentityOnly` 的兜底（无效身份 ⇒「未知平台」），
      // 关键是**不附短 ID** —— 空 ID 拼进去只会得到 `未知平台（）` 这种噪声。
      final label = disambiguatedPlatformLabel(invalid, const [invalid]);
      expect(label, '未知平台');
      expect(label, isNot(contains('（）')));
      expect(label, isNot(contains(invalid.shortId ?? '\u0000')));
    });
  });

  group('flattenOnlineSearchEntries — 9 类行模型与摊平顺序', () {
    test('单平台：曲目 → 专辑 → 艺人 → 页脚（不摆分组头）', () {
      final group = _group(netease, '网易云', _tracks(0, 2));
      final entries = flattenOnlineSearchEntries(
        groups: [group],
        albums: {
          netease: [_album('a1', '专辑一')],
        },
        albumsFailed: const {},
        artists: {
          netease: [_artist('ar1', '艺人一')],
        },
        artistsFailed: const {},
      );

      expect(entries.map((entry) => entry.runtimeType), [
        OnlineSearchTrackEntry,
        OnlineSearchTrackEntry,
        OnlineSearchAlbumEntry,
        OnlineSearchArtistEntry,
        OnlineSearchFooterEntry,
      ]);
      // 单平台不摆了分组头。
      expect(entries.whereType<OnlineSearchGroupHeaderEntry>(), isEmpty);
    });

    test('多平台：每组先摆分组头，组内顺序仍是 曲目→专辑→艺人→页脚', () {
      final neteaseGroup = _group(netease, '网易云', _tracks(0, 1));
      final qqGroup = _group(qq, 'QQ音乐', _tracks(100, 1));
      final entries = flattenOnlineSearchEntries(
        groups: [neteaseGroup, qqGroup],
        albums: const {},
        albumsFailed: const {},
        artists: const {},
        artistsFailed: const {},
        showHeaders: true,
      );

      expect(entries.map((entry) => entry.runtimeType), [
        OnlineSearchGroupHeaderEntry,
        OnlineSearchTrackEntry,
        OnlineSearchFooterEntry,
        OnlineSearchGroupHeaderEntry,
        OnlineSearchTrackEntry,
        OnlineSearchFooterEntry,
      ]);
      // 组头认的是自己那一组（不是"第一个组"）。
      final headers = entries.whereType<OnlineSearchGroupHeaderEntry>().toList();
      expect(headers[0].group, same(neteaseGroup));
      expect(headers[1].group, same(qqGroup));
    });

    test('某平台整体失败 ⇒ 只摆失败行，不再摆它的曲目/专辑/艺人', () {
      final failed = _group(netease, '网易云', const [])
        ..error = const OnlineMusicException(
          kind: OnlineMusicErrorKind.network,
          safeMessage: '网络请求失败',
        );
      final entries = flattenOnlineSearchEntries(
        groups: [failed],
        albums: {
          netease: [_album('a1', '不该出现')],
        },
        albumsFailed: const {},
        artists: {
          netease: [_artist('ar1', '也不该出现')],
        },
        artistsFailed: const {},
      );

      expect(entries.map((entry) => entry.runtimeType), [
        OnlineSearchFailureEntry,
      ]);
      expect(entries.single, isA<OnlineSearchFailureEntry>());
      expect((entries.single as OnlineSearchFailureEntry).group, same(failed));
    });

    test('某平台没有结果 ⇒ 空组行（与失败行是两条不同分支）', () {
      final empty = _group(netease, '网易云', const []);
      final entries = flattenOnlineSearchEntries(
        groups: [empty],
        albums: const {},
        albumsFailed: const {},
        artists: const {},
        artistsFailed: const {},
      );

      expect(entries.map((entry) => entry.runtimeType), [
        OnlineSearchEmptyGroupEntry,
      ]);
    });

    test('专辑/艺人搜索失败各自一行，且不影响曲目行', () {
      final group = _group(netease, '网易云', _tracks(0, 1));
      final entries = flattenOnlineSearchEntries(
        groups: [group],
        albums: const {},
        albumsFailed: {netease},
        artists: const {},
        artistsFailed: {netease},
      );

      expect(entries.map((entry) => entry.runtimeType), [
        OnlineSearchTrackEntry,
        OnlineSearchAlbumFailureEntry,
        OnlineSearchArtistFailureEntry,
        OnlineSearchFooterEntry,
      ]);
    });

    test('9 个 final 子类都能被构造，且都继承自同一个 sealed 基类', () {
      final group = OnlineSearchPlatformState(identity: netease, label: '网易云');
      final entries = <OnlineSearchEntry>[
        OnlineSearchGroupHeaderEntry(group),
        OnlineSearchTrackEntry(group, _tracks(0, 1).single),
        OnlineSearchFailureEntry(group),
        OnlineSearchEmptyGroupEntry(group),
        OnlineSearchAlbumEntry(_album('a1', '专辑一')),
        OnlineSearchArtistEntry(_artist('ar1', '艺人一')),
        OnlineSearchArtistFailureEntry(group),
        OnlineSearchAlbumFailureEntry(group),
        OnlineSearchFooterEntry(group),
      ];

      expect(entries, hasLength(9));
      expect(
        entries.map((entry) => entry.runtimeType).toSet(),
        hasLength(9),
        reason: '9 类行模型必须彼此可分辨（否则 switch 会漏分支）',
      );
    });
  });

  test('onlineSearchPageSize 是 30（首请求与分页共用同一页大小）', () {
    expect(onlineSearchPageSize, 30);
  });

  group('filterOnlineSearchEntries — 分类是纯显示过滤（2026-11-04 新增）', () {
    /// 两平台混合结果：曲目 + 专辑 + 艺人 + 页脚（多平台 ⇒ 带分组头）。
    List<OnlineSearchEntry> twoPlatforms() {
      final neteaseGroup = _group(netease, '网易云', _tracks(0, 2));
      final qqGroup = _group(qq, 'QQ音乐', _tracks(100, 1));
      return flattenOnlineSearchEntries(
        groups: [neteaseGroup, qqGroup],
        albums: {
          netease: [_album('a1', '专辑一')],
        },
        albumsFailed: const {},
        artists: {
          netease: [_artist('ar1', '艺人一')],
        },
        artistsFailed: const {},
        showHeaders: true,
      );
    }

    test('「全部」原样返回（同一个 list 实例 ⇒ 默认值零行为回归）', () {
      final entries = twoPlatforms();
      expect(
        filterOnlineSearchEntries(entries, OnlineSearchCategory.all),
        same(entries),
      );
    });

    test('「单曲」只留曲目 / 平台失败 / 空组行 / 页脚，分组头按内容保留', () {
      final filtered = filterOnlineSearchEntries(
        twoPlatforms(),
        OnlineSearchCategory.track,
      );
      expect(filtered.map((entry) => entry.runtimeType), [
        OnlineSearchGroupHeaderEntry,
        OnlineSearchTrackEntry,
        OnlineSearchTrackEntry,
        OnlineSearchFooterEntry,
        OnlineSearchGroupHeaderEntry,
        OnlineSearchTrackEntry,
        OnlineSearchFooterEntry,
      ]);
    });

    test('「专辑」只留专辑行 / 专辑失败行 / 平台失败行 / 页脚', () {
      final filtered = filterOnlineSearchEntries(
        twoPlatforms(),
        OnlineSearchCategory.album,
      );
      // QQ 那边没有专辑 ⇒ 它的分组头不该留下（否则是空标题）。
      expect(filtered.map((entry) => entry.runtimeType), [
        OnlineSearchGroupHeaderEntry,
        OnlineSearchAlbumEntry,
        OnlineSearchFooterEntry,
        OnlineSearchFooterEntry,
      ]);
    });

    test('「艺人」只留艺人行 / 艺人失败行 / 平台失败行 / 页脚', () {
      final filtered = filterOnlineSearchEntries(
        twoPlatforms(),
        OnlineSearchCategory.artist,
      );
      expect(filtered.map((entry) => entry.runtimeType), [
        OnlineSearchGroupHeaderEntry,
        OnlineSearchArtistEntry,
        OnlineSearchFooterEntry,
        OnlineSearchFooterEntry,
      ]);
    });

    test('平台级失败行在每个分类都保留（并保住它自己的分组头）', () {
      final failed = _group(qq, 'QQ音乐', const [])
        ..error = const OnlineMusicException(
          kind: OnlineMusicErrorKind.network,
          safeMessage: 'QQ 服务不可达',
        );
      final entries = flattenOnlineSearchEntries(
        groups: [_group(netease, '网易云', _tracks(0, 1)), failed],
        albums: const {},
        albumsFailed: const {},
        artists: const {},
        artistsFailed: const {},
        showHeaders: true,
      );

      for (final category in [
        OnlineSearchCategory.track,
        OnlineSearchCategory.album,
        OnlineSearchCategory.artist,
      ]) {
        final filtered = filterOnlineSearchEntries(entries, category);
        expect(
          filtered.whereType<OnlineSearchFailureEntry>(),
          hasLength(1),
          reason: '$category 下平台失败行必须如实保留',
        );
        // 失败行的文案不含平台名 ⇒ 它的分组头也必须留着，否则说不清是哪一家失败。
        expect(
          filtered.whereType<OnlineSearchGroupHeaderEntry>().map(
            (entry) => entry.group.label,
          ),
          containsAll(<String>['QQ音乐']),
          reason: '$category 下失败平台的分组头不能丢',
        );
      }
    });

    test('空组行只在「单曲」保留（专辑/艺人视图里它说的是别的事）', () {
      final empty = _group(qq, 'QQ音乐', const []);
      final entries = flattenOnlineSearchEntries(
        groups: [_group(netease, '网易云', _tracks(0, 1)), empty],
        albums: const {},
        albumsFailed: const {},
        artists: const {},
        artistsFailed: const {},
        showHeaders: true,
      );

      expect(
        filterOnlineSearchEntries(entries, OnlineSearchCategory.track)
            .whereType<OnlineSearchEmptyGroupEntry>(),
        hasLength(1),
      );
      for (final category in [
        OnlineSearchCategory.album,
        OnlineSearchCategory.artist,
      ]) {
        expect(
          filterOnlineSearchEntries(
            entries,
            category,
          ).whereType<OnlineSearchEmptyGroupEntry>(),
          isEmpty,
          reason: '$category 视图不摆空组行',
        );
      }
    });

    test('分类枚举的文案与顺序（tab 由它渲染）', () {
      expect(
        [
          for (final category in OnlineSearchCategory.values) category.label,
        ],
        ['全部', '单曲', '专辑', '艺人'],
      );
    });
  });
}

OnlineSearchPlatformState _group(
  PlatformIdentity identity,
  String label,
  List<MusicTrack> tracks,
) => OnlineSearchPlatformState(identity: identity, label: label)
  ..page = MusicSearchPage(
    platform: identity.platform,
    items: tracks,
    offset: 0,
    limit: onlineSearchPageSize,
    total: tracks.length,
  )
  ..lastPageCount = tracks.length;

MusicSearchPage _page(List<MusicTrack> tracks, {required int total}) =>
    MusicSearchPage(
      platform: MusicPlatform.netease,
      items: tracks,
      offset: 0,
      limit: onlineSearchPageSize,
      total: total,
    );

List<MusicTrack> _tracks(int start, int count) => [
  for (var i = start; i < start + count; i++)
    MusicTrack(
      ref: PlatformTrackRef(
        platform: MusicPlatform.netease,
        trackId: 'p$i',
      ),
      title: 'Track p$i',
      artists: const ['Test Artist'],
    ),
];

OnlineAlbumSummary _album(String id, String name) =>
    OnlineAlbumSummary(platform: MusicPlatform.netease, id: id, name: name);

OnlineArtistSummary _artist(String id, String name) =>
    OnlineArtistSummary(platform: MusicPlatform.netease, id: id, name: name);
