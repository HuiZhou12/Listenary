import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pure_music/component/remote_cover_cache.dart';

@visibleForTesting
Uri? resolveRemoteMediaCoverUri(Uri? uri) {
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri;
}

@visibleForTesting
ImageProvider<Object>? remoteMediaCoverImageProvider({
  required Uri? coverUri,
  Uint8List? imageBytes,
  required int cacheWidth,
  required int cacheHeight,
}) {
  if (imageBytes != null && imageBytes.isNotEmpty) {
    return ResizeImage.resizeIfNeeded(
      cacheWidth,
      cacheHeight,
      MemoryImage(imageBytes),
    );
  }
  final uri = resolveRemoteMediaCoverUri(coverUri);
  if (uri == null) return null;
  return ResizeImage.resizeIfNeeded(
    cacheWidth,
    cacheHeight,
    CachedRemoteImageProvider(uri.toString()),
  );
}

class RemoteMediaCover extends StatelessWidget {
  const RemoteMediaCover({
    super.key,
    required this.coverUri,
    this.imageBytes,
    required this.placeholder,
    required this.cacheWidth,
    required this.cacheHeight,
    this.fit = BoxFit.cover,
    this.filterQuality = FilterQuality.medium,
  }) : assert(cacheWidth > 0),
       assert(cacheHeight > 0);

  final Uri? coverUri;
  final Uint8List? imageBytes;
  final Widget placeholder;
  final int cacheWidth;
  final int cacheHeight;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    final provider = remoteMediaCoverImageProvider(
      coverUri: coverUri,
      imageBytes: imageBytes,
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
