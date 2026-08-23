import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/session_projection_models.dart';
import '../../../state/session_message_feedback_controller.dart';
import 'session_chat_node_seat.dart';

typedef SessionFileOpener = Future<void> Function(String path);
typedef SessionInspectTargetHandler = void Function(String target);

/// v0.5 Chat view：唯一消费 `ConversationNode` 投影的消息流入口。
///
/// 该组件不接收 raw timeline event；pending interaction 已在投影层排除，并由 composer chain 处理。
/// 滚动策略先覆盖 P2 的基础契约：用户在底部时跟随新尾部，用户上滚后暂停跟随，新增用户消息强制回到底部。
class SessionChatView extends StatefulWidget {
  const SessionChatView({
    required this.nodes,
    required this.running,
    this.emptyHero,
    this.leading,
    this.footer = const [],
    this.openFile,
    this.onInspectTarget,
    this.onFork,
    this.initialScrollOffset = 0,
    this.onScrollOffsetChanged,
    this.historyLoading = false,
    this.historyError,
    this.canLoadOlder = false,
    this.onLoadOlder,
    this.feedbackController,
    super.key,
  });

  final List<ConversationNode> nodes;
  final bool running;
  final Widget? emptyHero;

  /// 位于消息流上方的会话级控制带（如子会话面板）。它属于 Chat 投影上下文，
  /// 不参与 conversation node 流，也避免被滚动到底部时挤出视口。
  final Widget? leading;
  final List<Widget> footer;
  final SessionFileOpener? openFile;
  final SessionInspectTargetHandler? onInspectTarget;
  final SessionForkHandler? onFork;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;
  final bool historyLoading;
  final String? historyError;
  final bool canLoadOlder;
  final Future<void> Function()? onLoadOlder;
  final SessionMessageFeedbackController? feedbackController;

  @override
  State<SessionChatView> createState() => _SessionChatViewState();
}

class _SessionChatViewState extends State<SessionChatView> {
  late final ScrollController _controller;
  bool _readerPinnedToBottom = true;
  int _fileOpenEpoch = 0;
  _FileOpenError? _fileOpenError;
  String? _fileOpenBusyPath;
  final Map<String, GlobalKey> _nodeAnchorKeys = {};

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    );
    _controller.addListener(_captureReaderPosition);
    widget.feedbackController?.addListener(_feedbackChanged);
    if (widget.initialScrollOffset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients) return;
        _controller.jumpTo(
          widget.initialScrollOffset.clamp(
            0,
            _controller.position.maxScrollExtent,
          ),
        );
      });
    } else {
      _scrollToBottom();
    }
  }

  @override
  void didUpdateWidget(covariant SessionChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLast = oldWidget.nodes.isEmpty ? null : oldWidget.nodes.last;
    final nextLast = widget.nodes.isEmpty ? null : widget.nodes.last;
    final oldFirstKey = oldWidget.nodes.firstOrNull?.key;
    final prependCount = oldFirstKey == null
        ? 0
        : widget.nodes.indexWhere((node) => node.key == oldFirstKey);
    if (prependCount > 0 && _controller.hasClients) {
      final beforePixels = _controller.position.pixels;
      final anchor = _firstVisibleNodeAnchor(oldWidget.nodes);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients || anchor == null) return;
        final anchorContext = _nodeAnchorKeys[anchor.key]?.currentContext;
        final box = anchorContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.attached) return;
        final delta = box.localToGlobal(Offset.zero).dy - anchor.globalY;
        _controller.jumpTo(
          (beforePixels + delta).clamp(0, _controller.position.maxScrollExtent),
        );
      });
      return;
    }
    final appended =
        oldLast?.key != nextLast?.key ||
        oldWidget.nodes.length != widget.nodes.length ||
        oldWidget.running != widget.running;
    final appendedUser =
        nextLast?.kind == ConversationNodeKind.user &&
        oldLast?.key != nextLast?.key;
    if (appended && (_readerPinnedToBottom || appendedUser)) {
      _scrollToBottom();
    }
  }

  ({String key, double globalY})? _firstVisibleNodeAnchor(
    List<ConversationNode> nodes,
  ) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    for (final node in nodes) {
      final anchorContext = _nodeAnchorKeys[node.key]?.currentContext;
      final box = anchorContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom >= 0 && top <= viewportHeight) {
        return (key: node.key, globalY: top);
      }
    }
    return null;
  }

  @override
  void dispose() {
    widget.feedbackController?.removeListener(_feedbackChanged);
    if (_controller.hasClients) {
      widget.onScrollOffsetChanged?.call(_controller.position.pixels);
    }
    _controller.removeListener(_captureReaderPosition);
    _controller.dispose();
    super.dispose();
  }

  void _feedbackChanged() {
    if (mounted) setState(() {});
  }

  void _captureReaderPosition() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final pinned = position.maxScrollExtent - position.pixels <= 24;
    widget.onScrollOffsetChanged?.call(position.pixels);
    if (pinned == _readerPinnedToBottom) return;
    setState(() => _readerPinnedToBottom = pinned);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_controller.hasClients) return;
      _controller.animateTo(
        _controller.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
      _readerPinnedToBottom = true;
    });
  }

  Future<void> _requestOpenFile(String path) async {
    final opener = widget.openFile;
    final epoch = ++_fileOpenEpoch;
    setState(() {
      _fileOpenBusyPath = path;
      _fileOpenError = null;
    });
    try {
      if (opener == null) {
        throw StateError('当前环境不支持从会话直接打开路径。');
      }
      await opener(path);
      if (!mounted || epoch != _fileOpenEpoch) return;
      setState(() {
        _fileOpenBusyPath = null;
        _fileOpenError = null;
      });
    } catch (error) {
      if (!mounted || epoch != _fileOpenEpoch) return;
      setState(() {
        _fileOpenBusyPath = null;
        _fileOpenError = _FileOpenError(path: path, message: '$error');
      });
    }
  }

  void _closeFileOpenError() {
    _fileOpenEpoch += 1;
    setState(() {
      _fileOpenBusyPath = null;
      _fileOpenError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (widget.leading != null) widget.leading!,
      if (widget.historyLoading)
        const _HistoryLoadingRow()
      else if (widget.historyError != null)
        _HistoryErrorRow(
          message: widget.historyError!,
          onRetry: widget.onLoadOlder,
        )
      else if (widget.canLoadOlder)
        _HistoryLoadOlderRow(onLoadOlder: widget.onLoadOlder),
      if (widget.emptyHero != null) widget.emptyHero!,
      for (final node in widget.nodes)
        KeyedSubtree(
          key: _nodeAnchorKeys.putIfAbsent(node.key, GlobalKey.new),
          child: SessionChatNodeSeat(
            node: node,
            onOpenFile: _requestOpenFile,
            onInspect: widget.onInspectTarget,
            onFork: widget.onFork,
            feedbackController: widget.feedbackController,
          ),
        ),
      ...widget.footer,
    ];
    return Stack(
      children: [
        ListView.separated(
          key: const Key('session-chat-view'),
          controller: _controller,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) => children[index],
        ),
        // v0.5/回归修复：streaming 状态行固定为一个可见 overlay，而不是懒加载列表项。
        // 这样即使滚动到底部时 footer（如子会话面板）较高，streaming indicator 也始终在树中，
        // 不会因为 ListView 未 build 视口外的行而被测试或用户跳过。
        if (widget.running)
          Positioned(left: 16, right: 16, bottom: 12, child: _TurnStatusRow()),
        if (!_readerPinnedToBottom)
          Positioned(
            right: 18,
            bottom: 18,
            child: FloatingActionButton.small(
              key: const Key('session-chat-to-bottom-button'),
              tooltip: '回到底部',
              onPressed: _scrollToBottom,
              child: const Icon(Icons.keyboard_arrow_down),
            ),
          ),
        if (_fileOpenBusyPath != null)
          Positioned(
            left: 18,
            bottom: 18,
            child: _FileOpenStatus(path: _fileOpenBusyPath!),
          ),
        if (_fileOpenError != null)
          Positioned.fill(
            child: _FileOpenErrorDialog(
              error: _fileOpenError!,
              onClose: _closeFileOpenError,
              onRetry: () => _requestOpenFile(_fileOpenError!.path),
            ),
          ),
      ],
    );
  }
}

