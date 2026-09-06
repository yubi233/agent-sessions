import 'package:flutter/material.dart';
import '../app_theme.dart';

class SessionAgentPresetOption {
  const SessionAgentPresetOption({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;
}

/// 只在 deterministic fixture 中组合；真实 Relay 没有 roster 协议时不渲染。
const fixtureAgentPresetOptions = <SessionAgentPresetOption>[
  SessionAgentPresetOption(
    id: 'fixture-standard',
    name: '标准工具',
    description: '使用 fixture 默认工具与安全策略。',
  ),
  SessionAgentPresetOption(
    id: 'fixture-review',
    name: '代码审查',
    description: '以只读检查与回归分析为主。',
  ),
];

class SessionAgentPresetSeat extends StatelessWidget {
  const SessionAgentPresetSeat({
    required this.options,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final List<SessionAgentPresetOption> options;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    final selected = options
        .where((option) => option.id == selectedId)
        .firstOrNull;
    final current = selected ?? options.first;
    return PopupMenuButton<String>(
      key: const Key('session-agent-preset'),
      enabled: enabled,
      initialValue: current.id,
      tooltip: '选择下一会话的 Agent preset',
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem(
            value: option.id,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: option.id == current.id
                  ? const Icon(Icons.check, size: AppSizes.iconMd)
                  : const SizedBox(width: AppSpacing.lg),
              title: Text(option.name),
              subtitle: Text(option.description),
            ),
          ),
      ],
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Agent preset',
          suffixIcon: Icon(Icons.arrow_drop_down),
        ),
        child: Text(current.name),
      ),
    );
  }
}

/// 已创建会话的 preset 只能读取，不能从 header 伪装成可切换设置。
class SessionAgentPresetLabel extends StatelessWidget {
  const SessionAgentPresetLabel({required this.presetId, super.key});

  final String? presetId;

  @override
  Widget build(BuildContext context) {
    final id = presetId?.trim();
    if (id == null || id.isEmpty) return const SizedBox.shrink();
    final option = fixtureAgentPresetOptions
        .where((entry) => entry.id == id)
        .firstOrNull;
    return Tooltip(
      message: option?.description ?? '此会话的 Agent preset',
      child: Chip(
        key: const Key('session-agent-preset-label'),
        avatar: const Icon(Icons.tune, size: AppSizes.iconSm),
        label: Text(option?.name ?? id),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
