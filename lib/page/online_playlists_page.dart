import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:pure_music/component/danger_confirm_dialog.dart';
import 'package:pure_music/component/motion.dart';
import 'package:pure_music/component/quiet_empty_state.dart';
import 'package:pure_music/component/remote_media_cover.dart';
import 'package:pure_music/core/design_tokens.dart';
import 'package:pure_music/core/paths.dart' as app_paths;
import 'package:pure_music/core/utils.dart';
import 'package:pure_music/page/page_scaffold.dart';
import 'package:pure_music/services/music_platform/models/music_models.dart';
import 'package:pure_music/services/music_platform/online_library/online_library_repository.dart';
import 'package:pure_music/services/music_platform/online_library/online_playlist_controller.dart';

class OnlinePlaylistsPage extends StatefulWidget {
  const OnlinePlaylistsPage({super.key});

  @override
  State<OnlinePlaylistsPage> createState() => _OnlinePlaylistsPageState();
}

class _OnlinePlaylistsPageState extends State<OnlinePlaylistsPage> {
  final Set<int> _busy = <int>{};
  bool _adding = false;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<OnlinePlaylistController>().loadSubscriptions();
    });
  }

  Future<void> _addPlaylist() async {
    if (_adding) return;
    final id = await showDialog<String>(
      context: context,
      builder: (context) => const _OnlinePlaylistIdDialog(),
    );
    if (id == null || !mounted) return;
    setState(() => _adding = true);
    final result = await context.read<OnlinePlaylistController>().addOrRefresh(
      platform: MusicPlatform.netease,
      remotePlaylistId: id,
    );
    if (!mounted) return;
    setState(() => _adding = false);
    if (result == null) {
      showTextOnSnackBar(
        context.read<OnlinePlaylistController>().snapshot.errorMessage ??
            '无法添加在线歌单',
        variant: ToastVariant.error,
      );
    } else {
      showTextOnSnackBar('在线歌单已保存', variant: ToastVariant.success);
    }
  }

  Future<void> _refresh(OnlinePlaylistSnapshot item) async {
    if (_busy.contains(item.localId)) return;
    setState(() => _busy.add(item.localId));
    final result = await context.read<OnlinePlaylistController>().refresh(
      item.localId,
    );
    if (!mounted) return;
    setState(() => _busy.remove(item.localId));
    if (result == null) {
      showTextOnSnackBar(
        context.read<OnlinePlaylistController>().snapshot.errorMessage ??
            '无法刷新在线歌单',
        variant: ToastVariant.error,
      );
    } else {
      showTextOnSnackBar('在线歌单已刷新', variant: ToastVariant.success);
    }
  }

  Future<void> _delete(OnlinePlaylistSnapshot item) async {
    if (_busy.contains(item.localId)) return;
    final confirmed = await showDangerConfirmDialog(
      context: context,
      title: '删除在线歌单？',
      message: '只会删除本机保存的订阅，不会影响第三方平台。',
      confirmLabel: '删除',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy.add(item.localId));
    final deleted = await context.read<OnlinePlaylistController>().delete(
      platform: item.playlist.platform,
      remotePlaylistId: item.playlist.id,
    );
    if (!mounted) return;
    setState(() => _busy.remove(item.localId));
    showTextOnSnackBar(
      deleted ? '在线歌单已删除' : '删除在线歌单失败',
      variant: deleted ? ToastVariant.success : ToastVariant.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = context.watch<OnlinePlaylistController>().snapshot;
    final items = snapshot.subscriptions;
    return PageScaffold(
      title: '在线歌单',
      subtitle: '${items.length} 个订阅',
      actions: [
        IconButton.filledTonal(
          tooltip: '添加在线歌单',
          onPressed: _adding ? null : _addPlaylist,
          icon: _adding
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Symbols.add),
        ),
      ],
      body: _buildBody(snapshot),
    );
  }

  Widget _buildBody(OnlinePlaylistViewSnapshot snapshot) {
    if (snapshot.status == OnlinePlaylistLoadStatus.loading &&
        snapshot.subscriptions.isEmpty) {
      return const Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (snapshot.subscriptions.isEmpty) {
      return QuietEmptyState(
        icon: snapshot.status == OnlinePlaylistLoadStatus.failed
            ? Symbols.cloud_off
            : Symbols.playlist_add,
        title: snapshot.status == OnlinePlaylistLoadStatus.failed
            ? '在线歌单读取失败'
            : '还没有在线歌单',
        message: snapshot.status == OnlinePlaylistLoadStatus.failed
            ? snapshot.errorMessage ?? '请稍后重试。'
            : '添加网易歌单 ID 后即可离线查看快照。',
        action: FilledButton.tonalIcon(
          onPressed: _adding ? null : _addPlaylist,
          icon: const Icon(Symbols.add),
          label: const Text('添加在线歌单'),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: snapshot.subscriptions.length,
      itemBuilder: (context, index) {
        final item = snapshot.subscriptions[index];
        final busy = _busy.contains(item.localId);
        final creator = item.playlist.creator;
        final count = item.playlist.trackCount;
        final details = [
          if (creator != null && creator.isNotEmpty) creator,
          if (count != null) '$count 首歌曲',
          if (item.lastRefreshedAt != null)
            '更新于 ${_formatDate(item.lastRefreshedAt!)}',
        ].join(' · ');
        return DirectionalListItemEntrance(
          identity: item.localId,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: SizedBox(
              height: 72,
              child: Material(
                type: MaterialType.transparency,
                borderRadius: AppRadius.smCircular,
                child: InkWell(
                  borderRadius: AppRadius.smCircular,
                  onTap: busy
                      ? null
                      : () => context.push(
                          app_paths.ONLINE_PLAYLIST_DETAIL_PAGE,
                          extra: item.localId,
                        ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        _OnlinePlaylistCover(uri: item.playlist.coverUri),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.playlist.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: AppType.subtitle,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                details.isEmpty ? '网易 · 在线订阅' : details,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新',
                          onPressed: busy ? null : () => _refresh(item),
                          icon: busy
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Symbols.refresh),
                        ),
                        IconButton(
                          tooltip: '删除',
                          onPressed: busy ? null : () => _delete(item),
                          color: Theme.of(context).colorScheme.error,
                          icon: const Icon(Symbols.delete),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OnlinePlaylistCover extends StatelessWidget {
  const _OnlinePlaylistCover({required this.uri});

  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: AppRadius.smCircular,
      child: SizedBox.square(
        dimension: 48,
        child: RemoteMediaCover(
          coverUri: uri,
          placeholder: ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Icon(Symbols.cloud, color: scheme.onSurfaceVariant),
          ),
          cacheWidth: 96,
          cacheHeight: 96,
        ),
      ),
    );
  }
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

class _OnlinePlaylistIdDialog extends StatefulWidget {
  const _OnlinePlaylistIdDialog();

  @override
  State<_OnlinePlaylistIdDialog> createState() => _OnlinePlaylistIdDialogState();
}

class _OnlinePlaylistIdDialogState extends State<_OnlinePlaylistIdDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(value)) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加在线歌单'),
      content: TextField(
        autofocus: true,
        controller: _controller,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '网易歌单 ID',
          hintText: '输入数字 ID',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
