import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/component/remote_media_cover.dart';

void main() {
  test('remote cover URI accepts only HTTPS with a host', () {
    expect(
      resolveRemoteMediaCoverUri('https://cover.invalid/artwork.jpg'),
      Uri.parse('https://cover.invalid/artwork.jpg'),
    );
    expect(resolveRemoteMediaCoverUri(null), isNull);
    expect(resolveRemoteMediaCoverUri(''), isNull);
    expect(resolveRemoteMediaCoverUri('http://cover.invalid/a.jpg'), isNull);
    expect(resolveRemoteMediaCoverUri('file:///local/cover.jpg'), isNull);
    expect(resolveRemoteMediaCoverUri('https:///missing-host.jpg'), isNull);
  });

  test('remote cover provider applies bounded decode dimensions', () {
    final provider = remoteMediaCoverImageProvider(
      coverUri: 'https://cover.invalid/artwork.jpg',
      cacheWidth: 192,
      cacheHeight: 256,
    );

    expect(provider, isA<ResizeImage>());
    final resized = provider! as ResizeImage;
    expect(resized.width, 192);
    expect(resized.height, 256);
    expect(resized.imageProvider, isA<NetworkImage>());
  });

  testWidgets('missing or invalid cover displays only the placeholder', (
    tester,
  ) async {
    const placeholderKey = Key('remote-cover-placeholder');

    for (final coverUri in <String?>[
      null,
      'http://cover.invalid/artwork.jpg',
      'not a URI',
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
      const MaterialApp(
        home: RemoteMediaCover(
          coverUri: 'https://cover.invalid/missing.jpg',
          cacheWidth: 96,
          cacheHeight: 96,
          placeholder: SizedBox(key: placeholderKey),
        ),
      ),
    );

    expect(find.byKey(placeholderKey), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.excludeFromSemantics, isTrue);
  });
}
