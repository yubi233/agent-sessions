import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/providers.dart';
import '../../../domain/composer_preferences.dart';
import '../../../domain/control_models.dart';
import '../../../domain/session_input_grammar.dart';
import '../../../domain/session_models.dart';
import '../../../state/session_composer_controller.dart';
import '../../../state/session_controller.dart';
import '../../../state/session_turn_runtime.dart';
import '../../app_theme.dart';
import 'session_composer_chain.dart';
import 'session_model_seat.dart';
import 'session_queue_dock.dart';
import 'session_todo_dock.dart';

/// 会话 composer 面板：输入区、@补全、命令菜单、控制条、附件队列与技能确认卡。
/// 从 session_screens.dart 拆出（架构收口）；仅被 SessionDetailScreen 消费，
/// 其余组件保持库私有。
/// 确认卡是会话详情的一部分，而非 Provider 结果。拒绝只清空本地状态，确认才进入带 lease 的命令链路。
class _SkillConfirmationCard extends StatelessWidget {
  const _SkillConfirmationCard({
    required this.confirmation,
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SkillConfirmation confirmation;
  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final blocked = sessions.controlBlockedReason(
      'invoke_skill',
      canWrite: canWrite,
    );
    return Container(
      key: const Key('skill-confirmation-card'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: context.appColors.warning),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.micro),
            child: Icon(
              Icons.warning_amber_outlined,
              color: context.appColors.warning,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  confirmation.skill.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.micro),
                Text(
                  confirmation.skill.summary,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (blocked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      blocked,
                      key: const Key('skill-confirmation-blocked-reason'),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('skill-confirmation-reject-button'),
            tooltip: '拒绝 Skill',
            onPressed: sessions.isBusy
                ? null
                : sessions.rejectSkillConfirmation,
            icon: const Icon(Icons.close),
          ),
          IconButton(
            key: const Key('skill-confirmation-approve-button'),
            tooltip: '确认 Skill',
            onPressed: blocked == null && !sessions.isBusy
                ? () => sessions.confirmSkill(
                    deviceId: deviceId,
                    canWrite: canWrite,
                  )
                : null,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
    );
  }
}

class SessionComposerPanel extends StatefulWidget {
  const SessionComposerPanel({
    super.key,
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
    required this.interactionEvents,
    this.enterBehavior = ComposerEnterBehavior.queue,
    this.fileCompletionCatalog,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;
  final List<SessionTimelineEvent> interactionEvents;

  /// v0.5/P5：busy Enter 分流偏好（用户级设置，默认 Queue）。composer 与设置页
  /// 读取同一个 [composerPreferenceControllerProvider] 事实来源。
  final ComposerEnterBehavior enterBehavior;

  /// v0.2/P3：@ 补全的文件名目录；fixture 返回安全名，真实 Daemon RPC 未部署时为空（fail-closed）。
  final Future<List<String>> Function()? fileCompletionCatalog;

  @override
  State<SessionComposerPanel> createState() => _SessionComposerState();
}

/// 补全候选：type 区分文件与 Skill。
enum _CompletionKind { file, skill }

class _CompletionSuggestion {
  const _CompletionSuggestion({
    required this.kind,
    required this.label,
    required this.insertText,
  });

  final _CompletionKind kind;
  final String label;
  final String insertText;
}

class _SessionComposerState extends State<SessionComposerPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _inputScrollController = ScrollController();
  String? _draftSessionId;
  SessionComposerInputMachine _inputMachine = SessionComposerInputMachine();
  int _queueSeq = 0;
  bool _commandMenuOpen = false;
  // v0.2/P3：@ 与 / 自动补全只在内存生成；候选为空或查询越权时展示空态（fail-closed）。
  List<_CompletionSuggestion> _suggestions = const [];
  bool _suggestionsLoading = false;
  // 最近一次输入是否以 @ 或 / 触发补全；即使候选为空也展示空态说明（fail-closed）。
  bool _completionActive = false;
  // v0.5/P5：增量输入 revision；每次草稿变化 +1，供异步候选 CAS 判断是否过期。
  int _draftRev = 0;
  // 异步候选 generation：旧请求返回时若 generation 已变则 no-op，避免 stale pick 写入。
  int _suggestionsGeneration = 0;
  // 最近一次 selection-based 探测到的活跃 trigger（用于 span 替换与键盘导航）。
  InputTriggerHit? _activeTrigger;
  // 键盘导航中高亮的候选下标（-1 = 未选中）。
  int _selectedSuggestionIndex = -1;
  // 上次触发重新探测时的 caret 位置，用于 selection 变化去重。
  int? _lastCaret;

  /// v0.5/P5：把用户级 Enter 偏好映射为 InputMachine 的 busy enter 策略。
  BusyEnterMode get _enterBusyMode => switch (widget.enterBehavior) {
    ComposerEnterBehavior.queue => BusyEnterMode.queue,
    ComposerEnterBehavior.steer => BusyEnterMode.steer,
  };

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (_, event) => _handleComposerKey(event);
    // v0.5/P5：光标移动（selection 变化）也要按新位置重新探测 trigger，
    // 满足「候选按 selection + draft revision 定位」契约；借助 controller listener。
    _controller.addListener(_onControllerSelectionChanged);
    // 切换会话后恢复该会话的跨页内存草稿（不落明文盘）。
    _restoreDraft();
  }

  @override
  void didUpdateWidget(covariant SessionComposerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessions.selectedSessionId !=
        widget.sessions.selectedSessionId) {
      // Persist the complete session-scoped input before switching. In-flight
      // attempts are intentionally discarded by the new machine instance.
      final priorSessionId = _draftSessionId;
      if (priorSessionId != null) {
        widget.sessions.saveComposerState(
          priorSessionId,
          _inputMachine.sessionState,
        );
      }
      _inputMachine = SessionComposerInputMachine();
      _restoreDraft();
      _commandMenuOpen = false;
    }
  }

  void _restoreDraft() {
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId == null) {
      _draftSessionId = null;
      _inputMachine.restoreSessionState(
        const SessionComposerSessionState.empty(),
      );
      _setControllerText('');
      return;
    }
    if (_draftSessionId == sessionId) return;
    _draftSessionId = sessionId;
    final state = widget.sessions.composerStateFor(sessionId);
    _inputMachine.restoreSessionState(state);
    if (state.draft != _controller.text) {
      _setControllerText(state.draft);
    }
  }

  void _setControllerText(String text) {
    _controller.text = text;
    // 光标移到末尾，让用户直接继续输入。
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
  }

  @override
  void dispose() {
    // 页面销毁前把当前输入保存为内存草稿，保证跨页返回后内容不丢失。
    final sessionId = widget.sessions.selectedSessionId ?? _draftSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
    _controller.removeListener(_onControllerSelectionChanged);
    _focusNode.dispose();
    _inputScrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  KeyEventResult _handleComposerKey(KeyEvent event) {
    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final shortcut =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;

    if (event is KeyDownEvent && shortcut) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        final changed = HardwareKeyboard.instance.isShiftPressed
            ? _inputMachine.redo()
            : _inputMachine.undo();
        if (changed) _syncControllerFromMachine();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyC ||
          event.logicalKey == LogicalKeyboardKey.keyX) {
        final selection = _controller.selection;
        if (!selection.isValid || selection.isCollapsed) {
          return KeyEventResult.ignored;
        }
        unawaited(
          _copyOrCutSelection(cut: event.logicalKey == LogicalKeyboardKey.keyX),
        );
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        unawaited(_pasteClipboard());
        return KeyEventResult.handled;
      }
    }

