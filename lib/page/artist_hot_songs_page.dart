import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/content_section.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/component/online_track_entry.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// **艺人的全部热门歌曲**（2026-10-12 新增 ✓）。
///
/// 从艺人页的「**全部显示**」进来 ✓（参考页里热门歌曲下面就是它 ✓）。
///
/// 用户对这类子页面的要求很明确 ✓：可以套用**标准页壳（头部栏 + 主体窗体）** ✓，
/// 但**标题不许重复** ✗ —— 所以这里标题只由页壳给一次 ✓，
/// 主体里**没有**再写一遍艺人名或"热门歌曲"的大标题 ✓（那正是之前的问题 ✓）。
class ArtistHotSongsPage extends StatelessWidget {
  const ArtistHotSongsPage({super.key, required this.artist});

  final OnlineArtist artist;

  @override
  Widget build(BuildContext context) {
    final songs = artist.hotSongs;
    return PageScaffold(
      // 标题只在这里出现一次 ✓（主体不再重复 ✓）。
      title: '热门歌曲',
      subtitle:
          '${artist.name} · 来源：${musicPlatformLabel(artist.platform)} · '
          '共 ${songs.length} 首',
      body: ListView(
        padding: const EdgeInsets.only(bottom: Spacing.bottomNav),
        children: [
          if (songs.isEmpty)
            const InlineEmptyHint(
              icon: Symbols.music_off,
              message: '该艺人暂时没有热门曲目。',
            )
          else
            for (final track in songs)
              OnlineTrackEntry(
                track: track,
                onTap: () => playOnlineTrackSelection(
                  context,
                  OnlineTrackSelection.fromResultPage(
                    tracks: songs,
                    selectedRef: track.ref,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
