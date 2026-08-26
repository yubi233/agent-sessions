import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../state/command_palette_controller.dart';
import 'app_theme.dart';

/// P3 命令面板：只索引已注册路由与已授权动作，不创造隐藏写能力。
///
/// 支持按关键字过滤：导航（路由）、会话（切换）、控制（capability 门控）。
/// unsupported/无 lease 的动作明确显示原因且不可执行；服务端授权仍然
/// 是最终裁决，面板只是客户端入口索引。
class CommandPaletteScreen extends ConsumerStatefulWidget {
  const CommandPaletteScreen({super.key});

  @override
  ConsumerState<CommandPaletteScreen> createState() =>
      _CommandPaletteScreenState();
}

class _CommandPaletteScreenState extends ConsumerState<CommandPaletteScreen> {
  final _searchController = TextEditingController();
  FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(commandPaletteControllerProvider);
    return Scaffold(
      key: const Key('command-palette-screen'),
      appBar: AppBar(
        title: const Text('命令面板'),
        leading: IconButton(
          key: const Key('command-palette-back-button'),
          tooltip: '关闭命令面板',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    key: const Key('command-palette-input'),
                    controller: _searchController,
                    focusNode: _focusNode,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '搜索路由、会话或动作…',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (query) => controller.filter(query),
                  ),
                ),
                Expanded(
                  child: _PaletteResults(
                    controller: controller,
                    onSelect: (command) => _execute(context, controller, command),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 执行选中命令：导航直接跳转；会话切换先选中；控制动作经 capability
  /// 与 lease 门控后提交，unsupported 一律不执行。
  void _execute(
    BuildContext context,
    CommandPaletteController controller,
    PaletteCommand command,
  ) {
    final router = GoRouter.of(context);
    switch (command.kind) {
      case PaletteCommandKind.navigate:
        final route = command.route;
        if (route != null) router.push(route);
      case PaletteCommandKind.session:
        final sessions = ref.read(sessionControllerProvider);
        final sessionId = command.sessionId;
        if (sessionId != null) {
          unawaited(sessions.selectSession(sessionId));
          router.push('/sessions/$sessionId');
        }
      case PaletteCommandKind.control:
        if (command.blockedReason != null) return;
        final sessions = ref.read(sessionControllerProvider);
        final app = ref.read(appControllerProvider);
        final canWrite = app.canManageDevices;
        final deviceId = app.currentDevice?.id;
        switch (command.action) {
          case PaletteControlAction.resume:
            sessions.resumeSelectedSession(
              deviceId: deviceId,
              canWrite: canWrite,
            );
          case PaletteControlAction.stop:
            sessions.stopStreaming(deviceId: deviceId, canWrite: canWrite);
          case PaletteControlAction.openFiles:
            router.push('/sessions/${sessions.selectedSessionId}/files');
          case PaletteControlAction.openGit:
            router.push('/sessions/${sessions.selectedSessionId}/git');
          case null:
            break;
        }
    }
  }
}

class _PaletteResults extends StatelessWidget {
  const _PaletteResults({
    required this.controller,
    required this.onSelect,
  });

  final CommandPaletteController controller;
  final void Function(PaletteCommand command) onSelect;

  @override
  Widget build(BuildContext context) {
    final results = controller.results;
    if (results.isEmpty) {
      return Center(
        key: const Key('command-palette-empty'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.manage_search_outlined,
              size: 32,
              color: context.appColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              controller.query.trim().isEmpty ? '输入关键字开始搜索' : '没有匹配的命令',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    return ListView(
      key: const Key('command-palette-results'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        for (var index = 0; index < results.length; index += 1)
          _PaletteResultTile(
            command: results[index],
            index: index,
            onSelect: () => onSelect(results[index]),
          ),
      ],
    );
  }
}

class _PaletteResultTile extends StatelessWidget {
  const _PaletteResultTile({
    required this.command,
    required this.index,
    required this.onSelect,
  });

  final PaletteCommand command;
  final int index;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final blocked = command.blockedReason != null;
    final colors = context.appColors;
    return ListTile(
      key: Key('command-palette-result-$index'),
      enabled: !blocked,
      dense: true,
      leading: Icon(
        command.icon,
        color: blocked ? Theme.of(context).disabledColor : colors.info,
      ),
      title: Text(command.title),
      subtitle: blocked
          ? Text(
              command.blockedReason!,
              style: Theme.of(context).textTheme.labelSmall,
            )
          : Text(
              command.subtitle,
              style: Theme.of(context).textTheme.labelSmall,
            ),
      onTap: onSelect,
    );
  }
}
