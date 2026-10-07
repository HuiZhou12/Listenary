import 'package:pure_music/services/music_platform/models/music_models.dart';

/// 「添加在线歌单（订阅）」对话框的返回值：**平台 + 远端歌单 ID**。
///
/// 来源身份从 UI 开始就是完整的 `(platform, id)`（不变量 I1）—— 页面不再假设
/// "在线歌单就是网易云"，也不再只回传一个裸 ID。
final class OnlinePlaylistDraft {
  const OnlinePlaylistDraft({required this.platform, required this.id});

  final MusicPlatform platform;
  final String id;

  @override
  String toString() => 'OnlinePlaylistDraft(${platform.name}, $id)';
}
