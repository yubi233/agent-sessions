import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/git_diff_models.dart';
import '../state/git_diff_controller.dart';
import 'appearance_controls.dart';
import 'app_theme.dart';

/// Happy 风格的移动 Git DiffView：只读查看，不提供 stage、discard、commit 或 shell 入口。
class GitDiffScreen extends ConsumerStatefulWidget {
  const GitDiffScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<GitDiffScreen> createState() => _GitDiffScreenState();
}

class _GitDiffScreenState extends ConsumerState<GitDiffScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // controller 也会在 provider 创建时加载；此处确保返回该路由时重新消费已有 snapshot。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(gitDiffControllerProvider).initialize());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(gitDiffControllerProvider);
    final snapshot = controller.snapshot;
    return Scaffold(
      key: const Key('git-diff-screen'),
      appBar: AppBar(
        title: const Text('Git Diff', key: Key('git-diff-title')),
        leading: IconButton(
          key: const Key('git-diff-back-button'),
          tooltip: '返回会话',
          onPressed: () => context.go('/sessions/${widget.sessionId}'),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          const AppearanceMenu(),
          IconButton(
            key: const Key('git-diff-refresh-button'),
            tooltip: '刷新 Git 快照',
            onPressed:
                controller.isFileLoading ||
                    controller.isLoadingMore ||
                    controller.phase == GitDiffPhase.loading
                ? null
                : () => unawaited(controller.initialize(force: true)),
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
            child: _GitDiffBody(
              controller: controller,
              snapshot: snapshot,
              searchController: _searchController,
            ),
          ),
        ),
      ),
    );
  }
}

class _GitDiffBody extends StatelessWidget {
  const _GitDiffBody({
    required this.controller,
    required this.snapshot,
    required this.searchController,
  });

