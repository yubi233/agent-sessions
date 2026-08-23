import 'dart:async';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/ui/session/session_workspace_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

void main() {
  group('MOBILE-V05-16 Workspace controller', () {
    test('目录登记后打开目标会话才迁移草稿', () async {
      final relay = FixtureRelayRepository();
      final controller = await _writableController(relay);
      final sourceWorkspace = await controller.createWorkspaceFromDirectory(
        canonicalRoot: '/fixture/source',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final targetWorkspace = await controller.createWorkspaceFromDirectory(
        canonicalRoot: '/fixture/target',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final source = await controller.createSession(
        workspaceId: sourceWorkspace!.id,
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      controller.saveComposerDraft(source!.id, '迁移前草稿');

      final target = await controller.openWorkspace(
        workspaceId: targetWorkspace!.id,
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(target, isNotNull);
      expect(controller.selectedSessionId, target!.id);
      expect(controller.composerDraftFor(target.id), '迁移前草稿');
      expect(controller.composerDraftFor(source.id), isNull);
      expect(controller.workspaceSettling, isFalse);
      expect(controller.pendingWorkspaceId, isNull);
    });

    test('会话绑定图片时跨 workspace 迁移失败保留输入', () async {
      final relay = FixtureRelayRepository();
      final controller = await _writableController(relay);
      final first = await controller.createWorkspaceFromDirectory(
        canonicalRoot: '/fixture/images-source',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final second = await controller.createWorkspaceFromDirectory(
        canonicalRoot: '/fixture/images-target',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final source = await controller.createSession(
        workspaceId: first!.id,
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      controller.saveComposerDraft(source!.id, '保留草稿');
      expect(controller.addAttachmentDraft(_imageDraft()), isTrue);

      final target = await controller.openWorkspace(
        workspaceId: second!.id,
        provider: 'codex',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );

      expect(target, isNotNull);
      expect(controller.selectedSessionId, target!.id);
      expect(controller.composerDraftFor(target.id), '保留草稿');
      expect(controller.composerDraftFor(source.id), isNull);
      expect(controller.attachments, hasLength(1));
      expect(controller.workspaceErrorMessage, isNull);
    });
  });

  group('MOBILE-V05-16 Workspace picker', () {
    testWidgets('目录 flow 添加 workspace 并选择，pending 期间单飞', (tester) async {
      final relay = FixtureRelayRepository();
      final controller = await _writableController(relay);
      final selected = ValueNotifier<String?>(null);
      final pending = Completer<bool>();
      var holdPick = true;
      var pickCalls = 0;
      await tester.pumpWidget(
        _PickerHarness(
          controller: controller,
          selected: selected,
          directoryFlow: (_) async => '/fixture/added',
          onPick: (workspaceId) async {
            pickCalls += 1;
            if (holdPick) return pending.future;
            return true;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('session-workspace-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('session-workspace-add')));
      for (var frame = 0; frame < 5 && controller.workspaces.isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump();
      expect(controller.workspaces, hasLength(1));
      expect(pickCalls, 1);
      expect(selected.value, isNull);
      expect(
        find.byKey(const Key('session-workspace-pending')),
        findsOneWidget,
      );

      pending.complete(true);
      await tester.pumpAndSettle();
      expect(selected.value, controller.workspaces.single.id);

      holdPick = false;
      await tester.tap(find.byKey(const Key('session-workspace-picker')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('session-workspace-${controller.workspaces.single.id}')),
        findsOneWidget,
      );
    });

    testWidgets('目录登记失败可重新选择且旧请求不覆盖新结果', (tester) async {
      final relay = FixtureRelayRepository();
      final controller = await _writableController(relay);
      await controller.createWorkspaceFromDirectory(
        canonicalRoot: '/fixture/duplicate',
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      final paths = <String>['/fixture/duplicate', '/fixture/retry-success'];
      var flowIndex = 0;
      final selected = ValueNotifier<String?>(null);
      await tester.pumpWidget(
        _PickerHarness(
          controller: controller,
          selected: selected,
          directoryFlow: (_) async => paths[flowIndex++],
        ),
      );

      await tester.tap(find.byKey(const Key('session-workspace-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('session-workspace-add')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('session-workspace-error-dialog')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('session-workspace-choose-again')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('session-workspace-error-dialog')),
        findsNothing,
      );
      expect(controller.workspaces, hasLength(2));
      expect(selected.value, isNotNull);
      expect(flowIndex, 2);
    });

    testWidgets('无 directory occupant 显示不可用，删除态要求重新选择', (tester) async {
      final relay = FixtureRelayRepository();
      final controller = await _writableController(relay);
      final selected = ValueNotifier<String?>('workspace-deleted');
      await tester.pumpWidget(
        _PickerHarness(
          controller: controller,
          selected: selected,
          markMissingAsDeleted: true,
        ),
      );

      expect(find.text('工作区已移除'), findsOneWidget);
      expect(find.text('请重新选择可用工作区。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('session-workspace-picker')));
      await tester.pumpAndSettle();
      expect(find.text('Host 目录选择不可用'), findsOneWidget);
      final add = tester.widget<MenuItemButton>(
        find.byKey(const Key('session-workspace-add')),
      );
      expect(add.onPressed, isNull);
    });
  });
}

class _PickerHarness extends StatelessWidget {
  const _PickerHarness({
    required this.controller,
    required this.selected,
    this.directoryFlow,
    this.onPick,
    this.markMissingAsDeleted = false,
  });

  final SessionController controller;
  final ValueNotifier<String?> selected;
  final WorkspaceDirectoryFlow? directoryFlow;
  final Future<bool> Function(String workspaceId)? onPick;
  final bool markMissingAsDeleted;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          child: ValueListenableBuilder<String?>(
            valueListenable: selected,
            builder: (context, value, _) => SessionWorkspacePicker(
              controller: controller,
              selectedId: value,
              canWrite: true,
              deviceId: _ownerDeviceId,
              directoryFlow: directoryFlow,
              markMissingAsDeleted: markMissingAsDeleted,
              onPick: (workspaceId) async {
                final accepted =
                    await (onPick?.call(workspaceId) ??
                        Future<bool>.value(true));
                if (accepted) selected.value = workspaceId;
                return accepted;
              },
            ),
          ),
        ),
      ),
    ),
  );
}

Future<SessionController> _writableController(
  FixtureRelayRepository relay,
) async {
  await bootstrapFixtureOwner(relay);
  final controller = SessionController(relay: relay);
  await controller.initialize();
  return controller;
}

AttachmentDraft _imageDraft() => AttachmentDraft(
  id: 'workspace-image',
  localName: 'workspace.png',
  mimeType: 'image/png',
  byteSize: 128,
  compression: 'none',
  metadataCiphertext: Uint8List.fromList([1, 2, 3]),
  ciphertextChunks: [
    Uint8List.fromList([4, 5, 6]),
  ],
);

const _ownerDeviceId = 'android-owner-fixture';
