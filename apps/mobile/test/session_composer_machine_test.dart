import 'package:agent_sessions_mobile/state/session_composer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MOBILE-V05-04 SessionComposerInputMachine', () {
    test('command claim 使用 draft revision CAS，旧选区不会改写草稿', () {
      final machine = SessionComposerInputMachine()..setDraft('/goal ship');
      final revision = machine.snapshot.draftRevision;

      expect(
        machine.beginCommand(
          token: '/goal ',
          start: 0,
          end: 5,
          draftRevision: revision + 1,
        ),
        isFalse,
      );
      expect(machine.snapshot.draft, '/goal ship');

      expect(
        machine.beginCommand(
          token: '/goal ',
          start: 0,
          end: 5,
          draftRevision: revision,
        ),
        isTrue,
      );
      expect(machine.snapshot.phase, SessionInputPhase.claimed);
      expect(machine.snapshot.claimToken, '/goal ');
      expect(machine.snapshot.draft, '/goal  ship');
    });

    test('结构化引用 copy/cut/delete 使用 clipboard 投影并保持 undo/redo', () {
      final machine = SessionComposerInputMachine()..setDraft('打开 @readme');
      final revision = machine.snapshot.draftRevision;
      final start = machine.snapshot.draft.indexOf('@readme');
      final end = start + '@readme'.length;

      expect(
        machine.insertReference(
          label: 'README.md',
          clipboardText: '@file:README.md',
          start: start,
          end: end,
          draftRevision: revision,
        ),
        isTrue,
      );
      expect(machine.snapshot.references, hasLength(1));
      expect(machine.projectClipboard(), '打开 @file:README.md');

      final cut = machine.cutRange(0, machine.snapshot.draft.length);
      expect(cut, '打开 @file:README.md');
      expect(machine.snapshot.draft, '');

      expect(machine.undo(), isTrue);
      expect(machine.snapshot.draft, startsWith('打开 @README.md'));
      expect(machine.redo(), isTrue);
      expect(machine.snapshot.draft, '');
    });

    test('运行中 submit 按 Queue/Steer 策略返回模式，但不会自动 flush queue', () {
      final machine = SessionComposerInputMachine()
        ..setDraft('继续分析')
        ..addQueuedMessage('q1', '排队消息');

      expect(
        machine.submit(running: true, busyEnter: BusyEnterMode.queue),
        SessionSubmitMode.queue,
      );
      expect(machine.snapshot.queue.map((item) => item.text), ['排队消息']);

      machine.setDraft('');
      expect(
        machine.submit(running: true, accelerated: true),
        SessionSubmitMode.steer,
      );
      expect(
        machine.submit(running: true, accelerated: false),
        isNull,
        reason: '空草稿普通 Enter 不应发送或 flush queue',
      );
      expect(machine.snapshot.queue, hasLength(1));
    });

    test('提交失败保留草稿，提交成功清空草稿和引用', () {
      final machine = SessionComposerInputMachine()..setDraft('保留这段草稿');
      machine.enterSubmitting();
      machine.settleSubmit(success: false, error: 'fixture failure');

      expect(machine.snapshot.draft, '保留这段草稿');
      expect(machine.snapshot.notice, 'fixture failure');
      expect(machine.snapshot.phase, SessionInputPhase.plain);

      machine.enterSubmitting();
      machine.settleSubmit(success: true);
      expect(machine.snapshot.draft, '');
      expect(machine.snapshot.references, isEmpty);
      expect(machine.snapshot.notice, isNull);
    });
  });
}
