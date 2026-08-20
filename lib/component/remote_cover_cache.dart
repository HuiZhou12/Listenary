import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 会话级在线封面字节缓存：按 URL 缓存一次原始字节，各显示尺寸复用，
/// 避免同一封面因不同 cacheWidth 重复请求。仅存内存，随应用退出释放。
class RemoteCoverBytesCache {
  RemoteCoverBytesCache();

  static final RemoteCoverBytesCache instance = RemoteCoverBytesCache();

  static const int _maxEntries = 256;

  final Map<String, Uint8List> _bytes = {};
  final Map<String, Future<Uint8List>> _inFlight = {};

  Future<Uint8List> load(String url, Future<Uint8List> Function() fetch) {
    final cached = _bytes[url];
    if (cached != null) return SynchronousFuture(cached);
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final future = fetch().then((bytes) {
      _bytes[url] = bytes;
      _inFlight.remove(url);
      while (_bytes.length > _maxEntries) {
        _bytes.remove(_bytes.keys.first);
      }
      return bytes;
    }, onError: (Object error, StackTrace stackTrace) {
      _inFlight.remove(url);
      Error.throwWithStackTrace(error, stackTrace);
    });
    _inFlight[url] = future;
    return future;
  }
}

/// 在线封面图片提供器：经 [RemoteCoverBytesCache] 取字节并解码。
class CachedRemoteImageProvider extends ImageProvider<CachedRemoteImageProvider> {
  CachedRemoteImageProvider(this.url);

  final String url;

  @override
  Future<CachedRemoteImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    CachedRemoteImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _loadAsync(ImageDecoderCallback decode) async {
    final bytes = await RemoteCoverBytesCache.instance.load(url, _fetchBytes);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  Future<Uint8List> _fetchBytes() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('cover fetch failed (${response.statusCode})', uri: Uri.parse(url));
      }
      return await consolidateHttpClientResponseBytes(response)
          .timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CachedRemoteImageProvider && other.url == url;

  @override
  int get hashCode => Object.hash(runtimeType, url);
}
