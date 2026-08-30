import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/session_models.dart';
import '../domain/terminal_models.dart';
import '../state/session_controller.dart';
import 'app_theme.dart';

/// P3 会话 info 页：只读聚合会话元数据、机器白名单状态与终止/恢复能力。
///
/// 本页不持有会话正文、token 或完整路径；复制只提供白名单字段；分享在
/// 独立安全 ADR 通过前恒为 unavailable，不展示假入口。
class SessionInfoScreen extends ConsumerStatefulWidget {
  const SessionInfoScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SessionInfoScreen> createState() => _SessionInfoScreenState();
}

class _SessionInfoScreenState extends ConsumerState<SessionInfoScreen> {
  @override
  void initState() {
    super.initState();
    // 深链/通知跳转时这里才显式选中会话；必须延迟到 widget 树构建完成后，
    // 避免在生命周期内同步修改 provider 触发 Riverpod 断言。
    final sessions = ref.read(sessionControllerProvider);
    if (sessions.selectedSessionId != widget.sessionId) {
      Future<void>.microtask(() {
        if (!mounted) return;
        final current = ref.read(sessionControllerProvider);
        if (current.selectedSessionId != widget.sessionId) {
          current.selectSession(widget.sessionId);
        }
      });
    }
  }

  /// 生成排障用 debug 文本：只包含当前页面已展示的白名单元数据，不写 token、
  /// 消息正文、恢复码或完整路径。终端/会话 opaque ID 属于本机排查所需，不视为密钥。
  String _debugInfoText(MobileSession session) {
    final controller = ref.read(sessionInfoControllerProvider(session.id));
    final buffer = StringBuffer()
      ..writeln('会话 Debug 信息')
      ..writeln('会话 ID: ${session.id}')
      ..writeln('会话名称: ${session.displayName ?? ''}')
      ..writeln('状态: ${controller.statusLabel} (${session.status.wireValue})')
      ..writeln('Provider: ${session.provider}')
      ..writeln('模型: ${session.model ?? ''}')
      ..writeln('工作区 ID: ${session.workspaceId}')
      ..writeln('工作区名称: ${session.workspaceName ?? ''}')
      ..writeln('工作区: ${session.workspaceLabel}')
      ..writeln('项目: ${session.projectName ?? ''}')
      ..writeln('事件序号: ${session.lastSequence}')
      ..writeln('更新时间: ${session.updatedAt?.toIso8601String() ?? ''}')
      ..writeln(
        '最后活动: ${session.lastActivityAt?.toIso8601String() ?? ''}',
      );
    if (session.parentSessionId != null) {
      buffer.writeln('父会话 ID: ${session.parentSessionId}');
    }
    if (session.forkedFromMessageId != null) {
      buffer.writeln('Fork 来源消息: ${session.forkedFromMessageId}');
    }
    if (session.agentPresetId != null) {
      buffer.writeln('Agent 预设: ${session.agentPresetId}');
    }
    if (session.subagentReadOnlyReason != null) {
      buffer.writeln('子会话只读原因: ${session.subagentReadOnlyReason}');
    }
    if (session.archivedAt != null) {
      buffer.writeln('归档时间: ${session.archivedAt!.toIso8601String()}');
    }
    buffer.writeln('终端:');
    if (controller.visibleTerminals.isEmpty) {
      buffer.writeln('  暂无已确认终端');
    } else {
      for (final terminal in controller.visibleTerminals) {
        buffer
          ..writeln('  - ID: ${terminal.id}')
          ..writeln('    名称: ${terminal.hostname}')
          ..writeln('    平台: ${terminal.platform}')
          ..writeln('    状态: ${terminal.status.wireValue}')
          ..writeln('    协议版本: ${terminal.protocolVersion}')
          ..writeln('    Daemon 版本: ${terminal.daemonVersion ?? ''}')
          ..writeln(
            '    最后在线: ${terminal.lastSeen?.toIso8601String() ?? ''}',
          );
      }
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final controller = ref.watch(sessionInfoControllerProvider(sessionId));
    final app = ref.watch(appControllerProvider);
    final sessions = ref.watch(sessionControllerProvider);
    final session = controller.session;
    return Scaffold(
      key: const Key('session-info-screen'),
      appBar: AppBar(
        title: const Text('会话信息'),
        leading: IconButton(
          key: const Key('session-info-back-button'),
          tooltip: '返回会话',
          onPressed: () => context.go('/sessions/$sessionId'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              key: const Key('session-info-list'),
              padding: const EdgeInsets.all(16),
              children: [
                if (session == null)
                  const _InfoEmptyState()
                else ...[
                  _InfoCard(
                    title: '会话',
                    children: [
                      _InfoRow(label: '会话 ID', value: session.id),
                      if (session.displayName?.trim().isNotEmpty == true)
                        _InfoRow(label: '会话名称', value: session.displayName!),
                      _InfoRow(label: '状态', value: controller.statusLabel),
                      _InfoRow(label: 'Provider', value: session.provider),
                      _InfoRow(
                        label: '模型',
                        value: session.model?.trim().isNotEmpty == true
                            ? session.model!
                            : '未设置',
                      ),
                      _InfoRow(label: '事件序号', value: '${session.lastSequence}'),
                      _InfoRow(label: '工作区 ID', value: session.workspaceId),
                      if (session.projectName?.trim().isNotEmpty == true)
                        _InfoRow(label: '项目', value: session.projectName!),
                      _InfoRow(label: '工作区', value: session.workspaceLabel),
                      _InfoRow(
                        label: '更新时间',
                        value: session.updatedAt?.toIso8601String() ?? '未知',
                      ),
                      _InfoRow(
                        label: '最后活动',
                        value: session.lastActivityAt?.toIso8601String() ??
                            '未知',
                      ),
                      if (session.parentSessionId != null)
                        _InfoRow(label: '父会话 ID', value: session.parentSessionId!),
                      if (session.forkedFromMessageId != null)
                        _InfoRow(
                          label: 'Fork 来源',
                          value: session.forkedFromMessageId!,
                        ),
                      if (session.agentPresetId != null)
                        _InfoRow(label: 'Agent 预设', value: session.agentPresetId!),
                      if (session.subagentReadOnlyReason != null)
                        _InfoRow(
                          label: '子会话只读',
                          value: session.subagentReadOnlyReason!,
                        ),
                      if (session.archivedAt != null)
                        _InfoRow(
                          label: '归档时间',
                          value: session.archivedAt!.toIso8601String(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InfoCard(
                    title: '机器',
                    children: [
                      if (controller.visibleTerminals.isEmpty)
                        const _InfoRow(label: '终端', value: '暂无已确认终端')
                      else
                        for (final terminal in controller.visibleTerminals)
                          _TerminalInfoRow(terminal: terminal),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InfoCard(
                    title: '能力',
                    children: [
                      _CapabilityRow(
                        label: '终止会话',
                        blockedReason: controller.stopBlockedReason,
                      ),
                      _CapabilityRow(
                        label: '结束本机进程',
                        blockedReason: controller.killBlockedReason,
                      ),
                      _CapabilityRow(
                        label: '恢复会话',
                        blockedReason: controller.resumeBlockedReason,
                      ),
                      _CapabilityRow(
                        label: '分享',
                        blockedReason: controller.shareUnavailable
                            ? '分享能力未通过安全决策门，当前不可用。'
                            : null,
                      ),
                    ],
                  ),
                  if (app.canManageDevices) ...[
                    const SizedBox(height: 12),
                    _SessionInfoActions(
                      sessions: sessions,
                      deviceId: app.currentDevice?.id,
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('session-info-copy-id-button'),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: session.id)),
                        icon: const Icon(Icons.copy_outlined, size: 16),
                        label: const Text('复制会话 ID'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('session-info-copy-provider-button'),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: session.provider),
                        ),
                        icon: const Icon(Icons.copy_outlined, size: 16),
                        label: const Text('复制 Provider'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('session-info-copy-debug-button'),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: _debugInfoText(session)),
                        ),
                        icon: const Icon(Icons.bug_report_outlined, size: 16),
                        label: const Text('复制 Debug 信息'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const _BoundaryNote(
                    message:
                        '此页面只显示 Relay 白名单元数据；消息正文、token 与完整路径不会显示。终止与恢复需要 owner 可操作状态与 Provider 能力，分享暂不可用。',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 会话详情页的写入口只在当前设备是 owner 时出现，具体动作仍由
/// SessionController 统一执行 capability、lease、幂等和二次确认门控。
class _SessionInfoActions extends StatelessWidget {
  const _SessionInfoActions({required this.sessions, required this.deviceId});

  final SessionController sessions;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final startBlocked = sessions.controlBlockedReason('start', canWrite: true);
    final killBlocked = sessions.killBlockedReason(canWrite: true);
    return _InfoCard(
      title: '本机进程',
      children: [
        OutlinedButton.icon(
          key: const Key('session-start-button'),
          onPressed: startBlocked == null && !sessions.isBusy
              ? () => sessions.startSelectedSession(
                  deviceId: deviceId,
                  canWrite: true,
                )
              : null,
          icon: const Icon(Icons.play_arrow_outlined),
          label: Text(startBlocked == null ? '启动会话' : '启动不可用：$startBlocked'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('session-kill-button'),
          onPressed: killBlocked == null && !sessions.isBusy
              ? () => _confirmKill(context)
              : null,
          icon: const Icon(Icons.stop_circle_outlined),
          label: Text(killBlocked == null ? '结束本机进程' : '结束不可用：$killBlocked'),
        ),
      ],
    );
  }

  Future<void> _confirmKill(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('结束本机进程？'),
        content: const Text('这会结束当前会话的受控本地进程，已提交的事件不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('session-kill-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('结束进程'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await sessions.killSelectedSession(deviceId: deviceId, canWrite: true);
    }
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: context.appColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// 机器信息行：只展示 hostname/平台/版本白名单字段，不展示终端 ID、路径或日志。
class _TerminalInfoRow extends StatelessWidget {
  const _TerminalInfoRow({required this.terminal});

  final TerminalSummary terminal;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 80,
          child: Text('终端', style: TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Text(
            '${terminal.hostname} · ${terminal.platform} · Daemon ${terminal.daemonVersion ?? '版本未知'}',
            style: Theme.of(context).textTheme.bodyMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// 能力行：无阻断原因表示可用，否则展示明确原因（fail-closed）。
class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.label, required this.blockedReason});

  final String label;
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final blocked = blockedReason != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(
            child: Text(
              blocked ? blockedReason! : '可用',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: blocked ? colors.warning : colors.success,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BoundaryNote extends StatelessWidget {
  const _BoundaryNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.appColors.surfaceRaised,
      border: Border.all(color: context.appColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}

class _InfoEmptyState extends StatelessWidget {
  const _InfoEmptyState();

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('session-info-empty'),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.info_outline,
            size: 32,
            color: context.appColors.textSecondary,
          ),
          const SizedBox(height: 12),
          Text('未找到会话信息。', style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    ),
  );
}
