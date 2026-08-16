import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/component/online_search_launcher.dart';
import 'package:pure_music/page/page_scaffold.dart';

class OnlineMusicPage extends StatelessWidget {
  const OnlineMusicPage({super.key, this.onSearch});

  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PageScaffold(
      title: '在线音乐',
      actions: [
        FilledButton.icon(
          onPressed:
              onSearch ??
              () => showApplicationSearch(context, initialOnline: true),
          icon: const Icon(Symbols.search),
          label: const Text('搜索在线音乐'),
        ),
      ],
      body: Center(
        child: Icon(
          Symbols.cloud,
          size: 48.0,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
