import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/workspace_files_models.dart';
import '../state/workspace_files_controller.dart';
import 'appearance_controls.dart';

/// Happy 风格的只读工作区文件浏览：树、搜索、文本预览与安全摘要。
/// 不提供写按钮、shell 或 Git 写入口；越权路径由 Daemon workspacesafe 语义拒绝。
class WorkspaceFilesScreen extends ConsumerStatefulWidget {
  const WorkspaceFilesScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<WorkspaceFilesScreen> createState() =>
      _WorkspaceFilesScreenState();
}

class _WorkspaceFilesScreenState extends ConsumerState<WorkspaceFilesScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(workspaceFilesControllerProvider).initialize());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(workspaceFilesControllerProvider);
    return Scaffold(
      key: const Key('workspace-files-screen'),
      appBar: AppBar(
        title: const Text('工作区文件', key: Key('workspace-files-title')),
        leading: IconButton(
          key: const Key('workspace-files-back-button'),
          tooltip: '返回会话',
          onPressed: () => context.go('/sessions/${widget.sessionId}'),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          const AppearanceMenu(),
          IconButton(
            key: const Key('workspace-files-refresh-button'),
            tooltip: '刷新文件列表',
            onPressed: controller.phase == WorkspaceFilesPhase.loading
                ? null
                : () => unawaited(controller.refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _WorkspaceFilesBody(
              controller: controller,
              searchController: _searchController,
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceFilesBody extends StatelessWidget {
  const _WorkspaceFilesBody({
    required this.controller,
    required this.searchController,
  });

  final WorkspaceFilesController controller;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == WorkspaceFilesPhase.loading) {
      return const Center(
        key: Key('workspace-files-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == WorkspaceFilesPhase.error &&
        controller.entries.isEmpty) {
      return _WorkspaceFilesFailure(
        message: controller.errorMessage ?? '文件列表暂时不可用。',
        onRetry: () => unawaited(controller.refresh()),
      );
    }
    return Column(
      children: [
        _WorkspaceSearchField(
          controller: controller,
          searchController: searchController,
        ),
        if (controller.rejectionMessage != null)
          _WorkspaceRejectionBanner(
            message: controller.rejectionMessage!,
            onDismiss: controller.clearRejection,
          ),
        Expanded(
          child: controller.isSearching
              ? _WorkspaceSearchResults(
                  controller: controller,
                  onOpen: (entry) => _openEntry(context, controller, entry),
                )
              : _WorkspaceEntryList(
                  controller: controller,
                  onOpen: (entry) => _openEntry(context, controller, entry),
                ),
        ),
        if (controller.preview != null)
          _WorkspacePreviewPanel(
            content: controller.preview!,
            onClose: controller.clearPreview,
          ),
      ],
    );
  }

  /// 目录进入下一层；文件打开只读预览。越权拒绝由控制器写入 banner。
  void _openEntry(
    BuildContext context,
    WorkspaceFilesController controller,
    WorkspaceFileEntry entry,
  ) {
    if (entry.isDirectory) {
      unawaited(controller.openDirectory(entry.path));
    } else {
      unawaited(controller.openFile(entry.path));
    }
  }
}

class _WorkspaceSearchField extends StatelessWidget {
  const _WorkspaceSearchField({
    required this.controller,
    required this.searchController,
  });

  final WorkspaceFilesController controller;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: TextField(
      key: const Key('workspace-files-search-input'),
      controller: searchController,
      decoration: InputDecoration(
        hintText: '搜索当前目录',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: controller.isSearching
            ? IconButton(
                tooltip: '清除搜索',
                onPressed: () {
                  searchController.clear();
                  controller.search('');
                },
                icon: const Icon(Icons.close, size: 18),
              )
            : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        isDense: true,
      ),
      onChanged: controller.search,
    ),
  );
}

class _WorkspaceRejectionBanner extends StatelessWidget {
  const _WorkspaceRejectionBanner({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('workspace-files-rejection-banner'),
    margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.shield_outlined, size: 16),
        const SizedBox(width: 6),
        Expanded(child: Text(message)),
        IconButton(
          tooltip: '关闭',
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 16),
        ),
      ],
    ),
  );
}

class _WorkspaceEntryList extends StatelessWidget {
  const _WorkspaceEntryList({required this.controller, required this.onOpen});

  final WorkspaceFilesController controller;
  final void Function(WorkspaceFileEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final path = controller.currentPath;
    final entries = controller.entries;
    return ListView(
      key: const Key('workspace-files-list'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      children: [
        if (path.isNotEmpty)
          ListTile(
            key: const Key('workspace-files-up-button'),
            dense: true,
            leading: const Icon(Icons.arrow_upward_outlined, size: 20),
            title: const Text('上一级目录'),
            onTap: () {
              final parent = path.contains('/')
                  ? path.substring(0, path.lastIndexOf('/'))
                  : '';
              controller.openDirectory(parent);
            },
          ),
        for (final entry in entries)
          ListTile(
            key: Key('workspace-file-${entry.path}'),
            dense: true,
            leading: Icon(
              entry.isDirectory
                  ? Icons.folder_outlined
                  : Icons.description_outlined,
              size: 20,
            ),
            title: Text(entry.name),
            subtitle: entry.isDirectory
                ? null
                : Text(_formatBytes(entry.byteSize)),
            trailing: entry.isDirectory
                ? const Icon(Icons.chevron_right, size: 18)
                : null,
            onTap: () => onOpen(entry),
          ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                '此目录没有可浏览的文件。',
                key: const Key('workspace-files-empty'),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkspaceSearchResults extends StatelessWidget {
  const _WorkspaceSearchResults({
    required this.controller,
    required this.onOpen,
  });

  final WorkspaceFilesController controller;
  final void Function(WorkspaceFileEntry entry) onOpen;

  @override
  Widget build(BuildContext context) {
    final results = controller.searchResults;
    return ListView(
      key: const Key('workspace-files-search-results'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      children: [
        for (final entry in results)
          ListTile(
            key: Key('workspace-search-${entry.path}'),
            dense: true,
            leading: Icon(
              entry.isDirectory
                  ? Icons.folder_outlined
                  : Icons.description_outlined,
              size: 20,
            ),
            title: Text(entry.name),
            onTap: () => onOpen(entry),
          ),
        if (results.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('没有匹配的文件。')),
          ),
      ],
    );
  }
}

class _WorkspacePreviewPanel extends StatelessWidget {
  const _WorkspacePreviewPanel({required this.content, required this.onClose});

  final WorkspaceFileContent content;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final limited = content.limitedKind != WorkspaceFileLimitedKind.none;
    return Container(
      key: const Key('workspace-files-preview-panel'),
      height: 220,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    content.path,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                IconButton(
                  key: const Key('workspace-files-preview-close'),
                  tooltip: '关闭预览',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Expanded(
            child: limited
                ? _WorkspaceLimitedPreview(content: content)
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      content.text,
                      key: const Key('workspace-files-preview-text'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 二进制/超大文件的安全摘要：不渲染正文，只展示限制类型与大小。
class _WorkspaceLimitedPreview extends StatelessWidget {
  const _WorkspaceLimitedPreview({required this.content});

  final WorkspaceFileContent content;

  @override
  Widget build(BuildContext context) {
    final label = switch (content.limitedKind) {
      WorkspaceFileLimitedKind.binary => '二进制文件，不提供文本预览。',
      WorkspaceFileLimitedKind.tooLarge => '文件过大，仅显示受限摘要。',
      WorkspaceFileLimitedKind.none => '',
    };
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        key: const Key('workspace-files-limited-preview'),
        children: [
          const Icon(Icons.visibility_off_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$label 大小：${_formatBytes(content.byteSize)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceFilesFailure extends StatelessWidget {
  const _WorkspaceFilesFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        key: const Key('workspace-files-error'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_off_outlined, size: 36),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
