import 'package:flutter/material.dart';

import '../../../domain/session_projection_models.dart';

/// v0.5 Chat node 的 keyed renderer。
///
/// 这里消费的是 display-safe projection，不直接读取 Relay event，也不处理写命令。
/// 这样 pending interaction、密文占位和隐藏推理都由投影层先裁剪，再进入 UI。
class SessionChatNodeSeat extends StatelessWidget {
  const SessionChatNodeSeat({required this.node, super.key});

  final ConversationNode node;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: Key('session-chat-node-${node.key}'),
      child: Semantics(
        container: true,
        label: '会话节点 ${node.label}',
        child: switch (node.kind) {
          ConversationNodeKind.user => _ChatBubble(node: node, user: true),
          ConversationNodeKind.assistant => _ChatBubble(
            node: node,
            user: false,
          ),
          ConversationNodeKind.reasoning => _ReasoningRow(node: node),
          ConversationNodeKind.tool => _ToolStepRow(node: node),
          ConversationNodeKind.command => _CompactSystemRow(
            node: node,
            icon: Icons.terminal_outlined,
            tone: _SystemRowTone.neutral,
          ),
          ConversationNodeKind.compaction => _CompactSystemRow(
            node: node,
            icon: Icons.compress_outlined,
            tone: _SystemRowTone.neutral,
          ),
          ConversationNodeKind.retry => _CompactSystemRow(
            node: node,
            icon: Icons.replay_outlined,
            tone: _SystemRowTone.warning,
          ),
          ConversationNodeKind.error => _CompactSystemRow(
            node: node,
            icon: Icons.error_outline,
            tone: _SystemRowTone.error,
          ),
          ConversationNodeKind.encrypted => _CompactSystemRow(
            node: node,
            icon: Icons.lock_outline,
            tone: _SystemRowTone.neutral,
          ),
          ConversationNodeKind.notice => _CompactSystemRow(
            node: node,
            icon: Icons.info_outline,
            tone: _SystemRowTone.neutral,
          ),
          ConversationNodeKind.turnTail => _CompactSystemRow(
            node: node,
            icon: Icons.done_all_outlined,
            tone: _SystemRowTone.neutral,
          ),
        },
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.node, required this.user});

  final ConversationNode node;
  final bool user;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = user
        ? const Color(0xffffefb0)
        : scheme.surfaceContainerHigh;
    final foreground = user ? const Color(0xff1d1d1f) : scheme.onSurface;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 382),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              node.label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: foreground.withValues(alpha: 0.72),
              ),
            ),
            if (node.text?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text(node.text!, style: TextStyle(color: foreground)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasoningRow extends StatelessWidget {
  const _ReasoningRow({required this.node});

  final ConversationNode node;

  @override
  Widget build(BuildContext context) {
    final summary = node.safeReasoningSummary?.trim();
    return Card(
      key: Key('session-reasoning-row-${node.sequence}'),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        leading: const Icon(Icons.psychology_alt_outlined),
        title: Text(node.isStreaming ? 'Think · 运行中' : 'Think'),
        subtitle: Text(
          summary?.isNotEmpty == true ? summary! : '没有可展示的安全推理摘要',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                summary?.isNotEmpty == true
                    ? summary!
                    : '上游未提供 display-safe summary。',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolStepRow extends StatelessWidget {
  const _ToolStepRow({required this.node});

  final ConversationNode node;

  @override
  Widget build(BuildContext context) => _CompactSystemRow(
    node: node,
    icon: Icons.build_outlined,
    tone: node.isStreaming ? _SystemRowTone.warning : _SystemRowTone.neutral,
    trailing: node.toolStatus,
  );
}

enum _SystemRowTone { neutral, warning, error }

class _CompactSystemRow extends StatelessWidget {
  const _CompactSystemRow({
    required this.node,
    required this.icon,
    required this.tone,
    this.trailing,
  });

  final ConversationNode node;
  final IconData icon;
  final _SystemRowTone tone;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      _SystemRowTone.neutral => scheme.onSurfaceVariant,
      _SystemRowTone.warning => scheme.tertiary,
      _SystemRowTone.error => scheme.error,
    };
    final detail = trailing ?? node.toolStatus ?? node.text;
    return Container(
      key: Key('session-compact-node-${node.sequence}-${node.kind.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
        color: scheme.surfaceContainerLowest,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(detail!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
