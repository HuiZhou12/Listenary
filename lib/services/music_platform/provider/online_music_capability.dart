/// 具有独立请求链路与业务语义的在线音乐能力。
///
/// 封面不是独立能力：它是 search / playlist / playlistCollection / stream 结果里的字段，
/// 由返回该数据的 Provider 一并给出，不额外发请求。
///
/// [playlistCollection]（歌单集合 / 歌单列表）与 [playlist]（歌单详情 + 曲目）是
/// **两个业务语义**，各有自己的请求与响应形状；D12 说的"歌单详情与其曲目列表不拆"
/// 指的是后者内部不再拆。拆开是因为"浏览有哪些歌单"与"打开某个歌单"在真实服务里
/// 就是两个接口（Spec §19.2 方案 A）。
///
/// [chartList]（**榜单索引**）同样是一个独立语义：它回答"这个平台发布了哪些名次集合"，
/// 与 [playlistCollection]（"有哪些歌单"）是不同内容类型，真实服务里也是不同接口
/// （例如网易云 `/toplist` 对 `/top/playlist`）。
///
/// **榜单的曲目刻意不新开能力**：在榜单以歌单形态存在的平台上（网易云实测：
/// `/toplist` 给出的 id 直接可用于 `/playlist/detail`，返回完整曲目且不截断），
/// 打开榜单走的仍然是既有的 [playlist] 链路。因此：
/// - [chartList] 返回的摘要里，`id` 就是该平台后续要用的 id；
/// - **只有当该平台同时具备 [playlist] 能力时，榜单才可被打开**，否则会形成死链
///   （实测 QQ 的 `topId` 不适用于 `/getSongListDetail`，所以 QQ 的榜单曲目需要
///   另一条链路，在决定"一个能力是否允许由多个请求组成"之前不接入）。
///
/// [playlistCategories]（**歌单分类**）回答"平台把歌单分成了哪些类"，用于按分类浏览。
/// **"取某分类下的歌单"不新开能力**：那与 [playlistCollection] 是同一种内容、只是多了
/// 一个筛选条件，因此做成 [playlistCollection] 的一个可选输入（`categoryId`）而不是
/// 第七个能力。
///
/// ⚠️ **分类的分组名刻意不在领域模型里**：网易云 `/playlist/catlist` 的分类项只有
/// 数字分组 id（`category`），分组名（语种/风格/场景/情感/主题）在**另一个以该数字为键的
/// 映射**里（`categories`）。要把两者拼起来需要"按同级的另一个字段取值去查表"——
/// 那是**逻辑**而不是映射，与本 DSL "只做映射、不做逻辑"的原则冲突。因此分类在界面上
/// 是**扁平 chip 墙**。将来若确实需要分组，应当作为一次显式的 DSL 能力扩展来设计，
/// 而不是在映射层偷偷加表达式。
///
/// [newSongs]（**新歌**）与前几种不同：它返回的就是**曲目数组**，因此
/// **不新增领域字段**（复用 trackId/title/artists/album/coverUri/duration），
/// 也**不需要新的映射函数**（与搜索同构）。它仍然是一个独立能力，因为它回答的是
/// "这个平台最近发布了什么"，与关键词搜索是两种语义。
/// **界面上它还要求该平台具备 [stream]**：列表里的曲目点不动比不显示更糟。
/// **艺人详情**（`artist`，2026-10-12 新增）：回答"这个艺人是谁 + 他的热门作品"。
///
/// 为什么是新能力而不是塞进 search：真实服务里它就是**另一个接口**（网易云实测
/// `/artists?id=` 返回艺人基本信息 + `hotSongs` 曲目，与关键词搜索是两种语义）；
/// 而且它**同时**产出标量（名字/头像/简介）与**曲目列表** —— 这正是 [playlist]
/// （歌单详情的元数据 + 曲目）已经在用的形状 ✓。
///
/// 为什么热门曲目不新开能力：一次请求就能拿到（D2 决策：**一个能力不做多请求**），
/// 拆成两个能力反而要求两倍配置、且两者必须同源才不矛盾。
///
/// **它需要实体 ID**（艺人 id 在请求里、不在响应里）⇒ 按既有设计**不参与服务级探测** ✓。
/// **专辑详情**（`album`，2026-10-12 新增）：回答"这张专辑是什么 + 它有哪些曲目"。
///
/// 与 [playlist] 同形（元数据 + 曲目列表），但**语义不同**：专辑有"发行时间/曲目数/专辑艺人"
/// 这些歌单没有的东西，真实服务也是**另一个接口**（网易云实测 `/album?id=` 返回
/// `{code, album, songs}`）。参考产品的专辑页把曲目**编号**列出（我们照此 ✓）。
///
/// 它同样**需要实体 ID**（专辑 id 在请求里、不在响应里）⇒ 不参与服务级探测 ✓。
enum OnlineMusicCapability {
  search,
  playlist,
  playlistCollection,
  playlistCategories,
  chartList,
  newSongs,
  artist,
  album,
  /// **艺人的专辑列表**（`artistAlbums`，2026-10-12 新增）：参考产品艺人页的「专辑」区块 ✓。
  ///
  /// 与 [artist]（"艺人 + 热门歌曲"）分开，因为真实服务是**另一个接口**：
  /// 网易云实测 `/artist/album?id=` 返回 `{code, artist, hotAlbums, more, kindTabs}` ✓
  /// （D2：一个能力不做多请求 ✓）。输入复用**艺人 id** ✓（不再新增输入源 ✓）。
  ///
  /// 参考艺人页的分区顺序是：**热门歌曲 → 专辑 → 单曲和迷你专辑 → 视频 → 现场表演** ✓
  /// ⇒ 这一版先做「专辑」✓；「单曲」是同形但另一个接口 ✓，留作下一步 ✓（不假装有 ✓）。
  artistAlbums,
  /// **艺人的单曲列表**（`artistSongs`，2026-10-12 新增）：参考艺人页的「单曲和迷你专辑」区块 ✓。
  ///
  /// 实测 `/artist/songs?id=` → `{code, songs, more, total}`，曲目就是**标准曲目形状** ✓
  /// ⇒ **不放新领域字段**（身份/标题/艺人/专辑/时长全部复用 ✓），模型也直接复用 `MusicTrack` ✓。
  artistSongs,
  /// **新专辑**（`newAlbums`，2026-10-12 新增）：参考 Explore 第一个区块「**新专辑与单曲**」里的"新专辑"那一半 ✓。
  ///
  /// 为什么与 [newSongs] 分开：真实服务是另一个接口，且**输出形状不同**（专辑元数据 vs 曲目 ✓）
  /// —— 网易云实测 `/album/new?limit=N` **认 `limit`** ✓（而 `/album/newest` **不认** ✗，所以用前者 ✓），
  /// 并且它**不需要 `area`** 也能用 ✓（`area` 属"要不要暴露给用户"的决策，这一版先不碰 ✓）。
  newAlbums,
  /// **按关键词搜索专辑**（`searchAlbums`，2026-10-12 新增）：参考搜索页的结果分区里「**专辑**」那一段 ✓。
  ///
  /// 与 [search]（曲目）分开：真实服务是同一接口的**不同 `type`**（网易云实测
  /// `/cloudsearch?type=10` → `result.albums` ✓），且**输出形状不同**（专辑 vs 曲目 ✓）。
  /// 输入复用 `keyword` ✓（不新增输入源 ✓）；**可探测** ✓（给默认关键词即可，与 [search] 同判据 ✓）。
  searchAlbums,
  /// **按关键词搜索艺人**（`searchArtists`，2026-10-12 新增）：参考搜索结果的第三种类型 ✓
  ///（混合结果里以「**艺人 • …**」自报家门 ✓）。
  ///
  /// 与 [searchAlbums] 同形：同一个真实接口的另一个 `type` ✓
  ///（网易云实测 `/cloudsearch?type=100` → `result.artists` ✓）；输入复用 `keyword` ✓；**可探测** ✓。
  searchArtists,
  /// **推荐曲目**（`recommendedTracks`，2026-10-12 新增）：回答"平台给**这个账号**推荐了什么歌" ✓。
  ///
  /// 为什么是新能力：它是**账号相关**的语义 ✓ —— 同一首请求，换个账号结果就不同 ✓；
  /// 与 [newSongs]（"平台最近发布了什么" ✓，与账号无关 ✓）是两件事 ✓。
  /// 真实服务里也是另一个接口（网易云 `/recommend/songs` ✓ 需要登录 ✓）。
  ///
  /// ⚠️ **它通常需要凭据（cookie）** ✓：按既有机制，凭据走**安全槽位** ✓
  ///（`requiresCredential` + 请求头的 `credentialReference` ✓），**绝不写进明文配置** ✗。
  /// 凭据失效是**独立状态** ✓（见面文案要如实说"凭据失效"，**不能**混成"没有推荐" ✗）。
  ///
  /// 输出是**标准曲目数组** ✓ ⇒ 不加新领域字段、也不需要新映射函数 ✓（与 [newSongs] 同构 ✓）。
  /// **可探测** ✓（与 [search] 同判据 ✓）；界面要求该平台具备 [stream] ✓（点不响不如不显示 ✓）。
  recommendedTracks,
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
      OnlineMusicCapability.playlistCategories => '歌单分类',
      OnlineMusicCapability.chartList => '榜单',
      OnlineMusicCapability.newSongs => '新歌',
      OnlineMusicCapability.artist => '艺人详情',
      OnlineMusicCapability.album => '专辑详情',
      OnlineMusicCapability.artistAlbums => '艺人专辑列表',
      OnlineMusicCapability.artistSongs => '艺人单曲列表',
      OnlineMusicCapability.newAlbums => '新专辑',
      OnlineMusicCapability.searchAlbums => '搜索专辑',
      OnlineMusicCapability.searchArtists => '搜索艺人',
      OnlineMusicCapability.recommendedTracks => '推荐曲目',
      OnlineMusicCapability.lyric => '歌词',
      OnlineMusicCapability.stream => '播放解析',
    };
