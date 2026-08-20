import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/remote_cover_cache.dart';
import 'package:pure_music/component/remote_media_cover.dart';

void main() {
  test('remote cover URI accepts only HTTPS with a host', () {
    expect(
      resolveRemoteMediaCoverUri(
        Uri.parse('https://cover.invalid/artwork.jpg'),
      ),
      Uri.parse('https://cover.invalid/artwork.jpg'),
    );
    expect(resolveRemoteMediaCoverUri(null), isNull);
    expect(resolveRemoteMediaCoverUri(Uri()), isNull);
    expect(
      resolveRemoteMediaCoverUri(Uri.parse('http://cover.invalid/a.jpg')),
      isNull,
    );
    expect(
      resolveRemoteMediaCoverUri(Uri.parse('file:///local/cover.jpg')),
      isNull,
    );
    expect(
      resolveRemoteMediaCoverUri(Uri.parse('https:///missing-host.jpg')),
      isNull,
    );
  });

  test('remote cover provider applies bounded decode dimensions', () {
    final provider = remoteMediaCoverImageProvider(
      coverUri: Uri.parse('https://cover.invalid/artwork.jpg'),
      cacheWidth: 192,
      cacheHeight: 256,
    );

    expect(provider, isA<ResizeImage>());
    final resized = provider! as ResizeImage;
    expect(resized.width, 192);
    expect(resized.height, 256);
    expect(resized.imageProvider, isA<CachedRemoteImageProvider>());

    final memoryProvider = remoteMediaCoverImageProvider(
      coverUri: Uri.parse('https://cover.invalid/artwork.jpg'),
      imageBytes: Uint8List.fromList([1, 2, 3]),
      cacheWidth: 192,
      cacheHeight: 256,
    );
    expect(memoryProvider, isA<ResizeImage>());
    expect((memoryProvider! as ResizeImage).imageProvider, isA<MemoryImage>());
  });

  test('cover bytes cache fetches each URL once', () async {
    final cache = RemoteCoverBytesCache();
    var fetchCount = 0;
    Future<Uint8List> fetch() async {
      fetchCount++;
      return Uint8List.fromList([1, 2, 3]);
    }

    final first = await cache.load('https://cover.invalid/a.jpg', fetch);
    final second = await cache.load('https://cover.invalid/a.jpg', fetch);
    expect(fetchCount, 1);
    expect(first, second);
  });

  test('cover bytes cache dedupes concurrent fetches', () async {
    final cache = RemoteCoverBytesCache();
    var fetchCount = 0;
    Future<Uint8List> fetch() async {
      fetchCount++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return Uint8List.fromList([4, 5, 6]);
    }

    final results = await Future.wait([
      cache.load('https://cover.invalid/b.jpg', fetch),
      cache.load('https://cover.invalid/b.jpg', fetch),
    ]);
    expect(fetchCount, 1);
    expect(results[0], results[1]);
  });

  testWidgets('missing or invalid cover displays only the placeholder', (
    tester,
  ) async {
    const placeholderKey = Key('remote-cover-placeholder');

    for (final coverUri in <Uri?>[
      null,
      Uri.parse('http://cover.invalid/artwork.jpg'),
      Uri.parse('not-a-uri'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteMediaCover(
            coverUri: coverUri,
            cacheWidth: 96,
            cacheHeight: 96,
            placeholder: const SizedBox(key: placeholderKey),
          ),
        ),
      );

      expect(find.byKey(placeholderKey), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    }
  });

  testWidgets('failed HTTPS load returns to the placeholder', (tester) async {
    const placeholderKey = Key('failed-remote-cover-placeholder');

    await tester.pumpWidget(
      MaterialApp(
        home: RemoteMediaCover(
          coverUri: Uri.parse('https://cover.invalid/missing.jpg'),
          cacheWidth: 96,
          cacheHeight: 96,
          placeholder: const SizedBox(key: placeholderKey),
        ),
      ),
    );

    expect(find.byKey(placeholderKey), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.excludeFromSemantics, isTrue);
  });
}
