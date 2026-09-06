import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';

import '../../../domain/session_models.dart';
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
    this.turnPhase,
    this.turnTimedOut = false,
    this.timeoutFreshnessText,
    this.onViewResult,
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
  /// v0.8.4（ADR-015 §3）：最近的回合相位；null 时状态行回退通用生成态文案。
  final TurnPhase? turnPhase;

  /// v0.8.6 A①：客户端判定回合超时（轮询窗口耗尽仍无终态）。为 true 时用
  /// 显式超时横幅替代"处理中"状态条，不再无限转圈；迟到的终态事实事件
  /// 到达后 controller 会按事件校正清除该标记。
  final bool turnTimedOut;

  /// v0.9.0 C3：超时横幅次级行的事件新鲜度文案（最近一次成功合并的客户端时刻）。
  final String? timeoutFreshnessText;

  /// v0.9.0 C3：「查看结果」手动出口（controller.refreshTurnResult）。
  final Future<void> Function()? onViewResult;
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
        if (widget.turnTimedOut)
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: _TurnTimeoutRow(
              freshnessText: widget.timeoutFreshnessText,
              onViewResult: widget.onViewResult,
            ),
          )
        else if (widget.running)
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: _TurnStatusRow(phase: widget.turnPhase),
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
  Widget build(BuildContext context) => Container(
    key: const Key('session-file-open-busy'),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
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
      color: Theme.of(context).colorScheme.scrim.withValues(
        alpha: AppOpacity.scrim,
      ),
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

/// v0.9.0 C1/C3：回合超时横幅。UX deadline（锚点 + 2 分钟）到达仍无 canonical
/// 终态时替代"处理中"状态条：明确"等待结果已超时，仍在同步"（同步未停止——
/// L1 降频续轮/L3/SSE 仍会发现迟到事实）；次级行展示事件新鲜度（T5 裁决），
/// 并提供「查看结果」手动出口（强制一次快照同步，成功只在真实事实到达时清横幅）。
class _TurnTimeoutRow extends StatelessWidget {
  const _TurnTimeoutRow({this.freshnessText, this.onViewResult});

  /// 最近一次成功合并事件的展示文案（客户端时刻）；null 时不显示次级行。
  final String? freshnessText;

  /// 「查看结果」回调；null 时按钮隐藏（例如控制器尚未就绪）。
  final Future<void> Function()? onViewResult;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('session-turn-timeout-row'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
          color: theme.colorScheme.errorContainer,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timer_off_outlined,
                    size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '等待结果已超时，仍在同步。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
            if (freshnessText != null)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 2),
                child: Text(
                  freshnessText!,
                  key: const Key('session-turn-timeout-freshness'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (onViewResult != null)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('session-turn-timeout-view-result'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => onViewResult!(),
                    icon: Icon(
                      Icons.sync_outlined,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    label: const Text('查看结果'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// v0.8.4（ADR-015 §3）：phase-aware 状态行。取代固定的"模型仍在处理当前轮次"：
/// 有 phase 投影时展示对应可见文案（思考中/生成中/工具执行中/等待交互/收尾/取消），
/// 无投影（旧桥/旧会话）时回退通用文案，行为与 v0.8.3 完全一致。
/// 终态相位（completed/cancelled/failed）不由该常驻行展示——终态收敛由
/// running=false 关闭状态行与消息气泡本身表达，避免终态文案残留闪烁。
class _TurnStatusRow extends StatelessWidget {
  const _TurnStatusRow({this.phase});

  final TurnPhase? phase;

  @override
  Widget build(BuildContext context) {
    final label = switch (phase) {
      null => '模型仍在处理当前轮次...',
      TurnPhase.queued => '排队中...',
      TurnPhase.preparing => '正在准备新一轮...',
      TurnPhase.thinking => '思考中...',
      TurnPhase.streaming => '生成中...',
      TurnPhase.toolRunning => '工具执行中...',
      TurnPhase.waitingPermission => '等待权限确认...',
      TurnPhase.waitingQuestion => '等待你的回答...',
      TurnPhase.finishing => '收尾中...',
      TurnPhase.cancelling => '正在取消...',
      // 终态相位不常驻展示：running 会随终态关闭，此行随即消失。
      _ => '模型仍在处理当前轮次...',
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('session-turn-status-row'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.card),
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
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}