    if (event is KeyDownEvent &&
        !shortcut &&
        (event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey == LogicalKeyboardKey.delete)) {
      final selection = _controller.selection;
      if (selection.isValid &&
          selection.isCollapsed &&
          _inputMachine.deleteReferenceNearCaret(
            caret: selection.extentOffset,
            backwards: event.logicalKey == LogicalKeyboardKey.backspace,
          )) {
        _syncControllerFromMachine(caret: selection.extentOffset);
        return KeyEventResult.handled;
      }
    }

    // v0.5/P5：候选菜单键盘导航（up/down 移动、Escape 关闭、Enter 应用高亮项）。
    // 只在候选打开且 trigger 仍活跃时接管方向键/Escape/Enter；焦点保持在输入上下文。
    if (_completionActive &&
        _suggestions.isNotEmpty &&
        _activeTrigger != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (event is KeyDownEvent) {
          final delta = event.logicalKey == LogicalKeyboardKey.arrowDown
              ? 1
              : -1;
          setState(() {
            _selectedSuggestionIndex += delta;
            if (_selectedSuggestionIndex >= _suggestions.length) {
              _selectedSuggestionIndex = 0;
            } else if (_selectedSuggestionIndex < 0) {
              _selectedSuggestionIndex = _suggestions.length - 1;
            }
          });
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) _updateSuggestions();
        return KeyEventResult.handled;
      }
      if (enter && event is KeyDownEvent) {
        // 高亮项存在时 Enter 应用候选；否则交回普通提交路径。
        if (_selectedSuggestionIndex >= 0 &&
            _selectedSuggestionIndex < _suggestions.length) {
          _applySuggestion(_suggestions[_selectedSuggestionIndex]);
          _selectedSuggestionIndex = -1;
          return KeyEventResult.handled;
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.escape &&
        event is KeyDownEvent) {
      // 非候选场景：Escape 先关闭 command launcher 菜单，再交给输入状态机。
      if (_commandMenuOpen) {
        setState(() {
          _commandMenuOpen = false;
          _updateSuggestions();
        });
        return KeyEventResult.handled;
      }
    }

    if (!enter) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;

    // Shift+Enter 永远留给 TextField 原生换行，优先级高于 IME 和提交锁。
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    // 长按 Enter 的 repeat 事件只消费不提交，避免重复写入 Relay 或 queue。
    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final composing = _controller.value.composing;
    // IME 候选确认期间 Enter 只能交给输入法，不触发会话提交。
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.handled;
    }

    final snapshot = _inputMachine.snapshot;
    final machineBusy =
        snapshot.phase == SessionInputPhase.adjudicating ||
        snapshot.phase == SessionInputPhase.submitting;
    final blocked = widget.sessions.composerBlockedReason(
      canWrite: widget.canWrite,
    );
    if (blocked != null || widget.sessions.isBusy || machineBusy) {
      return KeyEventResult.handled;
    }

    final accelerated =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    final mode = _inputMachine.submit(
      running: widget.sessions.isStreaming,
      accelerated: accelerated,
      busyEnter: _enterBusyMode,
    );
    if (mode == null) return KeyEventResult.handled;

