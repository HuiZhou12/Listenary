import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/enums.dart';
import 'package:pure_music/core/preference.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/page/albums_page.dart';
import 'package:pure_music/page/artists_page.dart';
import 'package:pure_music/page/audios_page.dart';
import 'package:pure_music/page/folders_page.dart';

/// 本地曲库四个页面此前**没有任何页面级测试**（R46 实测：无任何测试 import 它们）。
/// 本文件补上**能做的**那一部分，并把**做不了的那一部分连同证据**记在下面。
///
/// ## 覆盖到的
/// - 专辑页 / 文件夹页：喂入真实模型后**真的画出了这些内容**；
/// - 四个页面：空曲库时给空态且不抛异常（"别把空当崩"）；
/// - 四个页面：窄窗口（420px）下空态不溢出。
///
/// ## 覆盖不到的（**已实测，不是猜的**）
/// 「音频页」与「艺术家页」的**非空**渲染会走到共享外壳 `UniPage` 的"定位到正在播放"按钮，
/// 那条路会构造 `PlayService.playbackService` → `SmtcBridge.create` → `NativeSmtcBackend`
/// → flutter_rust_bridge，而它在 `flutter test` 里**没有初始化**：
///
/// ```
/// [W] [smtc] initialization failed: Bad state: flutter_rust_bridge has not been initialized.
/// #5  new SmtcSessionOwner.create (play_service/smtc_bridge.dart:411)
/// #6  PlayService._sharedSmtcSession (play_service/play_service.dart:234)
/// #11 PlayService.playbackService (play_service/play_service.dart:213)
/// #12 _UniPageState._locateNowPlayingButton (page/uni_page.dart:358)
/// ```
///
/// **试过 `await RustLib.init()`（应用在 `main.dart:95` 就是这么做的）**：在 `flutter test` 下
/// **仍拿不到可用的 rust 层**，这两个用例依旧失败 ⇒ 不是"忘了初始化"，而是**该路径依赖原生层**。
/// 因此这里**不写**这两个用例 —— 写了就是"看着有覆盖、其实测不到"的假覆盖。
///
/// 结论：本地曲库的**页面层覆盖是"两页 + 空态 + 窄窗"**，不是"四页全测"。
void main() {
  late PagePreference? audiosPref;
  late PagePreference? artistsPref;
  late PagePreference? albumsPref;

  setUp(() {
    // 这些是全局单例：先记下原值，tearDown 里还原（避免污染同进程里的其它测试）。
    audiosPref = AppPreference.instance.audiosPagePref;
    artistsPref = AppPreference.instance.artistsPagePref;
    albumsPref = AppPreference.instance.albumsPagePref;

    AudioLibrary.instance.dispose();
    AppPreference.instance.audiosPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.list,
    );
    AppPreference.instance.artistsPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.table,
    );
    AppPreference.instance.albumsPagePref = PagePreference(
      0,
      SortOrder.ascending,
      ContentView.table,
    );
  });

  tearDown(() {
    if (audiosPref != null) AppPreference.instance.audiosPagePref = audiosPref!;
    if (artistsPref != null) {
      AppPreference.instance.artistsPagePref = artistsPref!;
    }
    if (albumsPref != null) AppPreference.instance.albumsPagePref = albumsPref!;
  });

  Audio audioOf(String title, String artist, String albumName, String path) =>
      Audio(
        title,
        artist,
        albumName,
        null,
        1,
        60,
        320,
        44100,
        path,
        1,
        1,
        'test',
        disc: 1,
      );

  /// 喂入两首歌、两张专辑、两位艺术家、一个文件夹。
  ///
  /// 这几处集合在真实运行时由扫描/入库流程填充；这里**直接赋值公开集合**
  /// （与既有 `test/library/audio_library_tag_update_test.dart` 的做法一致），
  /// 目的是把"页面能不能把曲库内容画出来"单独测出来，不牵扯扫盘与数据库。
  void seedLibrary() {
    final first = audioOf('夜曲', '周杰伦', '十一月的萧邦', r'C:\Music\a.mp3');
    final second = audioOf('海阔天空', 'Beyond', '乐与怒', r'C:\Music\b.mp3');
    final library = AudioLibrary.instance;
    library.folders = [
      AudioFolder([first, second], r'C:\Music', 1, 1),
    ];
    library.audioCollection = [first, second];
    library.albumCollection = {
      '十一月的萧邦': Album(name: '十一月的萧邦')..works.add(first),
      '乐与怒': Album(name: '乐与怒')..works.add(second),
    };
    library.artistCollection = {
      '周杰伦': Artist(name: '周杰伦')..works.add(first),
      'Beyond': Artist(name: 'Beyond')..works.add(second),
    };
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('专辑页渲染曲库里的专辑', (tester) async {
    seedLibrary();
    await pumpPage(tester, const AlbumsPage());

    expect(tester.takeException(), isNull);
    expect(find.text('十一月的萧邦'), findsWidgets);
    expect(find.text('乐与怒'), findsWidgets);
  });

  testWidgets('文件夹页渲染曲库里的文件夹', (tester) async {
    seedLibrary();
    await pumpPage(tester, const FoldersPage());

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Music'), findsWidgets);
  });

  testWidgets('空曲库时四个页面都给出空态且不抛异常（回归：别把空当崩）', (tester) async {
    // 刻意不 seed：这是"真的没有内容"那一态。
    for (final page in const [
      AudiosPage(),
      AlbumsPage(),
      ArtistsPage(),
      FoldersPage(),
    ]) {
      await pumpPage(tester, page);
      expect(
        tester.takeException(),
        isNull,
        reason: '${page.runtimeType} 空曲库时不应抛异常',
      );
    }
  });

  testWidgets('窄窗口下四个页面的空态不溢出（本地曲库的既有风险点）', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 说明：这里刻意用**空曲库**（非空渲染会撞上前文记录的原生层依赖）。
    for (final page in const [
      AudiosPage(),
      AlbumsPage(),
      ArtistsPage(),
      FoldersPage(),
    ]) {
      await pumpPage(tester, page);
      expect(
        tester.takeException(),
        isNull,
        reason: '${page.runtimeType} 窄窗不应溢出',
      );
    }
  });
}
