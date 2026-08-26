import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../domain/workspace_files_models.dart';
import '../state/code_viewer_controller.dart';
import 'app_theme.dart';

/// P3 只读代码查看器：行号、轻量语法高亮、搜索跳行与受限摘要。
///
/// 以 Navigator.push 全屏打开，不把 repo-relative 路径放进 URL；
/// 二进制/超大/无权/路径越界文件由 repository fail-closed，页面只展示受限摘要。
class CodeViewerScreen extends ConsumerStatefulWidget {
  const CodeViewerScreen({
    required this.filePath,
    super.key,
  });

  final String filePath;

  @override
  ConsumerState<CodeViewerScreen> createState() => _CodeViewerScreenState();
}

class _CodeViewerScreenState extends ConsumerState<CodeViewerScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  int _currentLine = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        ref.read(codeViewerControllerProvider).openFile(widget.filePath),
      );
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _jumpToLine(int line, CodeViewerController controller) {
    setState(() => _currentLine = line);
    final lineHeight = 20.0;
    // 按行高估算滚动位置，保证目标行进入视口。
    unawaited(
      _scrollController.animateTo(
        (line - 1) * lineHeight,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      ),
    );
    controller.jumpToLine(line);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(codeViewerControllerProvider);
    return Scaffold(
      key: const Key('code-viewer-screen'),
      appBar: AppBar(
        title: Text(
          widget.filePath,
          key: const Key('code-viewer-title'),
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          key: const Key('code-viewer-back-button'),
          tooltip: '返回文件列表',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          IconButton(
            key: const Key('code-viewer-search-button'),
            tooltip: '搜索文件内容',
            onPressed: controller.phase == CodeViewerPhase.ready
                ? () => _showSearchBar(controller)
                : null,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            key: const Key('code-viewer-jump-button'),
            tooltip: '跳转到行',
            onPressed: controller.phase == CodeViewerPhase.ready
                ? () => _showLineJumpDialog(controller)
                : null,
            icon: const Icon(Icons.vertical_align_center_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (controller.searchQuery.isNotEmpty)
              _CodeSearchBar(
                controller: controller,
                textController: _searchController,
                onStep: (forward) => controller.stepMatch(forward: forward),
                onJump: (line) => _jumpToLine(line, controller),
              ),
            Expanded(child: _buildBody(controller)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(CodeViewerController controller) {
    if (controller.phase == CodeViewerPhase.loading) {
      return const Center(
        key: Key('code-viewer-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == CodeViewerPhase.error) {
      return _CodeViewerError(
        message: controller.errorMessage ?? '代码读取失败。',
        onRetry: () => controller.openFile(widget.filePath),
      );
    }
    final content = controller.content;
    // 就绪但无内容：给可见占位而非整屏空白（空白会被误读为卡死）。
    if (content == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 56),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.code_off_outlined,
                size: 32,
                color: context.appColors.textSecondary,
              ),
              const SizedBox(height: 12),
              Text(
                '暂无可显示的内容。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }
    // 二进制/超大文件：与文件浏览页一致的受限摘要，不渲染正文。
    if (content.limitedKind != WorkspaceFileLimitedKind.none) {
      return _CodeLimitedView(content: content);
    }
    final lines = content.text.split('\n');
    return Align(
      alignment: Alignment.topLeft,
      child: SingleChildScrollView(
        key: const Key('code-viewer-scroll'),
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CodeLineNumbers(
                lineCount: lines.length,
                searchMatches: controller.searchMatches(),
                activeMatch: controller.activeMatchIndex,
                currentLine: _currentLine,
              ),
              _CodeTextColumn(
                lines: lines,
                activeMatchLine: controller.activeMatchLine(),
                highlight: const CodeSyntaxHighlighter(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSearchBar(CodeViewerController controller) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: TextField(
          key: const Key('code-viewer-search-input'),
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '搜索代码内容',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (query) {
            controller.search(query);
            Navigator.of(sheetContext).pop();
          },
        ),
      ),
    );
  }

  void _showLineJumpDialog(CodeViewerController controller) {
    final lines = controller.lineCount();
    final input = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('跳转到行'),
        content: TextField(
          key: const Key('code-viewer-line-input'),
          controller: input,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '行号（1-$lines）',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('code-viewer-line-jump-confirm'),
            onPressed: () {
              final parsed = int.tryParse(input.text.trim());
              Navigator.of(dialogContext).pop();
              if (parsed != null) _jumpToLine(parsed, controller);
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
  }
}

/// 行号列：稳定渲染 1..N，同时把搜索匹配行用高亮点标出。
class _CodeLineNumbers extends StatelessWidget {
  const _CodeLineNumbers({
    required this.lineCount,
    required this.searchMatches,
    required this.activeMatch,
    required this.currentLine,
  });

  final int lineCount;
  final List<int> searchMatches;
  final int activeMatch;
  final int currentLine;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final matchSet = searchMatches.toSet();
    return Container(
      key: const Key('code-viewer-line-numbers'),
      width: 44,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        border: Border(
          right: BorderSide(color: colors.border, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var line = 1; line <= lineCount; line += 1)
            Container(
              height: 20,
              padding: const EdgeInsets.only(right: 8),
              color: matchSet.contains(line)
                  ? colors.warning.withValues(alpha: 0.18)
                  : null,
              child: Text(
                '$line',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: line == currentLine
                      ? Theme.of(context).colorScheme.primary
                      : colors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 代码正文列：逐行轻量语法高亮，长行可横向滚动。
class _CodeTextColumn extends StatelessWidget {
  const _CodeTextColumn({
    required this.lines,
    required this.activeMatchLine,
    required this.highlight,
  });

  final List<String> lines;
  final int? activeMatchLine;
  final CodeSyntaxHighlighter highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final baseStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.4,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final keywordStyle = baseStyle?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    );
    final stringStyle = baseStyle?.copyWith(color: colors.success);
    final commentStyle = baseStyle?.copyWith(color: colors.textSecondary);
    final numberStyle = baseStyle?.copyWith(color: colors.warning);
    return Column(
      key: const Key('code-viewer-text-column'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < lines.length; index += 1)
          Container(
            height: 20,
            padding: const EdgeInsets.only(left: 8, right: 16),
            // 行宽自适应内容：不再固定 960 制造"滚动虚空"，
            // 横向滚动范围收敛到最长行；高亮带随文本长度而非画布宽度。
            color: index + 1 == activeMatchLine
                ? colors.warning.withValues(alpha: 0.22)
                : null,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                children: highlight.highlightLine(
                  lines[index],
                  style: baseStyle ?? const TextStyle(),
                  keywordStyle: keywordStyle ?? const TextStyle(),
                  stringStyle: stringStyle ?? const TextStyle(),
                  commentStyle: commentStyle ?? const TextStyle(),
                  numberStyle: numberStyle ?? const TextStyle(),
                ),
              ),
              maxLines: 1,
              overflow: TextOverflow.clip,
            ),
          ),
      ],
    );
  }
}

/// 搜索条：显示匹配计数并支持上一个/下一个循环跳转。
class _CodeSearchBar extends StatelessWidget {
  const _CodeSearchBar({
    required this.controller,
    required this.textController,
    required this.onStep,
    required this.onJump,
  });

  final CodeViewerController controller;
  final TextEditingController textController;
  final void Function(bool forward) onStep;
  final void Function(int line) onJump;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('code-viewer-search-bar'),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Row(
      children: [
        IconButton(
          key: const Key('code-viewer-search-close'),
          tooltip: '关闭搜索',
          onPressed: () => controller.search(''),
          icon: const Icon(Icons.close, size: 18),
        ),
        Expanded(
          child: Text(
            controller.matchCount == 0
                ? '无匹配'
                : '${controller.activeMatchIndex + 1}/${controller.matchCount}',
            key: const Key('code-viewer-search-count'),
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        IconButton(
          tooltip: '上一个匹配',
          onPressed: controller.matchCount == 0
              ? null
              : () => onStep(false),
          icon: const Icon(Icons.keyboard_arrow_up),
        ),
        IconButton(
          tooltip: '下一个匹配',
          onPressed: controller.matchCount == 0
              ? null
              : () => onStep(true),
          icon: const Icon(Icons.keyboard_arrow_down),
        ),
      ],
    ),
  );
}

/// 二进制/超大文件的受限摘要视图。
class _CodeLimitedView extends StatelessWidget {
  const _CodeLimitedView({required this.content});

  final WorkspaceFileContent content;

  @override
  Widget build(BuildContext context) {
    final label = switch (content.limitedKind) {
      WorkspaceFileLimitedKind.binary => '二进制文件，不提供代码视图。',
      WorkspaceFileLimitedKind.tooLarge => '文件过大，仅显示受限摘要。',
      WorkspaceFileLimitedKind.none => '',
    };
    return Center(
      key: const Key('code-viewer-limited'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.visibility_off_outlined, size: 32),
            const SizedBox(height: 12),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _CodeViewerError extends StatelessWidget {
  const _CodeViewerError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('code-viewer-error'),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 32),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          IconButton(
            tooltip: '重试读取代码',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
}
