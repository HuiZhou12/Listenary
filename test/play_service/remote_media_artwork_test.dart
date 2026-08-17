import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/remote_media_artwork.dart';

void main() {
  test('invalid cover is rejected without starting a load', () {
    var loads = 0;
    final controller = RemoteMediaArtworkController(
      load: (_) async {
        loads++;
        return Uint8List.fromList([1]);
      },
      extractPalette: (_) async => [Colors.red],
    );
    addTearDown(controller.dispose);

    controller.synchronizeRemote(
      revision: 1,
      coverUri: Uri.parse('http://cover.invalid/art.jpg'),
    );

    expect(loads, 0);
    expect(controller.value.status, RemoteMediaArtworkStatus.unavailable);
    expect(controller.value.bytes, isNull);
  });

  test('one URI shares the in-flight load and extracted material', () async {
    final loadCompleter = Completer<Uint8List>();
    var loads = 0;
    var extractions = 0;
    final controller = RemoteMediaArtworkController(
      load: (_) {
        loads++;
        return loadCompleter.future;
      },
      extractPalette: (_) async {
        extractions++;
        return [Colors.red, Colors.blue];
      },
    );
    addTearDown(controller.dispose);
    final uri = Uri.parse('https://cover.invalid/art.jpg');

    controller.synchronizeRemote(revision: 1, coverUri: uri);
    controller.synchronizeRemote(revision: 2, coverUri: uri);
    expect(loads, 1);

    loadCompleter.complete(Uint8List.fromList([1, 2, 3]));
    await pumpEventQueue();

    expect(controller.value.status, RemoteMediaArtworkStatus.ready);
    expect(controller.value.revision, 2);
    expect(controller.value.bytes, orderedEquals([1, 2, 3]));
    expect(controller.value.palette, [Colors.red, Colors.blue]);
    expect(extractions, 1);

    controller.clear();
    controller.synchronizeRemote(revision: 3, coverUri: uri);
    expect(loads, 1);
    expect(extractions, 1);
    expect(controller.value.status, RemoteMediaArtworkStatus.ready);
  });

  test('late material from a replaced track cannot overwrite the current one',
      () async {
    final first = Completer<Uint8List>();
    final second = Completer<Uint8List>();
    final controller = RemoteMediaArtworkController(
      load: (uri) => uri.path.contains('first')
          ? first.future
          : second.future,
      extractPalette: (_) async => [Colors.green],
    );
    addTearDown(controller.dispose);
    final firstUri = Uri.parse('https://cover.invalid/first.jpg');
    final secondUri = Uri.parse('https://cover.invalid/second.jpg');

    controller.synchronizeRemote(revision: 1, coverUri: firstUri);
    controller.synchronizeRemote(revision: 1, coverUri: secondUri);
    second.complete(Uint8List.fromList([2]));
    await pumpEventQueue();
    expect(controller.value.bytes, orderedEquals([2]));

    first.complete(Uint8List.fromList([1]));
    await pumpEventQueue();
    expect(controller.value.bytes, orderedEquals([2]));
    expect(controller.value.revision, 1);

    controller.synchronizeRemote(revision: 2, coverUri: firstUri);
    expect(controller.value.bytes, orderedEquals([1]));
  });

  test('palette failure does not prevent the cover from becoming visible',
      () async {
    final controller = RemoteMediaArtworkController(
      load: (_) async => Uint8List.fromList([4, 5]),
      extractPalette: (_) async => throw StateError('decode failed'),
    );
    addTearDown(controller.dispose);

    controller.synchronizeRemote(
      revision: 4,
      coverUri: Uri.parse('https://cover.invalid/art.jpg'),
    );
    await pumpEventQueue();

    expect(controller.value.status, RemoteMediaArtworkStatus.ready);
    expect(controller.value.bytes, orderedEquals([4, 5]));
    expect(controller.value.palette, isEmpty);
  });

  test('oversized material is unavailable and is not extracted', () async {
    var extractions = 0;
    final controller = RemoteMediaArtworkController(
      load: (_) async => Uint8List(8 * 1024 * 1024 + 1),
      extractPalette: (_) async {
        extractions++;
        return [Colors.red];
      },
    );
    addTearDown(controller.dispose);

    controller.synchronizeRemote(
      revision: 5,
      coverUri: Uri.parse('https://cover.invalid/large.jpg'),
    );
    await pumpEventQueue();

    expect(controller.value.status, RemoteMediaArtworkStatus.unavailable);
    expect(extractions, 0);
  });

  test('clear invalidates a late request', () async {
    final completer = Completer<Uint8List>();
    final controller = RemoteMediaArtworkController(
      load: (_) => completer.future,
      extractPalette: (_) async => [Colors.purple],
    );
    addTearDown(controller.dispose);

    controller.synchronizeRemote(
      revision: 6,
      coverUri: Uri.parse('https://cover.invalid/art.jpg'),
    );
    controller.clear();
    completer.complete(Uint8List.fromList([9]));
    await pumpEventQueue();

    expect(controller.value.status, RemoteMediaArtworkStatus.empty);
    expect(controller.value.bytes, isNull);
  });
}
