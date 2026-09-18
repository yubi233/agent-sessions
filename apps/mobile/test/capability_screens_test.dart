import 'dart:typed_data';

import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_harness.dart';

void main() {
  testWidgets('MOBILE-03：480x960 模型设置弹窗显示 capability 三态与 Plan/Goal 摘要', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 960));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final harness = MobileAppHarness();
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _openWritableFixtureSession(tester, harness);

    expect(find.byKey(const Key('session-capability-panel')), findsNothing);
    expect(find.byKey(const Key('session-task-controls')), findsNothing);
    expect(find.byKey(const Key('session-goal-dock')), findsNothing);
    expect(find.byKey(const Key('session-capability-states')), findsNothing);
    expect(find.byKey(const Key('session-capability-provider')), findsNothing);
    expect(find.byKey(const Key('session-control-model')), findsNothing);
    expect(find.byKey(const Key('session-control-effort')), findsNothing);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-seat-details')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-model-details-dialog')),
    );
    expect(
      find.byKey(const Key('session-model-details-capabilities')),
      findsOneWidget,
    );
    expect(find.text('codex'), findsOneWidget);
    expect(find.text('model_select 原生'), findsOneWidget);
    expect(find.text('effort_select 原生'), findsOneWidget);
    expect(find.text('plan 原生'), findsOneWidget);
    expect(find.byKey(const Key('session-task-controls')), findsOneWidget);
    expect(find.byKey(const Key('session-plan-summary')), findsOneWidget);
    expect(find.byKey(const Key('session-goal-summary')), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('session-plan-approve-button')),
          )
          .onPressed,
      isNotNull,
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-details-close')),
    );
    // 等关闭动画完成后再断言弹窗内容消失。
    await _waitForAbsent(tester, find.byKey(const Key('session-task-controls')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('MODE-03：拒绝高风险 Skill 不提交命令，确认后只提交一次', (tester) async {
    final harness = MobileAppHarness();
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _openWritableFixtureSession(tester, harness);

    expect(harness.relay.submittedCommandCount, 0);
    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-seat-details')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-model-details-dialog')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-skill-open-button')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('skill-confirmation-card')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('skill-confirmation-reject-button')),
    );
    await _waitForAbsent(
      tester,
      find.byKey(const Key('skill-confirmation-card')),
    );
    expect(harness.relay.submittedCommandCount, 0);

    await _tapVisible(
      tester,
      find.byKey(const Key('session-model-seat-details')),
    );
    await _waitForVisible(
      tester,
      find.byKey(const Key('session-model-details-dialog')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('session-skill-open-button')),
    );
    await _tapVisible(
      tester,
      find.byKey(const Key('skill-confirmation-approve-button')),
    );
    await _waitForAbsent(
      tester,
      find.byKey(const Key('skill-confirmation-card')),
    );
    expect(harness.relay.submittedCommandCount, 1);
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('session-detail-screen'))),
    );
    expect(
      container
          .read(sessionControllerProvider)
          .timeline
          .any((event) => event.label == 'Skill 已确认'),
      isTrue,
    );
  });

  testWidgets('ATTACH-01：附件 chip 显示预检拒绝、分块失败与重试；fixture 已声明 DEK 可用', (
    tester,
  ) async {
    final harness = MobileAppHarness();
    await harness.launchAsOwner();
    await harness.seedSession();
    await tester.pumpWidget(harness.build());
    await _openWritableFixtureSession(tester, harness);
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('session-detail-screen'))),
    );
    final sessions = container.read(sessionControllerProvider);
    final valid = _attachmentDraft(
      id: 'ui-retry-image',
      localName: 'fixture-image.png',
      mimeType: 'image/png',
    );
    final rejected = _attachmentDraft(
      id: 'ui-rejected-binary',
      localName: 'fixture.bin',
      mimeType: 'application/octet-stream',
    );
    expect(sessions.addAttachmentDraft(valid), isTrue);
    expect(sessions.addAttachmentDraft(rejected), isFalse);
    harness.relay.failAttachmentChunkAtIndex(1);
    await sessions.uploadAttachment(
      attachmentId: valid.id,
      deviceId: 'android-owner-fixture',
      canWrite: true,
    );
    await tester.pump();

    expect(find.byKey(const Key('session-attachment-queue')), findsOneWidget);
    expect(find.byKey(Key('attachment-chip-${valid.id}')), findsOneWidget);
    expect(
      find.byKey(Key('attachment-rejected-${rejected.localName}')),
      findsOneWidget,
    );
    expect(find.textContaining('需重试'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(Key('attachment-upload-${valid.id}')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('session-attachment-add-button')),
          )
          .onPressed,
      // v0.2/P3：fixture 声明会话 DEK 可用，选附件入口启用；无 DEK 的禁用断言见 MOBILE-08。
      isNotNull,
    );

    await _tapVisible(tester, find.byKey(Key('attachment-upload-${valid.id}')));
    await _waitForVisible(tester, find.textContaining('已完成'));
  });
}

AttachmentDraft _attachmentDraft({
  required String id,
  required String localName,
  required String mimeType,
}) => AttachmentDraft(
  id: id,
  localName: localName,
  mimeType: mimeType,
  byteSize: 512,
  compression: 'none',
  metadataCiphertext: Uint8List.fromList([1, 2, 3]),
  ciphertextChunks: [
    Uint8List.fromList([11, 12]),
    Uint8List.fromList([13, 14]),
  ],
);

/// v0.8.1+：harness 已预置 owner + seed 会话并 pump 完成；打开详情并等待可写。
Future<void> _openWritableFixtureSession(
  WidgetTester tester,
  MobileAppHarness harness,
) async {
  await _waitForVisible(tester, find.byKey(const Key('session-home-screen')));
  final sessionId = (await harness.relay.listSessions()).single.id;
  // 经「最近会话」入口打开详情（首页已改为 DSH 工作区视图）。
  await _tapVisible(tester, find.byKey(const Key('session-recent-button')));
  await _waitForVisible(
    tester,
    find.byKey(Key('recent-session-$sessionId')),
  );
  await _tapVisible(tester, find.byKey(Key('recent-session-$sessionId')));
  await _waitForVisible(tester, find.byKey(const Key('session-detail-screen')));
  await _waitForVisible(tester, find.text('可控制'));
}

Future<void> _waitForVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsOneWidget);
}

Future<void> _waitForAbsent(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
  }
  expect(finder, findsNothing);
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await _waitForVisible(tester, finder);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}


