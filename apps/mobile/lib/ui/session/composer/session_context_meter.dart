import 'package:flutter/material.dart';

import '../../../domain/control_models.dart';
import '../../../domain/session_projection_models.dart';

/// v0.5/P7：ContextMeter 是上下文窗口压力的近似投影。
///
/// 只展示 Host/fixture 明确提供的 used/window；capacity 消失或比例缺失时
/// 不画伪占用段。点击打开 breakdown 对话框，再次点击/遮罩/Escape 关闭。
class SessionContextMeter extends StatefulWidget {
  const SessionContextMeter({required this.meter, super.key});

  final SessionContextMeterProjection meter;

  @override
  State<SessionContextMeter> createState() => _SessionContextMeterState();
}

class _SessionContextMeterState extends State<SessionContextMeter> {
  final FocusNode _triggerFocus = FocusNode(debugLabel: 'context-meter');
  bool _dialogOpen = false;

  bool get _available =>
      widget.meter.usedTokens != null &&
      widget.meter.windowTokens != null &&
      widget.meter.windowTokens! > 0;

  @override
  void didUpdateWidget(covariant SessionContextMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dialogOpen && !_available) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_dialogOpen) return;
        Navigator.of(context, rootNavigator: true).pop();
      });
    }
  }

  @override
  void dispose() {
    _triggerFocus.dispose();
    super.dispose();
  }

  Future<void> _toggleBreakdown() async {
    if (_dialogOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      return;
    }
    final ratio = widget.meter.ratio;
    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('session-context-meter-dialog'),
        title: const Text('上下文占用'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ratio == null
                  ? '上下文窗口不可用'
                  : '已用 ${SessionUsageSummary.compactForDisplay(widget.meter.usedTokens!)} / '
                        '窗口 ${SessionUsageSummary.compactForDisplay(widget.meter.windowTokens!)}'
                        '（${(ratio * 100).toStringAsFixed(0)}%）',
            ),
            const SizedBox(height: 8),
            if (widget.meter.usedTokens != null &&
                widget.meter.windowTokens != null)
              LinearProgressIndicator(
                value: ratio?.clamp(0.0, 1.0),
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('session-context-meter-dialog-close'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (mounted && _available) _triggerFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = widget.meter.ratio;
    final used = widget.meter.usedTokens;
    final window = widget.meter.windowTokens;
    if (used == null || window == null || window <= 0 || ratio == null) {
      return Padding(
        key: const Key('session-context-meter'),
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          '上下文不可用',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Padding(
      key: const Key('session-context-meter'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        button: true,
        label: '上下文占用 ${(ratio * 100).toStringAsFixed(0)}%，打开详情',
        child: InkWell(
          key: const Key('session-context-meter-open'),
          focusNode: _triggerFocus,
          borderRadius: BorderRadius.circular(8),
          onTap: _toggleBreakdown,
          child: Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '上下文 ${(ratio * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(width: 2),
              const Icon(Icons.info_outline, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}
