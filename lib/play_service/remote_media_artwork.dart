import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pure_music/native/rust/api/color_extraction.dart';

const _maxArtworkBytes = 8 * 1024 * 1024;
const _maxArtworkCacheEntries = 6;
const _maxRedirects = 5;
const _requestTimeout = Duration(seconds: 8);
const _bodyTimeout = Duration(seconds: 10);

enum RemoteMediaArtworkStatus { empty, loading, ready, unavailable }

@immutable
final class RemoteMediaArtworkSnapshot {
  const RemoteMediaArtworkSnapshot._({
    required this.revision,
    required this.status,
    this.bytes,
    this.palette = const [],
  });

  const RemoteMediaArtworkSnapshot.empty()
    : this._(revision: null, status: RemoteMediaArtworkStatus.empty);

  const RemoteMediaArtworkSnapshot.loading({required int revision})
    : this._(revision: revision, status: RemoteMediaArtworkStatus.loading);

  const RemoteMediaArtworkSnapshot.unavailable({required int revision})
    : this._(
        revision: revision,
        status: RemoteMediaArtworkStatus.unavailable,
      );

  RemoteMediaArtworkSnapshot.ready({
    required int revision,
    required Uint8List bytes,
    required Iterable<Color> palette,
  }) : this._(
         revision: revision,
         status: RemoteMediaArtworkStatus.ready,
         bytes: Uint8List.fromList(bytes),
         palette: List.unmodifiable(palette),
       );

  final int? revision;
  final RemoteMediaArtworkStatus status;
  final Uint8List? bytes;
  final List<Color> palette;

  bool get hasArtwork => status == RemoteMediaArtworkStatus.ready;

  @override
  String toString() =>
      'RemoteMediaArtworkSnapshot(revision: $revision, status: $status, '
      'bytes: ${bytes?.length ?? 0}, palette: ${palette.length})';
}

typedef RemoteMediaArtworkLoader = Future<Uint8List> Function(Uri uri);
typedef RemoteMediaArtworkPaletteExtractor = Future<List<Color>> Function(
  Uint8List bytes,
);

@visibleForTesting
Future<List<Color>> extractRemoteMediaArtworkPalette(Uint8List bytes) async {
  final colors = await extractColorsFromImage(
    imageBytes: bytes,
    numColors: 4,
  );
  return colors.map(Color.new).toList(growable: false);
}

@visibleForTesting
Future<Uint8List> loadRemoteMediaArtwork(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = _requestTimeout
    ..idleTimeout = _bodyTimeout;
  try {
    var current = uri;
    for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
      final request = await client.getUrl(current).timeout(_requestTimeout);
      request.followRedirects = false;
      final response = await request.close().timeout(_requestTimeout);
      if (_isRedirect(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirect == _maxRedirects) {
          throw const FormatException('remote artwork redirect rejected');
        }
        final next = current.resolve(location);
        if (next.scheme != 'https' || next.host.isEmpty) {
          throw const FormatException('remote artwork redirect rejected');
        }
        current = next;
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('remote artwork request failed');
      }
      final declaredLength = response.contentLength;
      if (declaredLength > _maxArtworkBytes) {
        throw const FormatException('remote artwork is too large');
      }

      final builder = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.timeout(_bodyTimeout)) {
        length += chunk.length;
        if (length > _maxArtworkBytes) {
          throw const FormatException('remote artwork is too large');
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    }
    throw const FormatException('remote artwork redirect rejected');
  } finally {
    client.close(force: true);
  }
}

bool _isRedirect(int statusCode) =>
    statusCode == HttpStatus.movedPermanently ||
    statusCode == HttpStatus.found ||
    statusCode == HttpStatus.seeOther ||
    statusCode == HttpStatus.temporaryRedirect ||
    statusCode == HttpStatus.permanentRedirect;

