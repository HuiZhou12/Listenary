/// **本地库**那一套在线歌词搜索的来源枚举（P-15）。
///
/// ⚠️ 与 `lib/lyric/lyric_source.dart` 里的同名枚举**不是同一个类型**（值域不同：
/// 这里 3 个、那边 5 个且含 `amll`/`local`）——两套子系统并存是**当前模型边界**
/// （Spec S6：本阶段明确不合并、不动本地歌词源）。
///
/// 在线曲目（`PlatformTrackRef`）**不读这个枚举**：那条链路按 `ref.platform` 路由到
/// 对应的 Provider（`RemoteLyricController` → `OnlineMusicService.fetchLyrics`）。
enum LyricSourceType {
  qq('QQ'),
  kugou('酷狗'),
  ne('网易');

  final String displayName;
  const LyricSourceType(this.displayName);

  static LyricSourceType? fromString(String value) {
    for (final v in LyricSourceType.values) {
      if (v.name == value) return v;
    }
    return null;
  }
}
