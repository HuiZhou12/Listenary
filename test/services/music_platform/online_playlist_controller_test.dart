import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/core/database.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';
import 'package:pure_music/services/music_platform/online_music_error.dart';
import 'package:pure_music/services/music_platform/online_music_request.dart';
import 'package:pure_music/services/music_platform/online_music_service.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database database;
  late OnlineLibraryRepository repository;
  late _FakeOnlineMusicService service;
  late OnlinePlaylistController controller;

  setUp(() {
    database = sqlite3.openInMemory();
    initializeAppDatabase(database);
    repository = OnlineLibraryRepository(database);
    service = _FakeOnlineMusicService();
    controller = OnlinePlaylistController(
      repository: Future.value(repository),
      service: service,
    );
  });

  tearDown(() {
    controller.dispose();
    database.dispose();
  });

  test('★ 远端 id 的形状由 Provider 决定：字母数字 id 不再被本地校验拒掉', () async {
    // 这条是回归守卫。原先这里只接受 `^[1-9][0-9]*$`（纯数字），
    // 于是"用字母数字 id 的 Provider"**根本无法订阅**，而且那句校验写在 try 之外，
    // 抛出的 ArgumentError 不会被转成失败 —— 会直接冲到界面上的点击回调里。
    service.nextPlaylist = _playlist();

    final saved = await controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: 'abc-123_XYZ',
    );

    expect(saved, isNotNull, reason: 'id 形状不该由这一层规定');
    expect(service.requestedPlaylistIds, ['abc-123_XYZ']);
    expect(controller.snapshot.errorMessage, isNull);
  });

  test('★ **Provider 返回的**远端 id 是字母数字时也要存得进去（取回 ≠ 存下）', () async {
    // 这条是 R25 那条测试的补丁：上一条只断言了**请求**用的 id，
    // 而"存库"这一层校验的是**Provider 返回的** `playlist.id` —— 两处是**独立的假设**。
    // 上一条的替身返回的是数字 id（`500`），所以它当时是绿的，**却漏掉了存不进去这件事**。
    service.nextPlaylist = _playlist(id: 'abc-123_XYZ');

    final saved = await controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: 'abc-123_XYZ',
    );

    expect(saved, isNotNull, reason: '取回了就必须存得下');
    expect(
      repository.readSubscriptionSnapshot(saved!.localId)!.playlist.id,
      'abc-123_XYZ',
      reason: '远端 id 必须原样保留（统一内容身份的一部分）',
    );
  });

  test('★ 空 id：**优雅失败**（返回 null + 错误信息），不抛异常', () async {
    service.nextPlaylist = _playlist();

    final saved = await controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '   ',
    );

    expect(saved, isNull);
    expect(controller.snapshot.errorMessage, '歌单 ID 不能为空');
    // 空 id 不该被发出去。
    expect(service.requestedPlaylistIds, isEmpty);
  });

  test(
    'adds a playlist and returns a provider-neutral playback selection',
    () async {      service.nextPlaylist = _playlist();

      final saved = await controller.addOrRefresh(
        platform: MusicPlatform.netease,
        remotePlaylistId: '500',
      );
      final selection = await controller.playbackSelection(
        localId: saved!.localId,
        selectedRef: _ref('200'),
      );

      expect(controller.snapshot.status, OnlinePlaylistLoadStatus.ready);
      expect(controller.snapshot.subscriptions, hasLength(1));
      expect(selection!.selectedIndex, 1);
      expect(selection.tracks.map((track) => track.ref.trackId), [
        '100',
        '200',
      ]);
    },
  );

  test('keeps the previous snapshot when refresh fails', () async {
    service.nextPlaylist = _playlist();
    final saved = await controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '500',
    );
    service.error = const OnlineMusicException(
      kind: OnlineMusicErrorKind.network,
      safeMessage: '网络不可用',
    );

    final refreshed = await controller.refresh(saved!.localId);

    expect(refreshed, isNull);
    expect(controller.snapshot.status, OnlinePlaylistLoadStatus.failed);
    expect(controller.snapshot.subscriptions.single.playlist.name, 'Remote');
    expect(repository.readSubscriptionSnapshot(saved.localId), isNotNull);
  });

  test('ignores a stale request after a newer refresh starts', () async {
    final first = Completer<RemotePlaylist>();
    service.pending.add(first);
    final firstRequest = controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '500',
    );
    await Future<void>.delayed(Duration.zero);

    service.nextPlaylist = _playlist(name: 'Second');
    final secondRequest = controller.addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: '500',
    );
    final second = await secondRequest;
    first.complete(_playlist(name: 'First'));
    final ignored = await firstRequest;

    expect(second!.playlist.name, 'Second');
    expect(ignored, isNull);
    expect(controller.snapshot.subscriptions.single.playlist.name, 'Second');
  });
}