    unawaited(_submitComposer(accelerated: accelerated));
    return KeyEventResult.handled;
  }

  /// caret 移动监听：文本未变但 selection 变化时，也按新位置重新探测 trigger。
  /// 只在确实发生 selection 变化时才刷新，避免应用补全时的重复触发。
  void _onControllerSelectionChanged() {
    if (!mounted) return;
    final selection = _controller.selection;
    final caret = selection.isValid ? selection.end : null;
    if (caret == null || caret == _lastCaret) return;
    _lastCaret = caret;
    _revealCaret(caret);
    _updateSuggestions();
  }

  void _revealCaret(int caret) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_inputScrollController.hasClients) return;
      if (caret >= _controller.text.length) {
        _inputScrollController.jumpTo(
          _inputScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  /// v0.5/P5：基于 caret（selection）+ draftRev 重新探测 Input Trigger。
  ///
  /// 由 TextField onChanged / 光标移动触发；不再按最后一个空格截 token。
  /// - 命中 trigger：`/` 走 skill 源，`@` 走文件目录源（异步 + CAS）；
  /// - 未命中或 caret 移出 token：静默关闭候选（outside dismiss）；
  /// - 源不可用 / 源被移除：静默移除对应候选组并刷新 lexicon，不展示伪错误项。
  void _updateSuggestions() {
    if (!mounted) return;
    final text = _controller.text;
    final selection = _controller.selection;
    final caret = selection.isValid ? selection.end : text.length;
    _draftRev += 1;
    final hit = detectInputTrigger(
      text,
      caret,
      claimed: _inputMachine.snapshot.claimToken != null,
    );
    _activeTrigger = hit;
    if (hit == null) {
      _completionActive = false;
      _suggestionsGeneration += 1;
      _setSuggestions(const []);
      _selectedSuggestionIndex = -1;
      setState(() => {});
      return;
    }
    _completionActive = true;
    _selectedSuggestionIndex = -1;
    if (hit.isSlash) {
      // Skill 建议：只使用 controls.skills 的标题，不读取任何参数或 Provider payload。
      final query = hit.query.toLowerCase();
      final skills = widget.sessions.controls.skills
          .where((skill) => skill.title.toLowerCase().contains(query))
          .map(
            (skill) => _CompletionSuggestion(
              kind: _CompletionKind.skill,
              label: 'Skill · ${skill.title}',
              insertText: '/${skill.title} ',
            ),
          )
          .toList(growable: false);
      _setSuggestions(skills);
      return;
    }
    // `@` 引用：越权路径（绝对路径、..、路径分隔、隐藏）不产生任何建议。
    final query = hit.query;
    if (!_isSafeSuggestionName(query)) {
      _setSuggestions(const []);
      return;
    }
    final catalog = widget.fileCompletionCatalog;
    if (catalog == null) {
      // 源未注册/被移除：静默关闭，不展示伪错误候选。
      _setSuggestions(const []);
      return;
    }
    _suggestionsGeneration += 1;
    final generation = _suggestionsGeneration;
    final rev = _draftRev;
    _suggestionsLoading = true;
    setState(() {});
    unawaited(_loadFileSuggestions(query, generation: generation, rev: rev));
  }

  /// 异步加载文件补全候选（目录不可用或越权查询时返回空）。
  ///
  /// 用 [generation] / [rev] CAS：过期请求（draft 已变或已切源）返回时 no-op，
  /// 避免 stale pick 写入新位置。
  Future<void> _loadFileSuggestions(
    String query, {
    required int generation,
    required int rev,
  }) async {
    List<String> names = const [];
    final catalog = widget.fileCompletionCatalog;
    if (catalog != null) {
      try {
        names = await catalog();
      } catch (_) {
        names = const [];
      }
    }
    if (!mounted) return;
    // CAS：只有仍是同一 generation 且 draftRev 未变迁时才允许落地候选。
    if (generation != _suggestionsGeneration || rev != _draftRev) return;
    final filtered = names
        .where(
          (name) =>
              name.toLowerCase().contains(query) && _isSafeSuggestionName(name),
        )
        .map(
          (name) => _CompletionSuggestion(
            kind: _CompletionKind.file,
            label: '文件 · $name',
            insertText: '@$name ',
          ),
        )
        .toList(growable: false);
    _suggestionsLoading = false;
    _setSuggestions(filtered);
  }

  /// 补全候选名安全校验：拒绝绝对路径、分隔符、隐藏与形如 `user@host` 的查询。
  bool _isSafeSuggestionName(String name) {
    if (name.trim().isEmpty || name.startsWith('/') || name.contains(':')) {
      return false;
    }
    if (name.contains('/') || name.contains('..')) return false;
    if (name.startsWith('.')) return false;
    return true;
  }

  void _setSuggestions(List<_CompletionSuggestion> next) {
    if (!mounted) return;
    setState(() => _suggestions = next);
  }

  /// 应用补全：只替换 [activeTrigger] 的 span，不做全文 token 重建。
  void _applySuggestion(_CompletionSuggestion suggestion) {
    final text = _controller.text;
    final hit = _activeTrigger;
    if (hit == null) {
      _updateSuggestions();
      return;
    }
    var replacement = suggestion.insertText;
    // 行内补全时若插入文本自带尾随空格、且目标位置后紧跟空白，去掉一个尾部空格，
    // 避免「@README.md + 原有空格」重复成两个空格（span 替换仍只动 trigger 段）。
    if (hit.end < text.length) {
      final after = text[hit.end];
      if (replacement.endsWith(' ') &&
          (after == ' ' || after == '\t' || after == '\n')) {
        replacement = replacement.substring(0, replacement.length - 1);
      }
    }
    var caret = hit.start + replacement.length;
    if (suggestion.kind == _CompletionKind.file) {
      final label = replacement.trim().replaceFirst('@', '');
      final inserted = _inputMachine.insertReference(
        label: label,
        clipboardText: '@file:$label',
        start: hit.start,
        end: hit.end,
        draftRevision: _inputMachine.snapshot.draftRevision,
      );
      if (!inserted) return;
      final reference = _inputMachine.snapshot.references
          .where((item) => item.offset == hit.start)
          .firstOrNull;
      caret = reference?.end ?? caret;
      final draft = _inputMachine.snapshot.draft;
      if (caret < draft.length && draft[caret] == ' ') caret += 1;
    } else {
      final claimed = _inputMachine.beginCommand(
        token: replacement,
        start: hit.start,
        end: hit.end,
        draftRevision: _inputMachine.snapshot.draftRevision,
      );
      if (!claimed) {
        _inputMachine.setDraft(
          text.replaceRange(hit.start, hit.end, replacement),
        );
      }
    }
    final next = _inputMachine.snapshot.draft;
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret.clamp(0, next.length)),
    );
    setState(() {});
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
    _updateSuggestions();
  }

  void _syncControllerFromMachine({int? caret}) {
    final draft = _inputMachine.snapshot.draft;
    final offset = (caret ?? draft.length).clamp(0, draft.length);
    _controller.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: offset),
    );
    final sessionId = widget.sessions.selectedSessionId;
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
    _updateSuggestions();
    setState(() {});
  }

  Future<void> _copyOrCutSelection({required bool cut}) async {
    final selection = _controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final start = selection.start;
    final end = selection.end;
    final text = cut
        ? _inputMachine.cutRange(start, end)
        : _inputMachine.projectClipboard(start: start, end: end);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted || !cut) return;
    _syncControllerFromMachine(caret: start);
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final pasted = data?.text;
    if (pasted == null || pasted.isEmpty) return;
    final selection = _controller.selection;
    final start = selection.isValid ? selection.start : _controller.text.length;
    final end = selection.isValid ? selection.end : _controller.text.length;
    var upgraded = false;
    if (pasted.startsWith('@file:') && pasted.length > '@file:'.length) {
      final target = pasted.substring('@file:'.length);
      final label = target
          .split('/')
          .where((part) => part.isNotEmpty)
          .lastOrNull;
      if (label != null) {
        upgraded = _inputMachine.pasteUpgradeReference(
          label: label,
          clipboardText: pasted,
          start: start,
          end: end,
          draftRevision: _inputMachine.snapshot.draftRevision,
        );
      }
    }
    if (!upgraded) {
      final current = _inputMachine.snapshot.draft;
      _inputMachine.setDraft(
        current.replaceRange(start, end, pasted),
        start: start,
        end: end,
        insertedLength: pasted.length,
      );
    }
    _syncControllerFromMachine(caret: start + pasted.length);
  }

  void _focusComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final blocked = widget.sessions.composerBlockedReason(
      canWrite: widget.canWrite,
    );
    final streaming = widget.sessions.isStreaming;
    // 回合在途（send 受理即置位，终态/中断/切会话才清除）+ 乐观回显窗口，
    // 两者共同决定"运行中"；不受 status 尚未翻到 streaming 的受理窗口影响。
    final running =
        streaming ||
        widget.sessions.isTurnInFlight ||
        widget.sessions.pendingOutgoingMessage != null;
    final input = _inputMachine.snapshot;
    final submitMode = _inputMachine.submit(
      running: streaming,
      busyEnter: _enterBusyMode,
    );
    final machineBusy =
        input.phase == SessionInputPhase.adjudicating ||
        input.phase == SessionInputPhase.submitting;
    final canSubmit =
        blocked == null &&
        submitMode != null &&
        !widget.sessions.isBusy &&
        !machineBusy;
    final primaryTooltip = switch (submitMode) {
      SessionSubmitMode.queue => '排队消息',
      SessionSubmitMode.steer => '插话',
      SessionSubmitMode.send || null => '发送消息',
    };
    final canStop = blocked == null && running && !widget.sessions.isBusy;
    // 运行中且草稿已清空：主按钮即中断按钮（用户请求：发送后可一键中断当前
    // 任务）。草稿非空时保留 queue/steer 语义，中断走独立停止按钮。
    final primaryIsStop = running && input.draft.trim().isEmpty && canStop;
    final pendingPermission = widget.interactionEvents
        .where((event) => event.kind == SessionTimelineKind.permissionRequest)
        .cast<SessionTimelineEvent?>()
        .firstWhere(
          (event) =>
              event?.permission != null &&
              !widget.sessions.isRequestResolved(
                'permission',
                event!.permission!.requestId,
              ) &&
              !widget.sessions.isRequestPending(event.permission!.requestId),
          orElse: () => null,
        );
    final pendingQuestion = widget.interactionEvents
        .where((event) => event.kind == SessionTimelineKind.questionRequest)
        .cast<SessionTimelineEvent?>()
        .firstWhere(
          (event) =>
              event?.question != null &&
              !widget.sessions.isRequestResolved(
                'question',
                event!.question!.requestId,
              ) &&
              !widget.sessions.isRequestPending(event.question!.requestId),
          orElse: () => null,
        );
    // v0.5/P4/P5：Question/Approval 接管整个 composer seat；
    // input.dock（Todo/Queue）必须让位，避免长 takeover 面板被 dock 挤出可触达区域。
    final hasComposerTakeover =
        pendingQuestion != null || pendingPermission != null;
    // V094-09（计划 §3.1「Todo/Queue 长内容独立限高或进入面板」）：
    // dock 渲染在 composer 容器之外（同一 SafeArea 内的兄弟节点），
    // 使「空/单行 composer 含配置摘要」的 ≤144dp 预算只覆盖输入与配置摘要；
    // dock 保持默认折叠单行（独立限高），不再挤占输入主动作。
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hasComposerTakeover)
            SessionTodoDock(todos: widget.sessions.controls.todos),
          if (input.queue.isNotEmpty)
            SessionQueueDock(
              messages: input.queue,
              onRemove: (id) =>
                  setState(() => _inputMachine.removeQueuedMessage(id)),
              onEdit: (id, text) =>
                  setState(() => _inputMachine.editQueuedMessage(id, text)),
              onSteer: (id) => unawaited(_steerQueuedMessages(id)),
              onSendAll: _sendQueuedMessages,
              running: widget.sessions.isStreaming,
            ),
          Container(
        key: const Key('session-composer'),
        // V094-09：垂直留白收紧（8→4），预算优先给正文与主动作。
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.sessions.skillConfirmation != null)
              _SkillConfirmationCard(
                confirmation: widget.sessions.skillConfirmation!,
                sessions: widget.sessions,
                canWrite: widget.canWrite,
                deviceId: widget.deviceId,
              ),
            if (pendingQuestion != null || pendingPermission != null)
              SessionComposerChain(
                pendingQuestion: pendingQuestion,
                pendingPermission: pendingPermission,
                canWrite: widget.canWrite,
                hasLease: widget.sessions.hasSelectedLease,
                sessions: widget.sessions,
                deviceId: widget.deviceId,
              ),
            if (_commandMenuOpen)
              _CommandLauncherMenu(
                onSelect: (command) {
                  final next = '/$command ';
                  _inputMachine.setDraft(next);
                  _setControllerText(next);
                  _commandMenuOpen = false;
                  final sessionId = widget.sessions.selectedSessionId;
                  if (sessionId != null) {
                    widget.sessions.saveComposerState(
                      sessionId,
                      _inputMachine.sessionState,
                    );
                  }
                  _updateSuggestions();
                  setState(() {});
                },
              ),
            if (widget.sessions.attachments.isNotEmpty ||
                widget.sessions.attachmentRejections.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _AttachmentQueue(
                  sessions: widget.sessions,
                  canWrite: widget.canWrite,
                  deviceId: widget.deviceId,
                ),
              ),
            if (_completionActive || _suggestionsLoading)
              _ComposerSuggestions(
                suggestions: _suggestions,
                loading: _suggestionsLoading,
                onApply: _applySuggestion,
                onDismiss: () => _setSuggestions(const []),
                selectedIndex: _selectedSuggestionIndex,
              ),
            if (blocked != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  blocked,
                  key: const Key('session-composer-blocked-reason'),
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            if (input.notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  input.notice!,
                  key: const Key('session-composer-machine-notice'),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            Container(
              key: const Key('happy-session-composer'),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.7),
                ),
                // 胶囊圆角与投影收口为全局 token，避免第二处硬编码扩散。
                borderRadius: BorderRadius.circular(AppRadius.pill),
                boxShadow: AppShadows.composerPill,
              ),
              // V094-10（计划 §3.1）：正文与工具栏分行——上方全宽输入，
              // 下方工具行；命令/附件不再挤占正文横排宽度。
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('session-composer-input'),
                    controller: _controller,
                      focusNode: _focusNode,
                      scrollController: _inputScrollController,
                      enabled: blocked == null,
                      readOnly: machineBusy,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      scrollPadding: const EdgeInsets.only(
                        bottom: AppLayout.keyboardScrollPadding,
                      ),
                      onTapOutside: (_) {
                        if (_commandMenuOpen || _completionActive) {
                          setState(() {
                            _commandMenuOpen = false;
                            _completionActive = false;
                            _suggestions = const [];
                          });
                        }
                        _focusNode.unfocus();
                      },
                      onChanged: (value) {
                        _inputMachine.setDraft(value);
                        setState(() {});
                        // 每次输入都写内存草稿；发送成功后由 controller 清除。
                        final sessionId = widget.sessions.selectedSessionId;
                        if (sessionId != null) {
                          widget.sessions.saveComposerState(
                            sessionId,
                            _inputMachine.sessionState,
                          );
                        }
                        _updateSuggestions();
                      },
                      decoration: const InputDecoration(
                        hintText: '输入消息...',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: AppSpacing.sm,
                        ),
                      ),
                    ),
                  // V094-09/10：工具行——命令、附件、紧凑权限徽标靠左，
                  // 停止/发送靠右；正文输入占满上一行（≥90% 内容宽）。
                  // 紧凑密度：视觉/命中 40dp（仍不低于可触达下限的实际按钮，
                  // 权限徽标外层保持 48dp 命中区）。
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      IconButton(
                        key: const Key('session-command-launcher'),
                        tooltip: '命令',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          setState(() => _commandMenuOpen = !_commandMenuOpen);
                          _focusComposer();
                        },
                        icon: const Icon(Icons.add),
                      ),
                      IconButton(
                        key: const Key('session-attachment-add-button'),
                        visualDensity: VisualDensity.compact,
                        tooltip:
                            widget.sessions.attachmentPickBlockedReason(
                              canWrite: widget.canWrite,
                            ) ??
                            '选择图片或文本附件',
                        // v0.2/P3：capability + 会话 DEK 均就绪后启用真实选附件；
                        // 无 DEK 时保持 fail-closed，不允许把明文文件或显示名放进 Relay。
                        onPressed:
                            widget.sessions.attachmentPickBlockedReason(
                                      canWrite: widget.canWrite,
                                    ) ==
                                    null &&
                                !widget.sessions.isBusy
                            ? () async {
                                await widget.sessions.pickAttachment(
                                  deviceId: widget.deviceId,
                                  canWrite: widget.canWrite,
                                );
                                _focusComposer();
                              }
                            : null,
                        icon: const Icon(Icons.attach_file),
                      ),
                      _ComposerControlStrip(
                        sessions: widget.sessions,
                        canWrite: widget.canWrite,
                        deviceId: widget.deviceId,
                      ),
                      const Spacer(),
                      IconButton(
                        key: const Key('session-composer-primary-action'),
                    tooltip: primaryIsStop ? '中断当前任务' : primaryTooltip,
                    onPressed: primaryIsStop
                        ? () async {
                            await _stop();
                            _focusComposer();
                          }
                        : canSubmit
                        ? () async {
                            await _submitComposer();
                            _focusComposer();
                          }
                        : null,
                    style: IconButton.styleFrom(
                      backgroundColor: primaryIsStop
                          ? Theme.of(context).colorScheme.errorContainer
                          : canSubmit
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                      foregroundColor: primaryIsStop
                          ? Theme.of(context).colorScheme.error
                          : canSubmit
                          ? Theme.of(context).colorScheme.onPrimary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    icon: Icon(
                      primaryIsStop
                          ? Icons.stop
                          : submitMode == SessionSubmitMode.send
                          ? Icons.arrow_upward
                          : Icons.schedule_send_outlined,
                    ),
                  ),
                      if (running && input.draft.trim().isNotEmpty)
                        IconButton(
                          key: const Key('session-stop-button'),
                          tooltip: '停止生成',
                          visualDensity: VisualDensity.compact,
                          onPressed: canStop
                              ? () async {
                                  await _stop();
                                  _focusComposer();
                                }
                              : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            // V094-09：配置摘要行——模型/effort 目录 seat 一行呈现；
            // 整行权限表单与空 helper 已移除（权限入口在工具行徽标）。
            _HappyComposerMetaRow(
              sessions: widget.sessions,
              canWrite: widget.canWrite,
              deviceId: widget.deviceId,
            ),
          ],
        ),
      ),
        ],
      ),
    );
  }

  bool _isGoalCommand(String message) {
    final trimmed = message.trimLeft();
    return trimmed == '/goal' || trimmed.startsWith('/goal ');
  }

  /// P5-E3：`/goal ...` 是 command-input 创建链路，不能走普通消息发送。
  ///
  /// 成功后 fixture 会先追加 `goal.command_input`，投影为 Chat command node；
  /// 再追加 `goal.created` 并更新模型设置中的 Goal 投影。失败时保留原草稿与 claim。
  Future<void> _submitGoalCommand(
    String message,
    String? sessionId,
    String attemptToken,
  ) async {
    final objective = message.trimLeft().substring('/goal'.length).trim();
    if (objective.isEmpty) {
      _inputMachine.settleSubmit(
        success: false,
        error: '请输入 /goal 后的目标文本。',
        attemptToken: attemptToken,
      );
      _setControllerText(message);
      setState(() {});
      return;
    }
    await widget.sessions.createGoal(
      objective: objective,
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!mounted) return;
    final error = widget.sessions.errorMessage;
    if (error != null) {
      final settled = _inputMachine.settleSubmit(
        success: false,
        error: error,
        attemptToken: attemptToken,
      );
      if (sessionId != null) {
        widget.sessions.saveComposerState(
          sessionId,
          _inputMachine.sessionState,
        );
      }
      _setControllerText(settled ? message : _inputMachine.snapshot.draft);
      setState(() {});
      return;
    }
    final settled = _inputMachine.settleSubmit(
      success: true,
      attemptToken: attemptToken,
    );
    if (!settled) {
      _setControllerText(_inputMachine.snapshot.draft);
      setState(() {});
      return;
    }
    if (sessionId != null) {
      widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
    }
    _setControllerText('');
    _setSuggestions(const []);
    setState(() {});
  }

  Future<void> _submitComposer({bool accelerated = false}) async {
    final snapshot = _inputMachine.snapshot;
    if (snapshot.phase == SessionInputPhase.adjudicating ||
        snapshot.phase == SessionInputPhase.submitting) {
      return;
    }
    final message = snapshot.draft.trim();
    final mode = _inputMachine.submit(
      running: widget.sessions.isStreaming,
      accelerated: accelerated,
      busyEnter: _enterBusyMode,
    );
    if (mode == null || message.isEmpty && mode != SessionSubmitMode.steer) {
      return;
    }
    final sessionId = widget.sessions.selectedSessionId;
    switch (mode) {
      case SessionSubmitMode.queue:
        // v0.5/P3-A：Queue 是显式 transient inbox；入队后只清本地草稿，
        // 不向 Relay 发 send，也不在 streaming 结束后自动 flush。
        _queueSeq += 1;
        _inputMachine.addQueuedMessage('queue-$_queueSeq', message);
        _inputMachine.settleSubmit(success: true);
        if (sessionId != null) {
          widget.sessions.saveComposerState(
            sessionId,
            _inputMachine.sessionState,
          );
        }
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
      case SessionSubmitMode.send:
        // v0.5/P5-E5：已知 slash command 若带图片且没有 images 能力，
        // 整次提交在进入 submitting 前拒绝，保留 draft、引用和图片。
        final imageError = widget.sessions.commandImageAdmissionError(message);
        if (imageError != null) {
          _inputMachine.setNotice(imageError);
          if (sessionId != null) {
            widget.sessions.saveComposerDraft(sessionId, message);
          }
          setState(() {});
          return;
        }
        final attemptToken = _inputMachine.beginAdjudication();
        if (attemptToken == null ||
            !_inputMachine.enterSubmitting(attemptToken: attemptToken)) {
          return;
        }
        setState(() {});
        if (_isGoalCommand(message)) {
          await _submitGoalCommand(message, sessionId, attemptToken);
          return;
        }
        // 受理即返回（awaitTurnCompletion=false）：命令确认 + 首批快照后
        // 立刻清空输入框并把主按钮切换为"中断"；回合完成由后台轮询收敛。
        // v0.9.0 C1：显式提交意图——send 模式是 newTurn。
        await widget.sessions.sendMessage(
          message: message,
          deviceId: widget.deviceId,
          canWrite: widget.canWrite,
          intent: TurnSubmissionIntent.newTurn,
          awaitTurnCompletion: false,
        );
        if (!mounted) return;
        final error = widget.sessions.errorMessage;
        if (error != null) {
          final settled = _inputMachine.settleSubmit(
            success: false,
            error: error,
            attemptToken: attemptToken,
          );
          if (sessionId != null) {
            widget.sessions.saveComposerState(
              sessionId,
              _inputMachine.sessionState,
            );
          }
          _setControllerText(settled ? message : _inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        final settled = _inputMachine.settleSubmit(
          success: true,
          attemptToken: attemptToken,
        );
        if (!settled) {
          _setControllerText(_inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
      case SessionSubmitMode.steer:
        // Strict steer is an explicit placement into the active provider turn.
        // The existing session.send relay path carries the opaque message and
        // lets the adapter decide whether the provider accepts steering.
        if (message.isEmpty) return;
        final attemptToken = _inputMachine.beginAdjudication();
        if (attemptToken == null ||
            !_inputMachine.enterSubmitting(attemptToken: attemptToken)) {
          return;
        }
        setState(() {});
        // v0.9.0 C1：显式提交意图——steer 模式注入当前活动回合，不重置超时预算。
        await widget.sessions.sendMessage(
          message: message,
          deviceId: widget.deviceId,
          canWrite: widget.canWrite,
          intent: TurnSubmissionIntent.steer,
        );
        if (!mounted) return;
        final error = widget.sessions.errorMessage;
        if (error != null) {
          final settled = _inputMachine.settleSubmit(
            success: false,
            error: error,
            attemptToken: attemptToken,
          );
          if (sessionId != null) {
            widget.sessions.saveComposerState(
              sessionId,
              _inputMachine.sessionState,
            );
          }
          _setControllerText(settled ? message : _inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        final settled = _inputMachine.settleSubmit(
          success: true,
          attemptToken: attemptToken,
        );
        if (!settled) {
          _setControllerText(_inputMachine.snapshot.draft);
          setState(() {});
          return;
        }
        _setControllerText('');
        _setSuggestions(const []);
        setState(() {});
    }
  }

  void _persistComposerState() {
    final sessionId = widget.sessions.selectedSessionId ?? _draftSessionId;
    if (sessionId == null) return;
    widget.sessions.saveComposerState(sessionId, _inputMachine.sessionState);
  }

  Future<void> _stop() => widget.sessions.stopStreaming(
    deviceId: widget.deviceId,
    canWrite: widget.canWrite,
  );

  Future<void> _sendQueuedMessages() async {
    if (widget.sessions.isStreaming) return;
    final queued = List<QueuedComposerMessage>.from(
      _inputMachine.snapshot.queue,
    );
    if (queued.isEmpty) return;
    for (final item in queued) {
      if (widget.sessions.isStreaming) break;
      // v0.9.0 C1：队列清空逐条发起的是新回合（排队语义），不是 steer。
      await widget.sessions.sendMessage(
        message: item.text,
        deviceId: widget.deviceId,
        canWrite: widget.canWrite,
        intent: TurnSubmissionIntent.newTurn,
      );
      if (!mounted) return;
      if (widget.sessions.errorMessage != null) break;
      setState(() {
        _inputMachine.removeQueuedMessage(item.id);
        _persistComposerState();
      });
      if (widget.sessions.isStreaming) break;
    }
  }

  /// v0.5/P5：逐条 strict steer——只把指定排队项作为显式动作发送，
  /// 其余队列保留；发送成功才移除该项，失败保留并在 composer notice 呈现。
  Future<void> _steerQueuedMessages(String id) async {
    final queued = List<QueuedComposerMessage>.from(
      _inputMachine.snapshot.queue,
    );
    final item = queued.where((entry) => entry.id == id).firstOrNull;
    if (item == null || !item.steerable) return;
    // v0.9.0 C1：逐条 strict steer 是显式 steer 意图（继承活动回合预算）。
    await widget.sessions.sendMessage(
      message: item.text,
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
      intent: TurnSubmissionIntent.steer,
    );
    if (!mounted) return;
    final error = widget.sessions.errorMessage;
    if (error != null) {
      setState(
        () => _inputMachine.setNotice(
          '只发送 '
          '$item.text'
          ' 失败：$error',
        ),
      );
      return;
    }
    setState(() {
      _inputMachine.removeQueuedMessage(item.id);
      _persistComposerState();
    });
  }
}

class _CommandLauncherMenu extends StatelessWidget {
  const _CommandLauncherMenu({required this.onSelect});

  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    const commands = <(String, String)>[
      ('export', '导出当前会话日志'),
      ('feedback', '提交消息反馈'),
      ('goal', '查看或更新 Goal'),
      ('permission', '选择权限 preset'),
      ('model', '切换模型'),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        key: const Key('session-command-launcher-menu'),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (final command in commands)
              ListTile(
                dense: true,
                leading: const Icon(Icons.chevron_right, size: AppSizes.iconMd),
                title: Text('/${command.$1}'),
                subtitle: Text(command.$2),
                onTap: () => onSelect(command.$1),
              ),
          ],
        ),
      ),
    );
  }
}

/// v0.5/P5：danger-full-access 权限预设的风险确认对话框。
///
/// 未勾选确认前「提交」不可用；取消按钮、遮罩点击与 Escape 都不提交任何命令。
/// 确认后调用 [SessionController.selectPermissionMode] 提交真实 preset。
Future<void> _confirmDangerPermission(
  BuildContext context, {
  required SessionController sessions,
  required String? deviceId,
  required bool canWrite,
}) async {
  var confirmed = false;
  final action = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            key: const Key('session-permission-risk-confirm'),
            title: const Text('确认授予完全访问权限'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '“danger-full-access” 将授予 Host 完全访问权限。请确认你了解风险后再提交。',
                ),
                const SizedBox(height: AppSpacing.sm),
                CheckboxListTile(
                  key: const Key('session-permission-risk-checkbox'),
                  value: confirmed,
                  onChanged: (value) =>
                      setDialogState(() => confirmed = value ?? false),
                  title: const Text('我已了解并确认授予完全访问权限'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
            actions: [
              TextButton(
                key: const Key('session-permission-risk-cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('session-permission-risk-submit'),
                onPressed: confirmed
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: const Text('确认提交'),
              ),
            ],
          );
        },
      );
    },
  );
  // 弹窗关闭后只对「确认并提交」走真实写命令；取消/遮罩/Escape 返回 null 或 false。
  if (action == true && context.mounted) {
    await sessions.selectPermissionMode(
      mode: 'danger-full-access',
      deviceId: deviceId,
      canWrite: canWrite,
    );
  }
}

