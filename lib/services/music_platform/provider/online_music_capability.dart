/// 具有独立请求链路与业务语义的在线音乐能力。
///
/// 封面不是独立能力：它是 search / playlist / playlistCollection / stream 结果里的字段，
/// 由返回该数据的 Provider 一并给出，不额外发请求。
///
/// [playlistCollection]（歌单集合 / 歌单列表）与 [playlist]（歌单详情 + 曲目）是
/// **两个业务语义**，各有自己的请求与响应形状；D12 说的"歌单详情与其曲目列表不拆"
/// 指的是后者内部不再拆。拆开是因为"浏览有哪些歌单"与"打开某个歌单"在真实服务里
/// 就是两个接口（Spec §19.2 方案 A）。
enum OnlineMusicCapability {
  search,
  playlist,
  playlistCollection,
  lyric,
  stream,
}

/// 能力的界面文案（设置页与能力编辑器共用一份，避免两处走偏）。
String onlineMusicCapabilityLabel(OnlineMusicCapability capability) =>
    switch (capability) {
      OnlineMusicCapability.search => '搜索',
      // 旧文案「歌曲列表」有歧义：它其实是"某个歌单的详情（含曲目）"。
      OnlineMusicCapability.playlist => '歌单详情',
      OnlineMusicCapability.playlistCollection => '歌单列表',
      OnlineMusicCapability.lyric => '歌词',
      OnlineMusicCapability.stream => '播放解析',
    };
