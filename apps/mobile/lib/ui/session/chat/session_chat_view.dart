import 'package:flutter/material.dart';

import '../../../domain/session_projection_models.dart';
import 'session_chat_node_seat.dart';

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
    super.key,
  });

  final List<ConversationNode> nodes;
  final bool running;
  final Widget? emptyHero;
  final List<Widget> footer;

  @override
  State<SessionChatView> createState() => _SessionChatViewState();
}

class _SessionChatViewState extends State<SessionChatView> {
  final _controller = ScrollController();
  bool _readerPinnedToBottom = true;

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

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      if (widget.emptyHero != null) widget.emptyHero!,
      for (final node in widget.nodes) SessionChatNodeSeat(node: node),
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
      ],
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
