import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/core/design_tokens.dart';

class CollectPlaylistChoice<T> {
  const CollectPlaylistChoice({
    required this.value,
    required this.name,
    required this.trackCount,
    this.alreadyContained = false,
  });

  final T value;
  final String name;
  final int trackCount;
  final bool alreadyContained;
}

/// 居中「收藏到歌单」弹窗，格式以本地「新建歌单」弹窗为地基。
/// 选择或新建成功时返回对应 value，取消返回 null。
Future<T?> showCollectPlaylistDialog<T>({
  required BuildContext context,
  required String title,
  required List<CollectPlaylistChoice<T>> choices,
  required Future<T?> Function(String name) onCreate,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) => _CollectPlaylistDialog<T>(
      title: title,
      choices: choices,
      onCreate: onCreate,
    ),
  );
}

class _CollectPlaylistDialog<T> extends StatefulWidget {
  const _CollectPlaylistDialog({
    required this.title,
    required this.choices,
    required this.onCreate,
  });

  final String title;
  final List<CollectPlaylistChoice<T>> choices;
  final Future<T?> Function(String name) onCreate;

  @override
  State<_CollectPlaylistDialog<T>> createState() =>
      _CollectPlaylistDialogState<T>();
}

class _CollectPlaylistDialogState<T> extends State<_CollectPlaylistDialog<T>> {
  final TextEditingController _nameController = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() => _creating = true);
    final value = await widget.onCreate(name);
    if (!mounted) return;
    setState(() => _creating = false);
    if (value != null) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = (MediaQuery.sizeOf(context).width - 48.0)
        .clamp(320.0, 420.0)
        .toDouble();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 24.0,
      ),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdCircular),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: TextStyle(
                  color: scheme.onSurface,
                  fontSize: AppType.sectionTitle,
                  fontWeight: AppType.weightBold,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameController,
                autofocus: true,
                onSubmitted: (_) => _create(),
                decoration: const InputDecoration(
                  labelText: '新建歌单名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              if (widget.choices.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                  child: Text(
                    '还没有可添加的歌单，输入名称新建一个。',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: widget.choices.length,
                    itemBuilder: (context, index) {
                      final choice = widget.choices[index];
                      return ListTile(
                        dense: true,
                        title: Text(choice.name),
                        leading: choice.alreadyContained
                            ? Icon(Symbols.check, color: scheme.primary)
                            : null,
                        trailing: Text(
                          '${choice.trackCount} 首',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        onTap: () => Navigator.of(context).pop(choice.value),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8.0,
                overflowSpacing: 8.0,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: _creating ? null : _create,
                    child: Text(_creating ? '创建中' : '创建并添加'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
