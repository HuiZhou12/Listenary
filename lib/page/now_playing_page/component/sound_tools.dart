import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/menu_styles.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/page/now_playing_page/component/equalizer_dialog.dart';
import 'package:pure_music/page/now_playing_page/component/pitch_control.dart';
import 'package:pure_music/play_service/active_playback_session.dart';
import 'package:pure_music/play_service/play_service.dart';

@visibleForTesting
bool shouldShowNowPlayingSoundTools(ActivePlaybackSessionSnapshot snapshot) =>
    snapshot.source == ActivePlaybackSessionSource.local &&
    snapshot.currentItem != null;

class NowPlayingSoundTools extends StatelessWidget {
  const NowPlayingSoundTools({super.key});

  @override
  Widget build(BuildContext context) {
    final visible = context.select<ActivePlaybackSession, bool>(
      (session) => shouldShowNowPlayingSoundTools(session.value),
    );
    if (!visible) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final useMonet = AppSettings.instance.useMaterialYouForControls;
    final foreground = useMonet ? scheme.primary : scheme.onSurface;
    final panelWidth = (MediaQuery.sizeOf(context).width - 64.0)
        .clamp(280.0, 340.0)
        .toDouble();
    final playbackService = PlayService.instance.playbackService;

    return MenuAnchor(
      style: appMenuStyle,
      builder: (context, controller, _) => IconButton(
        tooltip: '声音工具',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Symbols.tune),
        color: foreground,
      ),
      menuChildren: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: SizedBox(
            width: panelWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ValueListenableBuilder(
                  valueListenable: playbackService.wasapiExclusive,
                  builder: (context, exclusive, _) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('WASAPI 独占'),
                    subtitle: Text(exclusive ? '独占输出' : '共享输出'),
                    value: exclusive,
                    onChanged: playbackService.useExclusiveMode,
                  ),
                ),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => const EqualizerDialog(),
                    );
                  },
                  icon: const Icon(Symbols.graphic_eq),
                  label: const Text('均衡器'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(40),
                    shape: RoundedRectangleBorder(
                      borderRadius: AppRadius.smCircular,
                    ),
                  ),
                ),
                const Divider(height: 28),
                NowPlayingPitchPanel(width: panelWidth),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
