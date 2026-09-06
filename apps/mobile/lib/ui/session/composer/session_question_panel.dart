// Question 接管面板（v0.5/P4）：普通 question 多题流程与 plan-review 专用形态。
// 从 session_screens.dart 迁出；原 _QuestionRequestItem / _PlanReviewPanel。
import 'package:flutter/material.dart';

import '../../app_theme.dart';

import '../../../domain/session_models.dart';
import '../../../state/session_controller.dart';
import 'session_approval_panel.dart';
class SessionQuestionPanel extends StatefulWidget {
  const SessionQuestionPanel({
    super.key,
    required this.event,
    required this.canWrite,
    required this.hasLease,
    required this.sessions,
    required this.deviceId,
  });

  final SessionTimelineEvent event;
  final bool canWrite;
  final bool hasLease;
  final SessionController sessions;
  final String? deviceId;

  @override
  State<SessionQuestionPanel> createState() => SessionQuestionPanelState();
}

class SessionQuestionPanelState extends State<SessionQuestionPanel> {
  final Map<String, TextEditingController> _customAnswerControllers = {};
  final Map<String, Set<String>> _selectedAnswers = {};
  final Set<String> _skippedStepIds = {};
  String? _activeRequestId;
  String? _validationError;
  String? _submissionError;
  bool _minimized = false;
  bool _locallyCancelled = false;
  int _questionIndex = 0;

  @override
  void initState() {
    super.initState();
    _activeRequestId = widget.event.question?.requestId;
  }

  @override
  void didUpdateWidget(covariant SessionQuestionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextRequestId = widget.event.question?.requestId;
    if (_activeRequestId == nextRequestId) return;
    // v0.5/P4-B/P4-E：同一 request replay 保留每题草稿；新的 request/key 必须重置本地状态。
    _activeRequestId = nextRequestId;
    _resetDraftState();
  }