class _HistoryLoadingRow extends StatelessWidget {
  const _HistoryLoadingRow();

  @override
  Widget build(BuildContext context) => const Center(
    key: Key('session-chat-history-loading'),
    child: Padding(
      padding: EdgeInsets.all(12),
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}

class _HistoryErrorRow extends StatelessWidget {
  const _HistoryErrorRow({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => ListTile(
    key: const Key('session-chat-history-error'),
    leading: const Icon(Icons.error_outline),
    title: Text(message),
    trailing: TextButton(
      key: const Key('session-chat-history-retry'),
      onPressed: onRetry == null ? null : () => unawaited(onRetry!()),
      child: const Text('重试'),
    ),
  );
}

class _HistoryLoadOlderRow extends StatelessWidget {
  const _HistoryLoadOlderRow({required this.onLoadOlder});

  final Future<void> Function()? onLoadOlder;

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton.icon(
      key: const Key('session-chat-load-older'),
      onPressed: onLoadOlder == null ? null : () => unawaited(onLoadOlder!()),
      icon: const Icon(Icons.history),
      label: const Text('加载更早消息'),
    ),
  );
}

class _FileOpenError {
  const _FileOpenError({required this.path, required this.message});

  final String path;
  final String message;
}

class _FileOpenStatus extends StatelessWidget {
  const _FileOpenStatus({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('session-file-open-busy'),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('正在打开 $path'),
        ],
      ),
    ),
  );
}

class _FileOpenErrorDialog extends StatelessWidget {
  const _FileOpenErrorDialog({
    required this.error,
    required this.onClose,
    required this.onRetry,
  });

  final _FileOpenError error;
  final VoidCallback onClose;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AlertDialog(
            key: const Key('session-file-open-error-dialog'),
            title: const Text('无法打开路径'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  error.path,
                  key: const Key('session-file-open-error-path'),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                Text(
                  error.message,
                  key: const Key('session-file-open-error-message'),
                  style: TextStyle(color: scheme.error),
                ),
              ],
            ),
            actions: [
              TextButton(
                key: const Key('session-file-open-close'),
                onPressed: onClose,
                child: const Text('关闭'),
              ),
              FilledButton(
                key: const Key('session-file-open-retry'),
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TurnStatusRow extends StatelessWidget {
  const _TurnStatusRow();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('session-turn-status-row'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Row(
          children: [
            SizedBox.square(
              key: const Key('assistant-streaming-indicator'),
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(child: Text('模型仍在处理当前轮次...')),
          ],
        ),
      ),
    );
  }
}
