import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';

class OnlineTrackRow extends StatelessWidget {
  const OnlineTrackRow({
    super.key,
    required this.track,
    required this.details,
    required this.enabled,
    required this.onTap,
  });

  final MusicTrack track;
  final String details;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final titleColor = enabled ? scheme.onSurface : scheme.onSurfaceVariant;
    final metadataColor = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.55);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
      child: SizedBox(
        height: 64,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: AppRadius.smCircular,
          child: InkWell(
            onTap: onTap,
            hoverColor: scheme.onSurface.withValues(alpha: Alpha.hover),
            borderRadius: AppRadius.smCircular,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
              child: Row(
                children: [
                  _OnlineTrackCover(
                    key: ValueKey('online-track-cover-${track.ref.trackId}'),
                    coverUri: track.coverUri,
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: AppType.subtitle,
                            fontWeight: AppType.weightMedium,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          details,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: metadataColor),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  if (track.duration != Duration.zero)
                    Text(
                      formatOnlineTrackDuration(track.duration),
                      style: TextStyle(color: metadataColor),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OnlineTrackCover extends StatelessWidget {
  const _OnlineTrackCover({super.key, required this.coverUri});

  final Uri? coverUri;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Icon(
        Symbols.music_note,
        size: 22,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
      ),
    );
    return ClipRRect(
      borderRadius: AppRadius.smCircular,
      child: SizedBox.square(
        dimension: 48.0,
        child: RemoteMediaCover(
          coverUri: coverUri,
          placeholder: placeholder,
          cacheWidth: 96,
          cacheHeight: 96,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

String formatOnlineTrackDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