  @override
  void dispose() {
    for (final controller in _customAnswerControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.event.question;
    if (question == null) return SessionSystemNotice(event: widget.event);
    final steps = _stepsFor(question);
    final currentIndex = _questionIndex.clamp(0, steps.length - 1).toInt();
    final currentStep = steps[currentIndex];
    final stepKey = _stepKey(question, currentStep, currentIndex, steps.length);
    final controller = _controllerFor(currentStep.id);
    final selected = _selectedAnswers[currentStep.id] ?? const <String>{};
    final resolved =
        question.resolved == true ||
        widget.sessions.isRequestResolved('question', question.requestId);
    final pending = widget.sessions.isRequestPending(question.requestId);
    // v0.9：lease 在提交时自动获取，不再作为按钮前置门控。
    final enabled = widget.canWrite && !resolved && !pending;
    final answered = _answered(currentStep);
    if (_locallyCancelled && !resolved) {
      return Container(
        key: Key('question-card-${question.requestId}'),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Row(
          key: Key('question-local-cancelled-${question.requestId}'),
          children: [
            const Icon(Icons.close),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '已在本机关闭此问题，未向 Host 发送取消命令。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              key: Key('question-cancel-restore-${question.requestId}'),
              onPressed: () => setState(() => _locallyCancelled = false),
              child: const Text('恢复'),
            ),
          ],
        ),
      );
    }
    if (_minimized) {
      return Container(
        key: Key('question-card-${question.requestId}'),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Row(
          key: Key('question-minimized-${question.requestId}'),
          children: [
            const Icon(Icons.help_outline),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                currentStep.prompt,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: Key('question-restore-${question.requestId}'),
              onPressed: () => setState(() => _minimized = false),
              child: const Text('展开'),
            ),
          ],
        ),
      );
    }
    return Container(
      key: Key('question-card-${question.requestId}'),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (steps.length > 1)
                      Text(
                        '${currentIndex + 1} / ${steps.length}',
                        key: Key('question-progress-${question.requestId}'),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    Text(
                      currentStep.prompt,
                      key: Key('question-prompt-$stepKey'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('question-minimize-${question.requestId}'),
                tooltip: '最小化问题',
                onPressed: () => setState(() => _minimized = true),
                icon: const Icon(Icons.expand_more),
              ),
              IconButton(
                key: Key('question-cancel-${question.requestId}'),
                tooltip: '本机关闭问题',
                onPressed: pending
                    ? null
                    // v0.5/P4-C：本地关闭只退出当前可见面板，不伪造 Relay/Host cancel。
                    : () => setState(() {
                        _locallyCancelled = true;
                        _validationError = null;
                        _submissionError = null;
                      }),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (currentStep.detail != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(currentStep.detail!),
          ],
          if (currentStep.options.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            if (currentStep.multiSelect)
              Column(
                key: Key('question-options-$stepKey'),
                children: [
                  for (
                    var index = 0;
                    index < currentStep.options.length;
                    index += 1
                  )
                    Material(
                      type: MaterialType.transparency,
                      child: CheckboxListTile(
                        key: Key('question-option-$stepKey-$index'),
                        value: selected.contains(
                          currentStep.options[index].label,
                        ),
                        onChanged: enabled
                            ? (checked) => setState(() {
                                final next = {...selected};
                                if (checked == true) {
                                  next.add(currentStep.options[index].label);
                                } else {
                                  next.remove(currentStep.options[index].label);
                                }
                                _selectedAnswers[currentStep.id] = next;
                                _skippedStepIds.remove(currentStep.id);
                                _validationError = null;
                                _submissionError = null;
                              })
                            : null,
                        title: Text(
                          _displayOptionLabel(currentStep.options[index].label),
                        ),
                        subtitle: currentStep.options[index].description == null
                            ? null
                            : Text(currentStep.options[index].description!),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    ),
                ],
              )
            else
              DropdownButtonFormField<String>(
                key: Key('question-options-$stepKey'),
                initialValue: selected.isEmpty ? null : selected.first,
                decoration: const InputDecoration(labelText: '选择回答'),
                items: currentStep.options
                    .map(
                      (option) => DropdownMenuItem(
                        value: option.label,
                        child: Text(_displayOptionLabel(option.label)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: enabled
                    ? (value) => setState(() {
                        _selectedAnswers[currentStep.id] = {?value};
                        _controllerFor(currentStep.id).clear();
                        _skippedStepIds.remove(currentStep.id);
                        _validationError = null;
                        _submissionError = null;
                      })
                    : null,
              ),
          ],
          if (currentStep.allowsFreeform || currentStep.options.isEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: Key('question-freeform-$stepKey'),
              controller: controller,
              enabled: enabled,
              maxLines: currentStep.options.isEmpty ? 3 : 2,
              onChanged: (_) => setState(() {
                // v0.5/P4-E：单选 custom 替换已选项；多选 custom 可与已选项并存。
                if (!currentStep.multiSelect) {
                  _selectedAnswers[currentStep.id] = <String>{};
                }
                _skippedStepIds.remove(currentStep.id);
                _validationError = null;
                _submissionError = null;
              }),
              decoration: InputDecoration(
                labelText: currentStep.options.isEmpty ? '输入回答' : '或输入回答',
              ),
            ),
          ],
          if (_validationError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _validationError!,
              key: Key('question-validation-${question.requestId}'),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          if (_submissionError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              _submissionError!,
              key: Key('question-submit-error-${question.requestId}'),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (steps.length > 1)
                  TextButton(
                    key: Key('question-prev-${question.requestId}'),
                    onPressed: enabled && currentIndex > 0
                        ? () => setState(() {
                            _questionIndex = currentIndex - 1;
                            _validationError = null;
                            _submissionError = null;
                          })
                        : null,
                    child: const Text('上一题'),
                  ),
                TextButton(
                  key: Key('question-skip-${question.requestId}'),
                  onPressed: enabled
                      ? () => _skipCurrentStep(question, steps, currentIndex)
                      : null,
                  child: const Text('跳过'),
                ),
                TextButton(
                  key: Key('question-next-${question.requestId}'),
                  onPressed: enabled
                      ? () => _continueQuestion(
                          question,
                          steps,
                          currentIndex,
                          answered,
                        )
                      : null,
                  child: Text(currentIndex == steps.length - 1 ? '提交' : '下一题'),
                ),
                IconButton(
                  key: Key('question-submit-${question.requestId}'),
                  tooltip: '提交回答',
                  onPressed: enabled
                      ? () => _submitQuestionBatch(question, steps)
                      : null,
                  icon: pending
                      ? const SizedBox(
                          width: AppSpacing.lg,
                          height: AppSpacing.lg,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
          if (resolved)
            Text(
              '已回答',
              key: Key('question-resolved-${question.requestId}'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
        ],
      ),
    );
  }

  Future<void> _continueQuestion(
    TimelineQuestionRequest question,
    List<TimelineQuestionStep> steps,
    int currentIndex,
    bool answered,
  ) async {
    final currentStep = steps[currentIndex];
    if (!answered && !_skippedStepIds.contains(currentStep.id)) {
      setState(() => _validationError = '请选择、输入或跳过当前问题。');
      return;
    }
    if (currentIndex < steps.length - 1) {
      setState(() {
        _questionIndex = currentIndex + 1;
        _validationError = null;
        _submissionError = null;
      });
      return;
    }
    await _submitQuestionBatch(question, steps);
  }

  Future<void> _skipCurrentStep(
    TimelineQuestionRequest question,
    List<TimelineQuestionStep> steps,
    int currentIndex,
  ) async {
    final currentStep = steps[currentIndex];
    setState(() {
      _selectedAnswers[currentStep.id] = <String>{};
      _controllerFor(currentStep.id).clear();
      _skippedStepIds.add(currentStep.id);
      _validationError = null;
      _submissionError = null;
    });
    if (steps.length == 1) {
      await _skipQuestion(question.requestId);
      return;
    }
    if (currentIndex < steps.length - 1) {
      setState(() => _questionIndex = currentIndex + 1);
      return;
    }
    await _submitQuestionBatch(question, steps);
  }

  Future<void> _submitQuestionBatch(
    TimelineQuestionRequest question,
    List<TimelineQuestionStep> steps,
  ) async {
    final missingIndex = steps.indexWhere(
      (step) => !_answered(step) && !_skippedStepIds.contains(step.id),
    );
    if (missingIndex >= 0) {
      setState(() {
        _questionIndex = missingIndex;
        _validationError = '请选择、输入或跳过当前问题。';
        _submissionError = null;
      });
      return;
    }
    setState(() {
      _validationError = null;
      _submissionError = null;
    });
    final accepted = await widget.sessions.answerQuestionBatch(
      requestId: question.requestId,
      answers: steps.map(_answerForStep).toList(growable: false),
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!accepted && mounted && _activeRequestId == question.requestId) {
      setState(() {
        _submissionError = widget.sessions.errorMessage ?? '提交失败，请重试。';
      });
    }
  }

  Future<void> _skipQuestion(String requestId) async {
    setState(() {
      _validationError = null;
      _submissionError = null;
    });
    final accepted = await widget.sessions.skipQuestion(
      requestId: requestId,
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!accepted && mounted && _activeRequestId == requestId) {
      setState(() {
        _submissionError = widget.sessions.errorMessage ?? '跳过失败，请重试。';
      });
    }
  }

  bool _answered(TimelineQuestionStep step) {
    final selected = _selectedAnswers[step.id] ?? const <String>{};
    return selected.isNotEmpty ||
        _controllerFor(step.id).text.trim().isNotEmpty;
  }

  Map<String, dynamic> _answerForStep(TimelineQuestionStep step) {
    final custom = _controllerFor(step.id).text.trim();
    return {
      'id': step.id,
      'selected': _skippedStepIds.contains(step.id)
          ? const <String>[]
          : (_selectedAnswers[step.id] ?? const <String>{}).toList(
              growable: false,
            ),
      if (custom.isNotEmpty && !_skippedStepIds.contains(step.id))
        'custom': custom,
    };
  }

  TextEditingController _controllerFor(String stepId) =>
      _customAnswerControllers.putIfAbsent(stepId, TextEditingController.new);

  List<TimelineQuestionStep> _stepsFor(TimelineQuestionRequest question) {
    if (question.steps.isNotEmpty) return question.steps;
    return [
      TimelineQuestionStep(
        id: question.requestId,
        prompt: question.prompt,
        options: question.options
            .map((label) => TimelineQuestionOption(label: label))
            .toList(growable: false),
        allowsFreeform: question.allowsFreeform,
      ),
    ];
  }

  String _stepKey(
    TimelineQuestionRequest question,
    TimelineQuestionStep step,
    int index,
    int count,
  ) => count == 1 ? question.requestId : '${question.requestId}-${step.id}';

  String _displayOptionLabel(String label) => label
      .replaceFirst(
        RegExp(
          r'\s*(\((recommended|推荐)\)|（(recommended|推荐)）)\s*$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  void _resetDraftState() {
    for (final controller in _customAnswerControllers.values) {
      controller.dispose();
    }
    _customAnswerControllers.clear();
    _selectedAnswers.clear();
    _skippedStepIds.clear();
    _validationError = null;
    _submissionError = null;
    _minimized = false;
    _locallyCancelled = false;
    _questionIndex = 0;
  }
}

class SessionPlanReviewPanel extends StatefulWidget {
  const SessionPlanReviewPanel({
    super.key,
    required this.question,
    required this.sessions,
    required this.canWrite,
    required this.deviceId,
    required this.hasLease,
  });

  final TimelineQuestionRequest question;
  final SessionController sessions;
  final bool canWrite;
  final String? deviceId;
  final bool hasLease;

  @override
  State<SessionPlanReviewPanel> createState() => SessionPlanReviewPanelState();
}

/// v0.5/P4-F：PlanReview 专用接管面板，对照 DeepSeek Harness `PlanReviewPanel`。
///
/// 计划评审是"一个决策 + 一段 markdown plan"，不是被打分的选择题，因此采用
/// 带色条的审批卡形态：等待条 + 可滚动 plan + 右对齐动作区。三个动作是完整决策面：
/// approve / decline 用提问方给出的真实选项 label 回传；discuss 只本机关闭并恢复
/// 输入上下文（不伪造 Host cancel）。approve/decline 是一次性动作，失败时 re-arm。
class SessionPlanReviewPanelState extends State<SessionPlanReviewPanel> {
  String? _submissionError;
  bool _busy = false;
  bool _locallyDismissed = false;

  TimelineQuestionStep get _review {
    final steps = widget.question.steps;
    final first = steps.isNotEmpty ? steps.first : _fallbackStep();
    // 单题 plan-review：steps 只存单个意图 step。
    return first;
  }

  TimelineQuestionStep _fallbackStep() => TimelineQuestionStep(
    id: widget.question.requestId,
    prompt: widget.question.prompt,
    detail: null,
  );

  TimelineQuestionOption? get _approve {
    final label = _review.intentApproveLabel;
    if (label == null) return null;
    for (final option in _review.options) {
      if (option.label == label) return option;
    }
    return null;
  }

  TimelineQuestionOption? get _decline {
    final approveLabel = _review.intentApproveLabel;
    if (approveLabel == null) return null;
    for (final option in _review.options) {
      if (option.label != approveLabel) return option;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.question;
    final resolved =
        question.resolved == true ||
        widget.sessions.isRequestResolved('question', question.requestId);
    // v0.9：lease 在提交时自动获取，不再作为按钮前置门控。
    final enabled = widget.canWrite && !resolved && !_busy;
    final plan = _review.detail;
    final approve = _approve;
    if (_locallyDismissed && !resolved) {
      return Container(
        key: Key('plan-review-card-${question.requestId}'),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Row(
          key: Key('plan-review-dismissed-${question.requestId}'),
          children: [
            const Icon(Icons.chat_bubble_outline),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '已在本地关闭计划评审，可继续输入讨论。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              key: Key('plan-review-restore-${question.requestId}'),
              onPressed: () => setState(() => _locallyDismissed = false),
              child: const Text('恢复'),
            ),
          ],
        ),
      );
    }
    return Container(
      key: Key('plan-review-card-${question.requestId}'),
      margin: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, 0),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 等待/意图条：对齐 DeepSeek Harness 审批卡的 tinted strip。
          Container(
            key: Key('plan-review-strip-${question.requestId}'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.card),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.rule,
                  size: AppSizes.iconSm,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '计划评审',
                  key: Key('plan-review-header-${question.requestId}'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
            child: Text(
              _review.prompt,
              key: Key('plan-review-question-${question.requestId}'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          // plan markdown 在卡内独立滚动（cap 120），按钮始终常驻可达。
          if (plan != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Container(
                key: Key('plan-review-scroll-${question.requestId}'),
                constraints: const BoxConstraints(maxHeight: 120),
                // 内部纵向滚动：长 plan 在卡内独立滚动，按钮始终常驻可达。
                child: SingleChildScrollView(
                  child: Text(
                    plan,
                    key: Key('plan-review-body-${question.requestId}'),
                    style: AppTypography.mono.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          if (_submissionError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text(
                _submissionError!,
                key: Key('plan-review-error-${question.requestId}'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          // 动作区：discuss / decline(可选) / approve。按钮常驻可达。
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.sm, AppSpacing.xs, AppSpacing.sm, AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    key: Key('plan-review-discuss-${question.requestId}'),
                    onPressed: enabled
                        ? () => setState(() {
                            // 只本机关闭，不伪造 Host cancel；恢复后仍可继续输入。
                            _locallyDismissed = true;
                            _submissionError = null;
                          })
                        : null,
                    child: const Text('讨论'),
                  ),
                  if (_decline != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Tooltip(
                      message: _decline!.description ?? '',
                      child: TextButton(
                        key: Key('plan-review-decline-${question.requestId}'),
                        onPressed: enabled
                            ? () => _decide(_decline!.label)
                            : null,
                        child: Text('需要修改'),
                      ),
                    ),
                  ],
                  if (approve != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Tooltip(
                      message: approve.description ?? '',
                      child: FilledButton(
                        key: Key('plan-review-approve-${question.requestId}'),
                        onPressed: enabled
                            ? () => _decide(approve.label)
                            : null,
                        child: _busy
                            ? const SizedBox(
                                width: AppSpacing.lg,
                                height: AppSpacing.lg,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('批准执行'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (resolved)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              child: Text(
                '已评审',
                key: Key('plan-review-resolved-${question.requestId}'),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _decide(String label) async {
    setState(() {
      _busy = true;
      _submissionError = null;
    });
    // approve/decline 都以提问方给出的真实选项 label 回传 answer，与 Harness 一致。
    final accepted = await widget.sessions.answerQuestionBatch(
      requestId: widget.question.requestId,
      answers: [
        {
          'id': _review.id,
          'selected': [label],
        },
      ],
      deviceId: widget.deviceId,
      canWrite: widget.canWrite,
    );
    if (!accepted && mounted) {
      setState(() {
        _busy = false;
        _submissionError = widget.sessions.errorMessage ?? '提交失败，请重试。';
      });
    }
  }
}

