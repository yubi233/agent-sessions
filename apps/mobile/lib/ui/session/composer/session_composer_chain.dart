// Composer chain（v0.5/P4）：pending interaction 的唯一 carrier，question 优先于 approval。
// 从 session_screens.dart 迁出；原 _ComposerChain。
import 'package:flutter/material.dart';

import '../../../domain/session_models.dart';
import '../../../state/session_controller.dart';
import 'session_approval_panel.dart';
import 'session_question_panel.dart';
class SessionComposerChain extends StatelessWidget {
  const SessionComposerChain({
    super.key,
    required this.pendingQuestion,
    required this.pendingPermission,
    required this.canWrite,
    required this.hasLease,
    required this.sessions,
    required this.deviceId,
  });

  final SessionTimelineEvent? pendingQuestion;
  final SessionTimelineEvent? pendingPermission;
  final bool canWrite;
  final bool hasLease;
  final SessionController sessions;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    // v0.5/P4-A/P4-F：composer chain 是 pending interaction 的唯一 carrier。
    // Question 优先于 approval；question 完成后，外层 projection 重算并 re-arm approval。
    // 普通 question 走 SessionQuestionPanel；plan-review 走专用卡片形态，避免把
    // "一个决策 + 一段 plan" 渲染成被打分的选择题（对照 Harness PlanReviewPanel）。
    final question = pendingQuestion;
    final permission = pendingPermission;
    final planReview = _planReviewStep(question);
    return Padding(
      key: const Key('session-composer-chain'),
      padding: const EdgeInsets.only(bottom: 8),
      child: question != null
          ? KeyedSubtree(
              key: const Key('session-question-panel'),
              child: planReview != null
                  ? SessionPlanReviewPanel(
                      question: question.question!,
                      sessions: sessions,
                      canWrite: canWrite,
                      deviceId: deviceId,
                      hasLease: hasLease,
                    )
                  : SessionQuestionPanel(
                      event: question,
                      canWrite: canWrite,
                      hasLease: hasLease,
                      sessions: sessions,
                      deviceId: deviceId,
                    ),
            )
          : KeyedSubtree(
              key: const Key('session-approval-panel'),
              child: SessionApprovalPanel(
                event: permission!,
                canWrite: canWrite,
                hasLease: hasLease,
                sessions: sessions,
                deviceId: deviceId,
              ),
            ),
    );
  }

  /// 从 pending question 事件提取 plan-review step；非 plan-review 返回 null。
  /// 对齐 DeepSeek Harness `planReviewOf()`：单题、带 detail、非多选、最多两个选项、
  /// 且必须存在意图指定 approve 选项，否则交给普通 question 流程。
  TimelineQuestionStep? _planReviewStep(SessionTimelineEvent? event) {
    final question = event?.question;
    if (question == null) return null;
    final steps = question.steps;
    if (steps.length != 1) return null;
    final step = steps.first;
    return step.isPlanReview ? step : null;
  }
}

