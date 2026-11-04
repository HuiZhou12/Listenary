import 'dart:async';
import 'dart:io';

import 'package:pure_music/core/library_db.dart';
import 'package:pure_music/core/settings.dart';
import 'package:pure_music/library/audio_library.dart';
import 'package:pure_music/library/playlist.dart';
import 'package:pure_music/lyric/lyric_source.dart';
import 'package:pure_music/native/rust/api/tag_reader.dart';
import 'package:pure_music/core/utils.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:pure_music/core/paths.dart' as app_paths;

class UpdatingPage extends StatefulWidget {
  const UpdatingPage({super.key});

  @override
  State<UpdatingPage> createState() => _UpdatingPageState();
}

class _UpdatingPageState extends State<UpdatingPage> {
  late final Future<Directory?> _appDataDirFuture;

  @override
  void initState() {
    super.initState();
    _appDataDirFuture = _getAppDataDirSafe();
  }

  Future<Directory?> _getAppDataDirSafe() async {
    try {
      return await getAppDataDir();
    } catch (e, trace) {
      logger.e('获取应用数据目录失败', error: e, stackTrace: trace);
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Center(
        child: FutureBuilder<Directory?>(
          future: _appDataDirFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Padding(
                padding: const EdgeInsets.all(32.0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: scheme.primary),
                      const SizedBox(height: 16.0),
                      Text(
                        '正在准备应用数据...',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (snapshot.hasError ||
                !snapshot.hasData ||
                snapshot.data == null) {
              return Padding(
                padding: const EdgeInsets.all(32.0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: scheme.error,
                        size: 40.0,
                      ),
                      const SizedBox(height: 12.0),
                      Text(
                        '初始化失败',
                        style: TextStyle(
                          color: scheme.error,
                          fontSize: 18.0,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8.0),
                      Text(
                        '应用数据目录不可用，请查看日志',
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16.0),
                      FilledButton.icon(
                        onPressed: () => exit(1),
                        icon: const Icon(Icons.close),
                        label: const Text('退出'),
                      ),
                    ],
                  ),
                ),
              );
            }

            return UpdatingStateView(indexPath: snapshot.data!);
          },
        ),
      ),
    );
  }
}

class UpdatingStateView extends StatefulWidget {
  const UpdatingStateView({super.key, required this.indexPath});

  final Directory indexPath;

  @override
  State<UpdatingStateView> createState() => _UpdatingStateViewState();
}

class _UpdatingStateViewState extends State<UpdatingStateView> {
  StreamSubscription<IndexActionState>? _subscription;
  IndexActionState? _latestAction;
  String? _errorMessage;

  void whenIndexUpdated() async {
    if (_errorMessage != null) return;
    try {
      await Future.wait([
        AudioLibrary.initFromIndex(),
        readPlaylists(),
        readLyricSources(),
      ]);
      pruneLyricSourcesWhereMissing(
        (path) => AudioLibrary.instance.audioByPath(path) != null,
      );
      await _subscription?.cancel();
      final ctx = context;
      if (ctx.mounted) {
        // D1（2026-11-03 已拍板）：非首启的启动落地页 = **首页**。
        // 改前这里硬编码 `AUDIOS_PAGE` ✗ —— 与 `startPage` 默认值（HOME）是两套口径；
        // `startPage` 机制本身不动（它只服务 `/` 重定向，启动流程不访问 `/`）。
        ctx.go(app_paths.HOME_PAGE);
      }
    } catch (e, trace) {
      logger.e('索引完成后读取音乐库失败', error: e, stackTrace: trace);
      if (mounted) {
        setState(() => _errorMessage = '音乐库读取失败，请查看日志');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _subscription = _startUpdate().listen(
      (action) {
        if (action.message.isNotEmpty) {
          logger.i('[update index] ${action.progress}: ${action.message}');
        }
        if (mounted) {
          setState(() => _latestAction = action);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        logger.e('更新音乐库索引失败', error: error, stackTrace: stackTrace);
        if (mounted) {
          setState(() => _errorMessage = '音乐库索引失败，请查看日志');
        }
      },
      onDone: whenIndexUpdated,
      cancelOnError: true,
    );
  }

  /// 先向 Dart 仓储取快照，再交给 Rust：SQLite 归 Dart 之后，Rust 已经没有
  /// 「上次同步进库的索引是否还新鲜」的判定能力，快照因此改成入参（Q2 裁定）。
  /// 取不到快照（库缺失 / 版本不足）时传 `null` ⇒ 走全量检查。
  Stream<IndexActionState> _startUpdate() async* {
    final snapshot = await _readSnapshot();
    yield* updateIndex(
      indexPath: widget.indexPath.path,
      forceMetadataCheck: false,
      snapshot: snapshot,
    );
  }

  Future<IndexSnapshot?> _readSnapshot() async {
    try {
      final opened = await LibraryDb.instance.initialize(
        indexDir: widget.indexPath.path,
      );
      if (!opened) return null;
      final snapshot = LibraryDb.instance.readSnapshot();
      if (snapshot == null) return null;
      return IndexSnapshot(
        version: BigInt.from(snapshot.version),
        folders: snapshot.folders
            .map(
              (folder) => IndexFolderSnapshot(
                path: folder.path,
                modified: BigInt.from(folder.modified),
              ),
            )
            .toList(growable: false),
        // `PlatformInt64` 在原生平台就是 `int`（Web 才是 BigInt）。
        indexSourceModified: snapshot.indexSourceModified,
        indexSourceSize: snapshot.indexSourceSize,
      );
    } catch (err, trace) {
      logger.w('读取索引快照失败，改为全量检查', error: err, stackTrace: trace);
      return null;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final errorMessage = _errorMessage;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420.0),
          child: errorMessage != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, color: scheme.error, size: 40.0),
                    const SizedBox(height: 12.0),
                    Text(
                      '初始化失败',
                      style: TextStyle(
                        color: scheme.error,
                        fontSize: 18.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8.0),
                    Text(
                      errorMessage,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16.0),
                    FilledButton.icon(
                      onPressed: () => exit(1),
                      icon: const Icon(Icons.close),
                      label: const Text('退出'),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LinearProgressIndicator(
                      value: _latestAction?.progress,
                      backgroundColor: scheme.onSurface.withValues(alpha: 0.1),
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(2.0),
                      minHeight: 8,
                    ),
                    const SizedBox(height: 16.0),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            _latestAction?.message ?? '正在初始化...',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (_latestAction != null) ...[
                          const SizedBox(width: 8.0),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                              vertical: 4.0,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12.0),
                            ),
                            child: Text(
                              '${(_latestAction!.progress.clamp(0.0, 1.0) * 100).round()}%',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 12.0,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