/// v0.2/P3：模型与推理等级由 Composer 单行状态入口承载；此处只保留权限模式。
/// 所有写入口继续按 capability、设备角色和 lease fail-closed。
/// V094-16（计划 §2.5/§3.1）：紧凑权限徽标——内容宽度、视觉高 32dp、
/// 命中区域 ≥48dp；一次点击直达权限选择面板。整行 DropdownButtonFormField
/// 表单、永久「权限」label 与空 helper 已移除。徽标文案优先展示目录
/// 友好名，缺说明回退原 ID；danger-full-access 保留警示样式，风险确认门
/// 不受展示名影响。禁用（能力锁定/目录为空）附真实原因。
class _ComposerControlStrip extends StatelessWidget {
  const _ComposerControlStrip({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final controls = sessions.controls;
    final permissionCapability = sessions.selectedProviderCapabilities
        .capability('permission_mode');
    final shouldShow =
        controls.availablePermissionModes.isNotEmpty ||
        permissionCapability.isSupported;
    if (!shouldShow) return const SizedBox.shrink();
    final permissionModeBlocked = sessions.controlBlockedReason(
      'permission_mode',
      canWrite: canWrite,
    );
    final disabled =
        permissionModeBlocked != null ||
        controls.availablePermissionModes.isEmpty;
    final current = controls.permissionMode;
    final details = controls.availablePermissionModeDetails;
    final currentDetail = details
        .where((detail) => detail.id == current)
        .firstOrNull;
    // 徽标文案：目录友好名优先，缺失回退原 ID（不臆测语义）。
    final label = current == null
        ? '权限'
        : (currentDetail?.name.isNotEmpty == true ? currentDetail!.name : current);
    final isDanger = current == 'danger-full-access';
    final scheme = Theme.of(context).colorScheme;
    final tooltip = disabled
        ? (permissionModeBlocked ??
              sessions.permissionDirectoryHint ??
              '权限目录未提供')
        : (currentDetail?.description.isNotEmpty == true
              ? currentDetail!.description
              : '查看权限模式');

    return Padding(
      key: const Key('composer-control-strip'),
      padding: const EdgeInsets.only(left: AppSpacing.micro),
      child: SizedBox(
        // 命中区域高度 ≥48dp（视觉徽标 32dp 居中）。
        height: 48,
        child: Center(
          child: Tooltip(
            message: tooltip,
            child: InkWell(
              key: const Key('composer-permission-mode-select'),
              onTap: disabled
                  ? null
                  : () => _showPermissionSheet(
                      context,
                      sessions: sessions,
                      canWrite: canWrite,
                      deviceId: deviceId,
                    ),
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm + AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: isDanger
                      ? scheme.errorContainer
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(
                    color: isDanger
                        ? scheme.error.withValues(alpha: 0.6)
                        : scheme.outlineVariant,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isDanger
                          ? Icons.warning_amber_rounded
                          : Icons.verified_user_outlined,
                      size: AppSizes.iconSm,
                      color: isDanger
                          ? scheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: isDanger
                            ? scheme.error
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 权限选择面板（一次点击直达）：目录条目展示友好名 + 说明（缺失时
  /// 「说明未提供」），当前模式打勾；danger-full-access 关闭面板后先弹
  /// 风险勾选确认，确认门语义与 v0.8.6 一致。
  Future<void> _showPermissionSheet(
    BuildContext context, {
    required SessionController sessions,
    required bool canWrite,
    required String? deviceId,
  }) async {
    final controls = sessions.controls;
    final details = controls.availablePermissionModeDetails;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Semantics(
          container: true,
          label: '权限模式选择',
          child: ListView(
            key: const Key('session-permission-selection-sheet'),
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                child: Text(
                  '权限模式',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final mode in controls.availablePermissionModes)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  leading: Icon(
                    mode == 'danger-full-access'
                        ? Icons.warning_amber_rounded
                        : Icons.verified_user_outlined,
                    color: mode == 'danger-full-access'
                        ? Theme.of(sheetContext).colorScheme.error
                        : null,
                  ),
                  title: Text(
                    details
                            .where((detail) => detail.id == mode)
                            .map((detail) => detail.name)
                            .firstWhere(
                              (name) => name.isNotEmpty,
                              orElse: () => mode,
                            ),
                  ),
                  subtitle: Text(
                    details
                            .where((detail) => detail.id == mode)
                            .map((detail) => detail.description)
                            .firstWhere(
                              (description) => description.isNotEmpty,
                              orElse: () => '说明未提供',
                            ),
                  ),
                  trailing: controls.permissionMode == mode
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    if (mode == 'danger-full-access') {
                      _confirmDangerPermission(
                        context,
                        sessions: sessions,
                        deviceId: deviceId,
                        canWrite: canWrite,
                      );
                      return;
                    }
                    sessions.selectPermissionMode(
                      mode: mode,
                      deviceId: deviceId,
                      canWrite: canWrite,
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// v0.2/P3：@ / 自动补全面板。候选为空时展示空态说明（fail-closed）。
/// v0.5/P5：候选高度锚定在 composer 上方（max-height），支持键盘高亮下标。
class _ComposerSuggestions extends StatelessWidget {
  const _ComposerSuggestions({
    required this.suggestions,
    required this.loading,
    required this.onApply,
    required this.onDismiss,
    this.selectedIndex = -1,
  });

  final List<_CompletionSuggestion> suggestions;
  final bool loading;
  final void Function(_CompletionSuggestion suggestion) onApply;
  final VoidCallback onDismiss;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: Container(
        key: const Key('composer-suggestions'),
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          border: Border.all(color: theme.dividerColor),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (loading)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.sm),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: AppSpacing.sm),
                    Text('正在加载建议…'),
                  ],
                ),
              )
            else if (suggestions.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Text(
                  '没有可用的补全建议（目录不可用或查询越权）。',
                  key: const Key('composer-suggestions-empty'),
                  style: theme.textTheme.labelSmall,
                ),
              )
            else
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (var index = 0; index < suggestions.length; index += 1)
                      Material(
                        color: index == selectedIndex
                            ? theme.colorScheme.primaryContainer.withValues(
                                alpha: 0.4,
                              )
                            : Colors.transparent,
                        child: ListTile(
                          key: Key(
                            'completion-suggestion-${suggestions[index].label}',
                          ),
                          dense: true,
                          selected: index == selectedIndex,
                          leading: Icon(
                            suggestions[index].kind == _CompletionKind.skill
                                ? Icons.bolt_outlined
                                : Icons.description_outlined,
                            size: AppSizes.iconMd,
                          ),
                          title: Text(suggestions[index].label),
                          onTap: () => onApply(suggestions[index]),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 附件队列只绘制内存中的 localName 和最小进度；密文、元数据和原始文件不会被放入 Widget 文本或日志。
class _AttachmentQueue extends StatelessWidget {
  const _AttachmentQueue({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final blocked = sessions.controlBlockedReason(
      'attachments',
      canWrite: canWrite,
    );
    return Semantics(
      label: '附件上传队列',
      child: Wrap(
        key: const Key('session-attachment-queue'),
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final transfer in sessions.attachments)
            _AttachmentChip(
              transfer: transfer,
              pending: sessions.isAttachmentPending(transfer.draft.id),
              uploadEnabled: blocked == null,
              onUpload: () => sessions.uploadAttachment(
                attachmentId: transfer.draft.id,
                deviceId: deviceId,
                canWrite: canWrite,
              ),
              onRemove: () => sessions.removeAttachment(transfer.draft.id),
            ),
          for (final rejection in sessions.attachmentRejections)
            _AttachmentRejectedChip(
              rejection: rejection,
              onDismiss: () =>
                  sessions.dismissAttachmentRejection(rejection.localName),
            ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.transfer,
    required this.pending,
    required this.uploadEnabled,
    required this.onUpload,
    required this.onRemove,
  });

  final AttachmentTransfer transfer;
  final bool pending;
  final bool uploadEnabled;
  final VoidCallback onUpload;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final presentation = switch (transfer.phase) {
      AttachmentTransferPhase.queued => ('待上传', Icons.schedule_outlined),
      AttachmentTransferPhase.uploading => ('上传中', Icons.cloud_upload_outlined),
      AttachmentTransferPhase.failed => ('需重试', Icons.error_outline),
      AttachmentTransferPhase.completed => ('已完成', Icons.check_circle_outline),
    };
    final canUpload =
        uploadEnabled &&
        !pending &&
        transfer.phase != AttachmentTransferPhase.completed;
    return Container(
      key: Key('attachment-chip-${transfer.draft.id}'),
      constraints: const BoxConstraints(minWidth: 172, maxWidth: 218),
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.micro, AppSpacing.xs),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Icon(
            transfer.draft.isImage
                ? Icons.image_outlined
                : Icons.article_outlined,
            size: AppSizes.iconMd,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transfer.draft.localName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                Text(
                  '${presentation.$1} · ${transfer.completedChunks}/${transfer.draft.totalChunks}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (transfer.phase == AttachmentTransferPhase.uploading)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: LinearProgressIndicator(value: transfer.progress),
                  ),
                if (transfer.errorMessage != null)
                  Text(
                    transfer.errorMessage!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            key: Key('attachment-upload-${transfer.draft.id}'),
            tooltip: transfer.phase == AttachmentTransferPhase.failed
                ? '重试附件上传'
                : '上传附件',
            onPressed: canUpload ? onUpload : null,
            icon: pending
                ? const SizedBox(
                    width: AppSpacing.lg,
                    height: AppSpacing.lg,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    transfer.phase == AttachmentTransferPhase.failed
                        ? Icons.refresh
                        : presentation.$2,
                    size: AppSizes.iconMd,
                  ),
          ),
          IconButton(
            key: Key('attachment-remove-${transfer.draft.id}'),
            tooltip: '移除附件',
            onPressed: pending ? null : onRemove,
            icon: const Icon(Icons.close, size: AppSizes.iconMd),
          ),
        ],
      ),
    );
  }
}

class _AttachmentRejectedChip extends StatelessWidget {
  const _AttachmentRejectedChip({
    required this.rejection,
    required this.onDismiss,
  });

  final AttachmentRejection rejection;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('attachment-rejected-${rejection.localName}'),
    constraints: const BoxConstraints(minWidth: 172, maxWidth: 228),
    padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.micro, AppSpacing.xs),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      border: Border.all(color: Theme.of(context).colorScheme.error),
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: Row(
      children: [
        const Icon(Icons.block_outlined, size: AppSizes.iconMd),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rejection.localName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                rejection.reason,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '关闭附件拒绝提示',
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: AppSizes.iconMd),
        ),
      ],
    ),
  );
}


class _HappyComposerMetaRow extends StatelessWidget {
  const _HappyComposerMetaRow({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final controls = sessions.controls;
    final capabilities = sessions.selectedProviderCapabilities;
    final modelCapability = capabilities.capability('model_select');
    // 新会话刚启动时 usage 投影可能尚未落库；此时只采用 Host 在能力矩阵中
    // 明确声明且属于目录的默认项，不根据 Provider 名称猜测付费模型。
    final modelOptions = controls.models.isNotEmpty
        ? controls.models
        : modelCapability.options;
    final modelGroups = controls.modelGroups.isNotEmpty
        ? controls.modelGroups
        : modelCapability.modelGroups;
    final selectedModel =
        controls.model ??
        controls.defaultModel ??
        modelCapability.defaultOption;
    final modelDetail = selectedModel == null
        ? null
        : capabilities.modelDetailFor('model_select', selectedModel);
    // v0.9.2 G4：不可用时把执行侧给出的原因（经 Relay 转达）交给 composer，
    // 用户看到的是"未找到 node 运行时"这类可操作事实，而不是笼统的不可用。
    final providerReason = capabilities.capability('start').reason;
    return SessionModelSeat(
      key: const Key('happy-session-model-row'),
      provider: sessions.selectedSession?.provider,
      providerVersion: capabilities.version,
      providerAvailable: capabilities.available,
      providerReason: providerReason,
      providerFactsSource: capabilities.factsSource,
      capabilities: [
        for (final name in const [
          'model_select',
          'effort_select',
          'plan',
          'goal',
          'invoke_skill',
          'attachments',
        ])
          capabilities.capability(name),
      ],
      catalog: SessionModelCatalog(
        model: selectedModel,
        effort: controls.effort,
        models: modelOptions,
        efforts: controls.efforts,
        groups: modelGroups,
      ),
      modelCapability: modelCapability,
      effortCapability: capabilities.capability('effort_select'),
      modelBlockedReason: sessions.controlBlockedReason(
        'model_select',
        canWrite: canWrite,
      ),
      effortBlockedReason: sessions.controlBlockedReason(
        'effort_select',
        canWrite: canWrite,
      ),
      busy: sessions.isBusy,
      modelDetail: modelDetail,
      usage: controls.usage,
      effortsByModel: sessions.modelEffortsMemory,
      taskControls: _SessionTaskControls(
        sessions: sessions,
        canWrite: canWrite,
        deviceId: deviceId,
      ),
      onRefresh: () async {
        final error = await sessions.refreshSelectedControls();
        final refreshed = sessions.controls;
        return SessionModelCatalogRefresh(
          catalog: SessionModelCatalog(
            model:
                refreshed.model ??
                refreshed.defaultModel ??
                modelCapability.defaultOption,
            effort: refreshed.effort,
            models: refreshed.models.isNotEmpty
                ? refreshed.models
                : modelCapability.options,
            efforts: refreshed.efforts,
            groups: refreshed.modelGroups.isNotEmpty
                ? refreshed.modelGroups
                : modelCapability.modelGroups,
          ),
          error: error,
        );
      },
      onSelectModel: (model) async {
        await sessions.selectModel(
          model: model,
          deviceId: deviceId,
          canWrite: canWrite,
        );
        return sessions.errorMessage;
      },
      onSelectEffort: (effort) async {
        await sessions.selectEffort(
          effort: effort,
          deviceId: deviceId,
          canWrite: canWrite,
        );
        return sessions.errorMessage;
      },
    );
  }
}

class _SessionTaskControls extends StatelessWidget {
  const _SessionTaskControls({
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
  });

  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sessions,
    builder: (context, _) {
      final controls = sessions.controls;
      final plan = controls.plan;
      final goal = controls.goal;
      final skill = controls.skills.where(
        (item) => item.risk == SkillRisk.high,
      );
      final planBlocked = sessions.controlBlockedReason(
        'plan',
        canWrite: canWrite,
      );
      final goalBlocked = sessions.controlBlockedReason(
        'goal',
        canWrite: canWrite,
      );
      final skillBlocked = sessions.controlBlockedReason(
        'invoke_skill',
        canWrite: canWrite,
      );
      return Column(
        key: const Key('session-task-controls'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ControlSummaryRow(
            key: const Key('session-plan-summary'),
            icon: Icons.account_tree_outlined,
            title: plan?.title ?? 'Plan',
            subtitle: plan == null
                ? '等待已解密 Plan 事件'
                : '${plan.phase.label} · ${plan.summary}',
            action: IconButton(
              key: const Key('session-plan-approve-button'),
              tooltip: '确认 Plan',
              onPressed:
                  plan?.phase == PlanPhase.awaitingApproval &&
                      planBlocked == null &&
                      !sessions.isBusy
                  ? () => sessions.approvePlan(
                      deviceId: deviceId,
                      canWrite: canWrite,
                    )
                  : null,
              icon: const Icon(Icons.check_circle_outline),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          _ControlSummaryRow(
            key: const Key('session-goal-summary'),
            icon: Icons.flag_outlined,
            title: goal?.title ?? 'Goal',
            subtitle: goal == null
                ? '等待已解密 Goal 事件'
                : '${goal.phase.label} · ${goal.progressLabel}',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('session-goal-edit-button'),
                  tooltip: '编辑目标',
                  onPressed:
                      goal != null && goalBlocked == null && !sessions.isBusy
                      ? () => _showGoalEditDialog(
                          context,
                          sessions,
                          goal.title,
                          deviceId: deviceId,
                          canWrite: canWrite,
                        )
                      : null,
                  icon: const Icon(Icons.edit_outlined, size: AppSizes.iconLg),
                ),
                IconButton(
                  key: const Key('session-goal-toggle-button'),
                  tooltip: goal?.phase == GoalPhase.active
                      ? '暂停 Goal'
                      : '恢复 Goal',
                  onPressed:
                      goal != null &&
                          goal.phase != GoalPhase.completed &&
                          goalBlocked == null &&
                          !sessions.isBusy
                      ? () => sessions.toggleGoal(
                          deviceId: deviceId,
                          canWrite: canWrite,
                        )
                      : null,
                  icon: Icon(
                    goal?.phase == GoalPhase.active
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                  ),
                ),
                IconButton(
                  key: const Key('session-goal-clear-button'),
                  tooltip: '清除 Goal',
                  onPressed:
                      goal != null && goalBlocked == null && !sessions.isBusy
                      ? () => sessions.clearGoal(
                          deviceId: deviceId,
                          canWrite: canWrite,
                        )
                      : null,
                  icon: const Icon(Icons.clear_outlined, size: AppSizes.iconLg),
                ),
              ],
            ),
          ),
          if (skill.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            _ControlSummaryRow(
              key: const Key('session-skill-summary'),
              icon: Icons.security_outlined,
              title: skill.first.title,
              subtitle:
                  '${skill.first.risk.label} Skill · ${skill.first.summary}',
              action: IconButton(
                key: const Key('session-skill-open-button'),
                tooltip: '确认高风险 Skill',
                onPressed: skillBlocked == null && !sessions.isBusy
                    ? () {
                        sessions.requestSkillConfirmation(
                          skill.first,
                          canWrite: canWrite,
                        );
                        // 确认卡位于 composer seat；关闭详情弹窗后才可操作拒绝/确认。
                        Navigator.of(context).pop();
                      }
                    : null,
                icon: const Icon(Icons.warning_amber_outlined),
              ),
            ),
          ],
        ],
      );
    },
  );
}

/// v0.3/P0：goal 编辑对话框入口。只提交目标文本，不读取、不展示密文正文。
Future<void> _showGoalEditDialog(
  BuildContext context,
  SessionController sessions,
  String currentTitle, {
  required String? deviceId,
  required bool canWrite,
}) async {
  final objective = await showDialog<Object>(
    context: context,
    builder: (dialogContext) => _GoalEditDialog(initialTitle: currentTitle),
  );
  if (objective is String && objective.isNotEmpty) {
    sessions.editGoal(
      objective: objective,
      deviceId: deviceId,
      canWrite: canWrite,
    );
  }
}

/// goal 编辑对话框：controller 生命周期由 State 管理，避免对话框退场动画期被 dispose。

class _GoalEditDialog extends StatefulWidget {
  const _GoalEditDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_GoalEditDialog> createState() => _GoalEditDialogState();
}

class _GoalEditDialogState extends State<_GoalEditDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('goal-edit-dialog'),
    title: const Text('编辑目标'),
    content: TextField(
      key: const Key('goal-edit-input'),
      controller: _controller,
      maxLines: 3,
      decoration: const InputDecoration(
        labelText: '目标文本',
        border: OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        key: const Key('goal-edit-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('goal-edit-submit'),
        onPressed: () {
          final value = _controller.text.trim();
          if (value.isEmpty) return;
          Navigator.of(context).pop(value);
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class _ControlSummaryRow extends StatelessWidget {
  const _ControlSummaryRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: AppSizes.iconMd),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ],
        ),
      ),
      action,
    ],
  );
}
