import 'package:pure_music/services/music_platform/index.dart';

/// 远端内容的**展示文案**：只做"把平台声明的事实拼成一行"，不含任何布局/组件依赖。
///
/// 为什么单独一个文件：同一串元信息会被**卡片**（`AlbumShelf`）和**结果行**
/// （`OnlineAlbumRow`）同时使用 —— 让结果行去 import 一个货架 UI 组件是错误的方向
/// （UI 之间平级依赖，迟早互相牵住）；反过来把文案塞进货架里，结果行就成了它的下游。
/// ⇒ 抽到这不依赖 Flutter 的中性位置，两边共用同一份规则。
///
/// 刻意**不扩张成通用格式化系统**：这里只放"已经有 ≥2 个真实调用方、
/// 且格式规则已经写死"的文案；只有一处用的拼串留在各自页面里。

/// 专辑的元信息：**平台声明**的年份与曲目数（有什么说什么 ✓，不编 ✗）。
///
/// 两段式「**专辑 · 年份 · N 首**」：先点名内容类型，再跟最能区分它的信息
/// （与榜单卡的「榜单 · 更新节奏 · N 首」、歌单卡的「歌单 · 创建者 · N 首」同一套读法）。
/// 缺哪段就不写哪段 —— 不猜年份、不编曲目数。
String albumDetailsOf(OnlineAlbumSummary album) => [
  '专辑',
  if (album.releaseTime case final time?) '${time.year} 年',
  if (album.trackCount case final count?) '$count 首',
].join(' · ');
