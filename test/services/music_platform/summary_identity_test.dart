import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/services/music_platform/chksz/index.dart';

/// F5-P-39（P3 收尾）：**摘要类**（歌单/分类/搜索页）也带平台身份，
/// 使界面 8 处"歌单/分类标题"能显示自定义平台声明的名字。
void main() {
  const idA = '0f9a1c2e-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const idB = '0f9a1c2e-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

  test('★ P3 摘要身份：缺省 platformId ⇒ 等价内置身份（旧构造点零改动）', () {
    const summary = RemotePlaylistSummary(
      platform: MusicPlatform.netease,
      id: '500',
      name: '榜单',
    );
    expect(summary.identity, const PlatformIdentity.builtin(MusicPlatform.netease));

    const category = RemotePlaylistCategory(
      platform: MusicPlatform.netease,
      id: '华语',
      name: '华语',
    );
    expect(category.identity.platformId, isNull);

    final page = MusicSearchPage(platform: MusicPlatform.netease, items: const []);
    expect(page.identity.isValid, isTrue);
  });

  test('★ P3 摘要身份：带稳定 ID ⇒ 两个自定义平台即使同名/同 ID 也不互相顶替', () {
    const a = RemotePlaylistSummary(
      platform: MusicPlatform.custom,
      platformId: idA,
      id: '1',
      name: '同名歌单',
    );
    const b = RemotePlaylistSummary(
      platform: MusicPlatform.custom,
      platformId: idB,
      id: '1',
      name: '同名歌单',
    );

    expect(a.identity.platform, MusicPlatform.custom);
    expect(a.identity.platformId, idA);
    expect(b.identity.platformId, idB);
    expect(a.identity == b.identity, isFalse, reason: '同 ID 名称不改变身份');

    // 身份可被界面出口解析（找不到配置时兜底「自定义平台」，绝不回落网易云）。
    expect(platformLabelForIdentityOnly(a.identity), '自定义平台');
    expect(platformLabelForIdentityOnly(a.identity), isNot('网易云'));
  });

  test('★ P3 摘要身份：RemotePlaylist（歌单详情）同样带身份', () {
    final playlist = RemotePlaylist(
      platform: MusicPlatform.custom,
      platformId: idA,
      id: '9',
      name: '自建歌单',
    );
    expect(playlist.identity.platformId, idA);
    expect(playlist.identity.isValid, isTrue);
  });
}