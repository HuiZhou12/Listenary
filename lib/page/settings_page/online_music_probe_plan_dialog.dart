import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_inputs.dart';
import 'package:pure_music/services/music_platform/declarative/declarative_probe_plan.dart';

/// 探测前的**计划确认**对话框（F3-2b / Spec §13.2 R7、§9.4、§10 决策 5）。
///
/// 三件事必须在**发请求之前**说清，并且允许就地改输入：
/// 1. 会测**哪些候选**（来源 + 能力，顺序即执行顺序）；
/// 2. 用什么**输入**（**默认值也写出来** —— 结论是"在这个输入下"得到的）；
/// 3. 是否需要**真实凭据**（声明需要但没配 ⇒ 结论最多"未能确认"，不会伪造成功）。
///
/// 取消 ⇒ 返回 null ⇒ 调用方**一个请求都不发**。
class OnlineMusicProbePlanDialog extends StatefulWidget {
  const OnlineMusicProbePlanDialog({super.key, required this.plan});

  final ProviderProbePlan plan;

  @override
  State<OnlineMusicProbePlanDialog> createState() =>
      _OnlineMusicProbePlanDialogState();
}

class _OnlineMusicProbePlanDialogState
    extends State<OnlineMusicProbePlanDialog> {
  late final TextEditingController _keyword = TextEditingController(
    text: widget.plan.inputs.keyword ?? '',
  );
  late final TextEditingController _limit = TextEditingController(
    text: widget.plan.inputs.limit?.toString() ?? '',
  );
  String? _limitError;

  @override
  void dispose() {
    _keyword.dispose();
    _limit.dispose();
    super.dispose();
  }

  void _confirm() {
    final limitRaw = _limit.text.trim();
    int? limit;
    if (limitRaw.isNotEmpty) {
      final parsed = int.tryParse(limitRaw);
      if (parsed == null || parsed <= 0) {
        // 非法值**不发送请求**（Spec §10 决策 5 / 输入契约）。
        setState(() => _limitError = '每页数量必须是正整数（或留空用默认值）');
        return;
      }
      limit = parsed;
    }
    final keywordRaw = _keyword.text.trim();
    Navigator.of(context).pop(
      DeclarativeProbeInputs(
        // 留空 = 用默认值（默认值会在结论里如实注明）；这样"空"与"默认"不会混。
        keyword: keywordRaw.isEmpty ? null : keywordRaw,
        limit: limit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('探测前确认'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.plan.describe()),
              const SizedBox(height: 16),
              TextField(
                controller: _keyword,
                decoration: const InputDecoration(
                  labelText: '关键词（留空 = 使用默认值）',
                  hintText: probeDefaultKeyword,
                  helperText: '只影响"查什么"；留空时结论里会注明用的是默认值',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '每页数量（留空 = 使用默认值）',
                  hintText: '$probeDefaultLimit',
                  errorText: _limitError,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _confirm,
          icon: const Icon(Symbols.search),
          label: const Text('开始探测'),
        ),
      ],
    );
  }
}
