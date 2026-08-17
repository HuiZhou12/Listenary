import 'package:flutter/material.dart';

@visibleForTesting
Uri? resolveRemoteMediaCoverUri(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

@visibleForTesting
ImageProvider<Object>? remoteMediaCoverImageProvider({
  required String? coverUri,
  required int cacheWidth,
  required int cacheHeight,
}) {
  final uri = resolveRemoteMediaCoverUri(coverUri);
  if (uri == null) return null;
  return ResizeImage.resizeIfNeeded(
    cacheWidth,
    cacheHeight,
    NetworkImage(uri.toString()),
  );
}

class RemoteMediaCover extends StatelessWidget {
  const RemoteMediaCover({
    super.key,
    required this.coverUri,
    required this.placeholder,
    required this.cacheWidth,
    required this.cacheHeight,
    this.fit = BoxFit.cover,
    this.filterQuality = FilterQuality.medium,
  }) : assert(cacheWidth > 0),
       assert(cacheHeight > 0);

  final String? coverUri;
  final Widget placeholder;
  final int cacheWidth;
  final int cacheHeight;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    final provider = remoteMediaCoverImageProvider(
      coverUri: coverUri,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
    if (provider == null) return placeholder;

    return Image(
      image: provider,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: filterQuality,
      excludeFromSemantics: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return placeholder;
      },
      errorBuilder: (context, error, stackTrace) => placeholder,
    );
  }
}
