import 'package:flutter/material.dart';
import 'package:pure_music/component/online_search_panel.dart';
import 'package:pure_music/services/music_platform/index.dart';

/// 面板的测试宿主（`test/` 内部复用，不是用例文件）。
///
/// 搜索页撤销后（Spec D2），面板不再自带输入框：查询词与**显式提交**都由宿主提供。
/// 真实宿主是 `SearchDialog`；测试里用这个最小宿主，让面板测试不依赖整棵弹窗。
///
/// 对外用法：
/// - `find.byKey(onlineSearchHostFieldKey)` 输入查询词；
/// - `tester.testTextInput.receiveAction(TextInputAction.search)` 提交（= Enter）；
/// - `_submit` 之类的辅助函数点「在线搜索」按钮等价。
///
/// **提交走 `GlobalKey<OnlineSearchPanelState>.submit`**（Spec §5.4.2 选定的方案）：
/// 面板在切换来源时是**新建**的，"递增一个参数"不会被它看见 —— 直接调方法才行。
class OnlineSearchHost extends StatefulWidget {
  const OnlineSearchHost({
    super.key,
    this.search,
    this.onTrackSelected,
    this.onHistoryRequested,
  });

  /// 单平台搜索注入（null ⇒ 面板走聚合服务，需要 provider）。
  final OnlineSearchQuery? search;
  final Future<void> Function(MusicSearchPage page, MusicTrack selected)?
  onTrackSelected;
  final VoidCallback? onHistoryRequested;

  @override
  State<OnlineSearchHost> createState() => OnlineSearchHostState();
}

class OnlineSearchHostState extends State<OnlineSearchHost> {
  final TextEditingController controller = TextEditingController();
  final GlobalKey<OnlineSearchPanelState> panelKey = GlobalKey();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// 模拟"点「在线搜索」/ Enter"：直接调面板的 `submit`（与弹窗同一条路径）。
  void submit() {
    final query = controller.text;
    final panel = panelKey.currentState;
    if (panel != null) {
      panel.submit(query);
      return;
    }
    // 面板还没挂上 ⇒ 排到帧后（与弹窗里的同一条退路）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      panelKey.currentState?.submit(query);
    });
  }

  /// 模拟"父级重建"：查询词与已提交状态都不变。
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          key: onlineSearchHostFieldKey,
          controller: controller,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            suffixIcon: IconButton(
              tooltip: '在线搜索',
              onPressed: submit,
              icon: const Icon(Icons.travel_explore),
            ),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => submit(),
        ),
        Expanded(
          child: OnlineSearchPanel(
            key: panelKey,
            query: controller.text,
            search: widget.search,
            onTrackSelected: widget.onTrackSelected,
            onHistoryRequested: widget.onHistoryRequested,
          ),
        ),
      ],
    );
  }
}

/// 宿主输入框的 key（弹窗在线来源用的是同一个字面值 `online-search-field`）。
const onlineSearchHostFieldKey = ValueKey('online-search-field');
