// ignore_for_file: constant_identifier_names

const String ONLINE_MUSIC_PAGE = '/online';
// 在线艺人页（`artist` 能力，2026-10-12）：作为 `/online` 的子路由 ⇒ 与其它在线页同族 ✓。
const String ONLINE_ARTIST_PAGE = '/online/artist';
// 艺人的**全部热门歌曲**（2026-10-12）：艺人页「全部显示」的目标 ✓；作为 `/online/artist` 的子路由 ✓。
const String ARTIST_HOT_SONGS_PAGE = '/online/artist/hot-songs';
// 在线专辑页（`album` 能力，2026-10-12）：同为 `/online` 的子路由 ✓。
const String ONLINE_ALBUM_PAGE = '/online/album';
// 「新专辑」与「新歌」是**两个**落地页（2026-10-17 拆开 ✓）：探索页两个区块的
// 「查看全部」各进自己的页 ✓ —— 此前共用一个「专辑和单曲」页，于是某个入口下
// 两个标题叠在一起，且点「新歌 → 查看全部」先看到「新专辑」✗。
// 作为 `/explore` 的子路由 ⇒ 与探索页同族 ✓。
const String NEW_ALBUMS_PAGE = '/explore/new-albums';
const String NEW_SONGS_PAGE = '/explore/new-songs';
// 平台歌单列表页（2026-10-12）：探索页「平台歌单 → 查看全部」与「歌单分类 → 点 tag」都进这里 ✓。
const String PLATFORM_PLAYLISTS_PAGE = '/explore/playlists';
const String FAVORITES_PAGE = '/favorites';

const String AUDIOS_PAGE = '/audios';
const String AUDIO_DETAIL_PAGE = '/audios/detail';

const String ARTISTS_PAGE = '/artists';
const String ARTIST_DETAIL_PAGE = '/artists/detail';

const String ALBUMS_PAGE = '/albums';
const String ALBUM_DETAIL_PAGE = '/albums/detail';

const String FOLDERS_PAGE = '/folders';
const String FOLDER_DETAIL_PAGE = '/folders/detail';

const String PLAYLISTS_PAGE = '/playlists';
const String PLAYLIST_DETAIL_PAGE = '/playlists/detail';
// `/playlists/online` 本身**不是页面**（纯分组节点）：它下面挂着两条子路由 ✓。
// 这里曾经有一个 `ONLINE_PLAYLISTS_PAGE` 常量指向一个独立列表页，但那页与歌单页
// 做同一件事、且全仓没有任何入口指向它 ⇒ 页面与常量一起删除 ✓。
const String ONLINE_PLAYLIST_DETAIL_PAGE = '/playlists/online/detail';
// **远程歌单预览**（2026-10-12）：只读、不订阅 —— 点榜单/歌单封面进这里 ✓。
const String REMOTE_PLAYLIST_PAGE = '/playlists/online/preview';
const String PERSONAL_PLAYLIST_DETAIL_PAGE = '/playlists/personal/detail';

const String NOW_PLAYING_PAGE = '/nowplaying';

const String STATS_PAGE = '/stats';

const String SETTINGS_PAGE = '/settings';
const String SETTINGS_ISSUE_PAGE = '/settings/issue';

/// 聚合主页：多平台内容与各平台状态的统一入口。
const String HOME_PAGE = '/home';

/// 探索：目录式的多平台内容浏览入口（与主页并列的一级页面）。
const String EXPLORE_PAGE = '/explore';

/// 探索 · 榜单全量页（货架上的「查看全部」落地到网格）。
const String EXPLORE_CHART_LIST_PAGE = '/explore/charts';

const String WELCOMING_PAGE = '/welcoming';

const String UPDATING_DIALOG = '/updating';

const String TEST_BACKGROUND = '/test/background';

/// 可以作为 start page 的 pages
///
/// **只允许追加**：`AppPreference.startPage` 存的是这张表的下标，
/// 往中间插值会让老用户已选的启动页漂移到别的页面上（配置语义破坏）。
const List<String> START_PAGES = [
  AUDIOS_PAGE,
  ARTISTS_PAGE,
  ALBUMS_PAGE,
  FOLDERS_PAGE,
  PLAYLISTS_PAGE,
  HOME_PAGE,
];

/// 主页在 [START_PAGES] 中的下标。
///
/// 写成常量是因为 `const` 表达式里不能取 `List.length`；**改动 START_PAGES 时必须同步**，
/// `test/component/side_nav_destination_test.dart` 会守住两者一致。
const int HOME_START_PAGE_INDEX = 5;

/// **根路径 `/` 应该落到哪一页** ✓（2026-10-12 修正）。
///
/// 为什么抽成函数：`/` 的重定向以前**硬编码**成「音频」✗，而启动页的默认值是
/// [HOME_START_PAGE_INDEX]（**主页**）✓ —— 于是"用户选的启动页"与"从根路径进来看到的页"
/// 是两套口径 ✗，而且那条重定向**没有测试**钉住 ✗。抽出来之后两者同源 ✓、也能直接测 ✓。
///
/// 下标越界时按边界夹住 ✓（与 `AppPreference` 的 `_normalizedBoundedInt` 同一策略 ✓）。
String startPageLocationFor(int startPageIndex) =>
    START_PAGES[startPageIndex.clamp(0, START_PAGES.length - 1)];
