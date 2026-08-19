import 'package:flutter/material.dart';

import '../../../domain/session_projection_models.dart';
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
    this.footer = const [],
    this.openFile,
    this.onInspectTarget,
    super.key,
  });

  final List<ConversationNode> nodes;
  final bool running;
  final Widget? emptyHero;
  final List<Widget> footer;
  final SessionFileOpener? openFile;
  final SessionInspectTargetHandler? onInspectTarget;

  @override
  State<SessionChatView> createState() => _SessionChatViewState();
}

class _SessionChatViewState extends State<SessionChatView> {
  final _controller = ScrollController();
  bool _readerPinnedToBottom = true;
  int _fileOpenEpoch = 0;
  _FileOpenError? _fileOpenError;
  String? _fileOpenBusyPath;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_captureReaderPosition);
    _scrollToBottom();
  }

  @override
  void didUpdateWidget(covariant SessionChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLast = oldWidget.nodes.isEmpty ? null : oldWidget.nodes.last;
    final nextLast = widget.nodes.isEmpty ? null : widget.nodes.last;
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

  @override
  void dispose() {
    _controller.removeListener(_captureReaderPosition);
    _controller.dispose();
    super.dispose();
  }

  void _captureReaderPosition() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    _readerPinnedToBottom = position.maxScrollExtent - position.pixels <= 24;
    setState(() {});
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
      if (widget.emptyHero != null) widget.emptyHero!,
      for (final node in widget.nodes)
        SessionChatNodeSeat(
          node: node,
          onOpenFile: _requestOpenFile,
          onInspect: widget.onInspectTarget,
        ),
      if (widget.running) const _TurnStatusRow(),
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
