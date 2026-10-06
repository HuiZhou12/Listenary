/// 具有独立请求链路与业务语义的在线音乐能力。
///
/// 封面不是独立能力：它是 search / playlist / stream 结果里的字段，
/// 由返回该数据的 Provider 一并给出，不额外发请求。
enum OnlineMusicCapability { search, playlist, lyric, stream }