final class RemoteMediaArtworkController
    extends ValueNotifier<RemoteMediaArtworkSnapshot> {
  RemoteMediaArtworkController({
    RemoteMediaArtworkLoader? load,
    RemoteMediaArtworkPaletteExtractor? extractPalette,
  }) : _load = load ?? loadRemoteMediaArtwork,
       _extractPalette = extractPalette ?? extractRemoteMediaArtworkPalette,
       super(const RemoteMediaArtworkSnapshot.empty());

  final RemoteMediaArtworkLoader _load;
  final RemoteMediaArtworkPaletteExtractor _extractPalette;
  final Map<Uri, RemoteMediaArtworkMaterial> _cache = {};
  final Map<Uri, Future<RemoteMediaArtworkMaterial>> _inFlight = {};
  _RemoteMediaArtworkKey? _activeKey;
  int _generation = 0;
  bool _disposed = false;

  void synchronizeRemote({required int revision, required Uri? coverUri}) {
    _throwIfDisposed();
    final uri = _validatedUri(coverUri);
    if (uri == null) {
      _activeKey = null;
      _generation++;
      if (value.status != RemoteMediaArtworkStatus.unavailable ||
          value.revision != revision) {
        value = RemoteMediaArtworkSnapshot.unavailable(revision: revision);
      }
      return;
    }
    final key = _RemoteMediaArtworkKey(revision, uri);
    if (key == _activeKey) return;
    _activeKey = key;
    final generation = ++_generation;

    final cached = _cache[uri];
    if (cached != null) {
      _touchCache(uri);
      value = RemoteMediaArtworkSnapshot.ready(
        revision: revision,
        bytes: cached.bytes,
        palette: cached.palette,
      );
      return;
    }

    value = RemoteMediaArtworkSnapshot.loading(revision: revision);
    final future = _inFlight[uri] ??= _loadMaterial(uri);
    future.then((material) {
      if (identical(_inFlight[uri], future)) _inFlight.remove(uri);
      if (_disposed) {
        return;
      }
      _cache[uri] = material;
      _trimCache(uri);
      if (generation != _generation || key != _activeKey) return;
      value = RemoteMediaArtworkSnapshot.ready(
        revision: revision,
        bytes: material.bytes,
        palette: material.palette,
      );
    }, onError: (_, _) {
      if (identical(_inFlight[uri], future)) _inFlight.remove(uri);
      if (_disposed || generation != _generation || key != _activeKey) {
        return;
      }
      value = RemoteMediaArtworkSnapshot.unavailable(revision: revision);
    });
  }

  void clear() {
    if (_disposed) return;
    _activeKey = null;
    _generation++;
    if (value.status != RemoteMediaArtworkStatus.empty) {
      value = const RemoteMediaArtworkSnapshot.empty();
    }
  }

  Future<RemoteMediaArtworkMaterial> _loadMaterial(Uri uri) async {
    final loaded = await _load(uri);
    if (loaded.isEmpty || loaded.length > _maxArtworkBytes) {
      throw const FormatException('remote artwork is invalid');
    }
    final bytes = Uint8List.fromList(loaded);
    List<Color> palette;
    try {
      palette = await _extractPalette(bytes);
    } catch (_) {
      palette = const [];
    }
    return RemoteMediaArtworkMaterial(bytes: bytes, palette: palette);
  }

  void _trimCache(Uri newest) {
    _touchCache(newest);
    while (_cache.length > _maxArtworkCacheEntries) {
      final oldest = _cache.keys.first;
      if (oldest == newest && _cache.length > 1) {
        final next = _cache.keys.elementAt(1);
        _cache.remove(next);
      } else {
        _cache.remove(oldest);
      }
    }
  }

  void _touchCache(Uri uri) {
    final material = _cache.remove(uri);
    if (material != null) _cache[uri] = material;
  }

  static Uri? _validatedUri(Uri? uri) {
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('RemoteMediaArtworkController disposed');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activeKey = null;
    _generation++;
    _cache.clear();
    _inFlight.clear();
    super.dispose();
  }
}

@immutable
final class RemoteMediaArtworkMaterial {
  RemoteMediaArtworkMaterial({
    required Uint8List bytes,
    required Iterable<Color> palette,
  }) : bytes = Uint8List.fromList(bytes),
       palette = List.unmodifiable(palette);

  final Uint8List bytes;
  final List<Color> palette;
}

@immutable
final class _RemoteMediaArtworkKey {
  const _RemoteMediaArtworkKey(this.revision, this.uri);

  final int revision;
  final Uri uri;

  @override
  bool operator ==(Object other) =>
      other is _RemoteMediaArtworkKey &&
      revision == other.revision &&
      uri == other.uri;

  @override
  int get hashCode => Object.hash(revision, uri);
}