final class _FakeOnlineMusicService implements OnlineMusicService {
  @override
  Future<List<OnlineArtistSummary>> fetchFollowedArtists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Followed artists are not implemented here');

  @override
  Future<List<RemotePlaylistSummary>> fetchRecommendedPlaylists({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended playlists are not implemented here');

  @override
  Future<List<MusicTrack>> fetchRecommendedTracks({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Recommended tracks are not implemented here');

  @override
  Future<List<OnlineArtistSummary>> searchArtists({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> searchAlbums({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album search is not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchNewAlbums({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('New albums are not implemented here');
  @override
  Future<List<MusicTrack>> fetchArtistSongs({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist songs are not implemented here');
  @override
  Future<List<OnlineAlbumSummary>> fetchArtistAlbums({
    required MusicPlatform platform,
    required String artistId,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist albums are not implemented here');
  @override
  Future<OnlineAlbum> fetchAlbum({
    required MusicPlatform platform,
    required String albumId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Album detail is not implemented here');
  @override
  Future<OnlineArtist> fetchArtist({
    required MusicPlatform platform,
    required String artistId,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('Artist detail is not implemented here');
  final pending = <Completer<RemotePlaylist>>[];
  RemotePlaylist? nextPlaylist;
  Object? error;

  /// 记录每次真的发给 Provider 的 playlistId（用来验证"本地不再按形状拦 id"）。
  final requestedPlaylistIds = <String>[];

  @override
  final capabilities = OnlineMusicCapabilities(
    searchablePlatforms: [],
    resolvablePlatforms: [MusicPlatform.netease],
    playlistPlatforms: [MusicPlatform.netease],
  );

  @override
  Future<MusicSearchPage> search({
    required MusicPlatform platform,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('search');

  @override
  Future<ResolvedStream> resolve(
    PlatformTrackRef ref, {
    required String requestedQuality,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('resolve');

  @override
  Future<RemotePlaylist> fetchPlaylist({
    required MusicPlatform platform,
    required String playlistId,
    required OnlineMusicCancelToken cancelToken,
  }) async {
    requestedPlaylistIds.add(playlistId);
    if (pending.isNotEmpty) return pending.removeAt(0).future;
    final failure = error;
    if (failure != null) throw failure;
    return nextPlaylist!;
  }

  @override
  Future<List<RemotePlaylistSummary>> fetchPlaylistCollection({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    String? categoryId,
    required OnlineMusicCancelToken cancelToken,
  }) async => const [];

  @override
  Future<List<RemotePlaylistCategory>> fetchPlaylistCategories({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('categories');

  @override
  Future<List<RemotePlaylistSummary>> fetchChartList({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('charts');

  @override
  Future<List<MusicTrack>> fetchNewSongs({
    required MusicPlatform platform,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('new songs');

  @override
  Future<MusicLyrics> fetchLyrics(
    PlatformTrackRef ref, {
    required OnlineMusicCancelToken cancelToken,
  }) => throw UnsupportedError('lyrics');

  @override
  String defaultQualityFor(MusicPlatform platform) => 'lossless';

  @override
  Future<AggregatedSearchResult> searchAggregated({
    required Iterable<MusicPlatform> platforms,
    required String keyword,
    int limit = 30,
    int offset = 0,
    required OnlineMusicCancelToken cancelToken,
  }) async => AggregatedSearchResult(perPlatform: const {}, failures: const {});

  @override
  List<PlatformQualityTier> qualityTiersFor(MusicPlatform platform) => const [];

  @override
  PlatformQualitySelection selectQualityFor(
    MusicPlatform platform, {
    required String preference,
  }) => PlatformQualitySelection(
    requestValue: preference,
    displayLabel: preference,
    internalLevel: preference,
  );

  @override
  void dispose() {}
}

PlatformTrackRef _ref(String id) =>
    PlatformTrackRef(platform: MusicPlatform.netease, trackId: id);

MusicTrack _track(String id, String title) =>
    MusicTrack(ref: _ref(id), title: title, artists: const ['Artist']);

RemotePlaylist _playlist({String name = 'Remote', String id = '500'}) =>
    RemotePlaylist(
      platform: MusicPlatform.netease,
      id: id,
      name: name,
      trackCount: 2,
      tracks: [_track('100', 'First'), _track('200', 'Second')],
    );