  final GitDiffController controller;
  final GitDiffSnapshot? snapshot;
  final TextEditingController searchController;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == GitDiffPhase.loading && snapshot == null) {
      return const Center(
        key: Key('git-diff-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (snapshot == null) {
      return _GitDiffFailureState(
        phase: controller.phase,
        message: controller.message,
        onRetry: () => unawaited(controller.initialize(force: true)),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 文件树在 480x960 占固定上限；较矮窗口优先给 Diff 错误/重试状态留出可读空间。
        final availableHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : 960.0;
        final fileTreeHeight = (availableHeight - 430)
            .clamp(76.0, 186.0)
            .toDouble();
        return Column(
          children: [
            _GitSnapshotHeader(snapshot: snapshot!),
            _GitFilterBar(controller: controller),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: TextField(
                key: const Key('git-diff-search-input'),
                controller: searchController,
                onChanged: controller.setQuery,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '筛选文件',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            _GitFileTree(controller: controller, height: fileTreeHeight),
            _GitDiffToolbar(controller: controller),
            Expanded(child: _GitDiffContent(controller: controller)),
          ],
        );
      },
    );
  }
}

class _GitSnapshotHeader extends StatelessWidget {
  const _GitSnapshotHeader({required this.snapshot});

  final GitDiffSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final summary = snapshot.summary;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  snapshot.repositoryLabel,
                  key: const Key('git-repository-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelLarge,
                ),
              ),
              const SizedBox(width: 8),
              // 长分支名在 480 宽下会撑爆 Row：包 Flexible 让 ellipsis 生效。
              Flexible(
                child: Text(
                  snapshot.branch,
                  key: const Key('git-branch-label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Metric(label: '文件', value: '${summary.changedFiles}'),
              _Metric(label: '暂存', value: '${summary.stagedFiles}'),
              _Metric(
                label: '+',
                value: '${summary.additions}',
                positive: true,
              ),
              _Metric(
                label: '-',
                value: '${summary.deletions}',
                negative: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.positive = false,
    this.negative = false,
  });

  final String label;
  final String value;
  final bool positive;
  final bool negative;

  @override
  Widget build(BuildContext context) {
    final color = positive
        ? context.appColors.success
        : negative
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).textTheme.bodyMedium?.color;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _GitFilterBar extends StatelessWidget {
  const _GitFilterBar({required this.controller});

  final GitDiffController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
    child: SizedBox(
      width: double.infinity,
      child: SegmentedButton<GitChangeFilter>(
        key: const Key('git-filter-segmented'),
        showSelectedIcon: false,
        segments: GitChangeFilter.values
            .map(
              (filter) => ButtonSegment<GitChangeFilter>(
                value: filter,
                label: Text(
                  filter.label,
                  key: Key('git-filter-${filter.name}'),
                ),
              ),
            )
            .toList(growable: false),
        selected: {controller.filter},
        onSelectionChanged: (selected) => controller.setFilter(selected.first),
      ),
    ),
  );
}

class _GitFileTree extends StatelessWidget {
  const _GitFileTree({required this.controller, required this.height});

  final GitDiffController controller;
  final double height;

  @override
  Widget build(BuildContext context) {
    final files = controller.visibleFiles;
    return SizedBox(
      height: height,
      child: files.isEmpty
          ? Center(
              key: const Key('git-file-tree-empty'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.filter_alt_off_outlined,
                    size: 32,
                    color: context.appColors.textSecondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '没有匹配的变更文件。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            )
          : ListView.builder(
              key: const Key('git-file-tree'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                return _GitFileRow(
                  file: file,
                  selected: file.path == controller.selectedPath,
                  onTap: controller.isFileLoading || controller.isLoadingMore
                      ? null
                      : () => unawaited(controller.selectFile(file.path)),
                );
              },
            ),
    );
  }
}

class _GitFileRow extends StatelessWidget {
  const _GitFileRow({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final GitChangeFile file;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final selectedColor = selected
        ? Theme.of(context).colorScheme.surfaceContainerHighest
        : Colors.transparent;
    return Material(
      color: selectedColor,
      // 文件行是卡状列表项：圆角回归 8 档，与全局卡片一致。
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        key: Key('git-diff-file-${_keyPath(file.path)}'),
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              Icon(
                _iconFor(file),
                size: 17,
                color: _changeColor(file, context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    if (file.renameFrom != null)
                      Text(
                        '${file.renameFrom} -> ${file.path}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      )
                    else if (file.limitedKind != GitDiffLimitedKind.none)
                      Text(
                        file.limitedKind.label,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 58,
                child: Text(
                  '+${file.additions} -${file.deletions}',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _iconFor(GitChangeFile file) => switch (file.limitedKind) {
  GitDiffLimitedKind.binary => Icons.image_not_supported_outlined,
  GitDiffLimitedKind.submodule => Icons.account_tree_outlined,
  GitDiffLimitedKind.lfs => Icons.inventory_2_outlined,
  GitDiffLimitedKind.tooLarge => Icons.warning_amber_outlined,
  GitDiffLimitedKind.none => switch (file.type) {
    GitChangeType.added || GitChangeType.untracked => Icons.add_circle_outline,
    GitChangeType.deleted => Icons.remove_circle_outline,
    GitChangeType.renamed => Icons.drive_file_rename_outline,
    _ => Icons.description_outlined,
  },
};

Color _changeColor(GitChangeFile file, BuildContext context) =>
    switch (file.type) {
      GitChangeType.added ||
      GitChangeType.untracked => context.appColors.success,
      GitChangeType.deleted => Theme.of(context).colorScheme.error,
      GitChangeType.renamed => context.appColors.warning,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };

String _keyPath(String path) => path.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-');

class _GitDiffToolbar extends StatelessWidget {
  const _GitDiffToolbar({required this.controller});

  final GitDiffController controller;

  @override
  Widget build(BuildContext context) => Container(
    height: 50,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: context.appColors.border)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            controller.selectedPath ?? '选择一个文件',
            key: const Key('git-selected-file-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
        SizedBox(
          width: 154,
          child: SegmentedButton<GitDiffViewMode>(
            key: const Key('git-view-segmented'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: GitDiffViewMode.unified,
                label: Text('统一', key: Key('git-view-unified')),
              ),
              ButtonSegment(
                value: GitDiffViewMode.split,
                label: Text('拆分', key: Key('git-view-split')),
              ),
            ],
            selected: {controller.viewMode},
            onSelectionChanged: controller.phase == GitDiffPhase.ready
                ? (selected) => controller.setViewMode(selected.first)
                : null,
          ),
        ),
      ],
    ),
  );
}

class _GitDiffContent extends StatelessWidget {
  const _GitDiffContent({required this.controller});

  final GitDiffController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.phase == GitDiffPhase.stale) {
      return _GitDiffFailureState(
        phase: controller.phase,
        message: controller.message,
        onRetry: () => unawaited(controller.retryAfterStale()),
      );
    }
    if (controller.phase == GitDiffPhase.unavailable ||
        controller.phase == GitDiffPhase.error) {
      return _GitDiffFailureState(
        phase: controller.phase,
        message: controller.message,
        onRetry: () => unawaited(controller.initialize(force: true)),
      );
    }
    if (controller.isFileLoading) {
      return const Center(
        key: Key('git-diff-file-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final selected = controller.selectedFile;
    if (selected == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 32,
              color: context.appColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              '工作区没有可显示的变更。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    if (selected.limitedKind != GitDiffLimitedKind.none) {
      return _LimitedDiffState(file: selected);
    }
    if (controller.hunks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notes,
              size: 32,
              color: context.appColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              '此文件没有可显示的文本差异。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    return ListView(
      key: const Key('git-diff-scroll'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      children: [
        for (final hunk in controller.hunks)
          _GitHunkPanel(
            hunk: hunk,
            collapsed: controller.isHunkCollapsed(hunk.id),
            viewMode: controller.viewMode,
            onToggle: () => controller.toggleHunk(hunk.id),
          ),
        if (controller.hasMore)
          Align(
            alignment: Alignment.center,
            child: IconButton(
              key: const Key('git-load-more-button'),
              tooltip: '加载更多 Diff',
              onPressed: controller.isLoadingMore
                  ? null
                  : () => unawaited(controller.loadNextPage()),
              icon: controller.isLoadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more),
            ),
          ),
      ],
    );
  }
}

class _LimitedDiffState extends StatelessWidget {
  const _LimitedDiffState({required this.file});

  final GitChangeFile file;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Container(
      key: const Key('git-diff-limited-state'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.appColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  file.limitedKind.label,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            file.limitedKind.detail,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (file.renameFrom != null) ...[
            const SizedBox(height: 8),
            Text(
              '${file.renameFrom} -> ${file.path}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ],
      ),
    ),
  );
}

class _GitHunkPanel extends StatelessWidget {
  const _GitHunkPanel({
    required this.hunk,
    required this.collapsed,
    required this.viewMode,
    required this.onToggle,
  });

  final GitDiffHunk hunk;
  final bool collapsed;
  final GitDiffViewMode viewMode;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('git-hunk-${hunk.id}'),
    margin: const EdgeInsets.only(bottom: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: context.appColors.border),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    hunk.header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ),
              IconButton(
                key: Key('git-hunk-toggle-${hunk.id}'),
                tooltip: collapsed ? '展开 Diff 段' : '折叠 Diff 段',
                onPressed: onToggle,
                icon: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
              ),
            ],
          ),
        ),
        if (!collapsed)
          viewMode == GitDiffViewMode.unified
              ? _UnifiedDiffLines(lines: hunk.lines)
              : _SplitDiffLines(lines: hunk.lines),
      ],
    ),
  );
}

class _UnifiedDiffLines extends StatelessWidget {
  const _UnifiedDiffLines({required this.lines});

  final List<GitDiffLine> lines;

  @override
  Widget build(BuildContext context) => Column(
    children: lines
        .map((line) => _UnifiedDiffLine(line: line))
        .toList(growable: false),
  );
}

class _UnifiedDiffLine extends StatelessWidget {
  const _UnifiedDiffLine({required this.line});

  final GitDiffLine line;

  @override
  Widget build(BuildContext context) {
    final background = _lineBackground(context, line.kind);
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LineNumber(value: line.oldLine),
          _LineNumber(value: line.newLine),
          Expanded(
            child: Text(
              '${_linePrefix(line.kind)}${line.text}',
              key: Key('git-unified-line-${line.oldLine ?? line.newLine ?? 0}'),
              softWrap: true,
              // 差异正文是核心内容：显式 onSurface，避免继承 bodyMedium 的次级灰。
              style: (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
                fontFamily: 'monospace',
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _SplitDiffLines extends StatelessWidget {
  const _SplitDiffLines({required this.lines});

  final List<GitDiffLine> lines;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('git-split-lines'),
    children: lines
        .map(
          (line) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _SplitCell(line: line, left: true)),
              const SizedBox(width: 1),
              Expanded(child: _SplitCell(line: line, left: false)),
            ],
          ),
        )
        .toList(growable: false),
  );
}

class _SplitCell extends StatelessWidget {
  const _SplitCell({required this.line, required this.left});

  final GitDiffLine line;
  final bool left;

  @override
  Widget build(BuildContext context) {
    final show = left
        ? line.kind != GitDiffLineKind.addition
        : line.kind != GitDiffLineKind.deletion;
    final number = left ? line.oldLine : line.newLine;
    return Container(
      color: show ? _lineBackground(context, line.kind) : Colors.transparent,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LineNumber(value: number),
          Expanded(
            child: Text(
              show ? line.text : '',
              softWrap: true,
              // 与统一视图同口径：显式 onSurface，12px 对齐统一视图行。
              style: (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
                fontFamily: 'monospace',
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _LineNumber extends StatelessWidget {
  const _LineNumber({required this.value});

  final int? value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 32,
    child: Text(
      value?.toString() ?? '',
      textAlign: TextAlign.end,
      style: Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(fontFamily: 'monospace'),
    ),
  );
}

Color _lineBackground(BuildContext context, GitDiffLineKind kind) =>
    switch (kind) {
      GitDiffLineKind.addition => context.appColors.diffAddition,
      GitDiffLineKind.deletion => context.appColors.diffDeletion,
      GitDiffLineKind.context => Colors.transparent,
    };

String _linePrefix(GitDiffLineKind kind) => switch (kind) {
  GitDiffLineKind.addition => '+ ',
  GitDiffLineKind.deletion => '- ',
  GitDiffLineKind.context => '  ',
};

class _GitDiffFailureState extends StatelessWidget {
  const _GitDiffFailureState({
    required this.phase,
    required this.message,
    required this.onRetry,
  });

  final GitDiffPhase phase;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isStale = phase == GitDiffPhase.stale;
    return SingleChildScrollView(
      key: const Key('git-diff-failure-scroll'),
      padding: const EdgeInsets.all(20),
      child: Container(
        key: isStale
            ? const Key('git-snapshot-stale')
            : const Key('git-diff-error-state'),
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border.all(color: context.appColors.border),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isStale ? Icons.sync_problem_outlined : Icons.cloud_off_outlined,
              size: 28,
            ),
            const SizedBox(height: 10),
            Text(
              message ?? 'Git 变更暂时不可用。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            IconButton(
              key: isStale
                  ? const Key('git-stale-retry-button')
                  : const Key('git-diff-retry-button'),
              tooltip: isStale ? '刷新 Git 快照' : '重试读取 Git',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
    );
  }
}
