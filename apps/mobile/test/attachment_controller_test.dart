import 'dart:math';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

void main() {
  group('ATTACH-01 附件控制器', () {
    test('MIME/大小预检拒绝不创建上传请求或附件状态', () async {
      final relay = _AttachmentSpyRelay(clock: () => _now);
      final controller = await _prepareWritableSession(relay);
      final rejected = controller.addAttachmentDraft(
        _draft(
          id: 'rejected-pdf',
          localName: 'fixture.pdf',
          mimeType: 'application/pdf',
        ),
      );

      expect(rejected, isFalse);
      expect(controller.attachments, isEmpty);
      expect(controller.attachmentRejections, hasLength(1));
      expect(controller.attachmentRejections.single.localName, 'fixture.pdf');
      expect(relay.uploadAttemptCount, 0);
    });

    test('分块按序上传；第二块可恢复失败后只从已确认块继续并幂等完成', () async {
      final relay = _FailAfterFirstChunkRelay(clock: () => _now);
      final controller = await _prepareWritableSession(relay);
      final draft = _draft(id: 'retry-text', localName: 'fixture-note.md');
      expect(controller.addAttachmentDraft(draft), isTrue);

      await controller.uploadAttachment(
        attachmentId: draft.id,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(
        controller.attachments.single.phase,
        AttachmentTransferPhase.failed,
      );
      expect(controller.attachments.single.completedChunks, 1);
      expect(relay.uploadedChunkIndexes, [0, 1]);
      expect(relay.completeAttemptCount, 0);

      await controller.uploadAttachment(
        attachmentId: draft.id,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(
        controller.attachments.single.phase,
        AttachmentTransferPhase.completed,
      );
      expect(controller.attachments.single.completedChunks, 2);
      expect(relay.uploadedChunkIndexes, [0, 1, 1]);
      expect(relay.completeAttemptCount, 1);

      await controller.uploadAttachment(
        attachmentId: draft.id,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(relay.completeAttemptCount, 1);
    });
  });
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 10, 30);

AttachmentDraft _draft({
  required String id,
  required String localName,
  String mimeType = 'text/markdown',
}) => AttachmentDraft(
  id: id,
  localName: localName,
  mimeType: mimeType,
  byteSize: 128,
  compression: 'none',
  metadataCiphertext: Uint8List.fromList([1, 2, 3]),
  ciphertextChunks: [
    Uint8List.fromList([11, 12]),
    Uint8List.fromList([13, 14]),
  ],
);

Future<SessionController> _prepareWritableSession(
  FixtureRelayRepository relay,
) async {
  await bootstrapFixtureOwner(relay);
  final controller = SessionController(
    relay: relay,
    clock: () => _now,
    random: _DeterministicRandom(),
  );
  await controller.initialize();
  final created = await controller.createSession(
    workspaceId: 'fixture-workspace',
    provider: 'codex',
    deviceId: _ownerDeviceId,
    canWrite: true,
  );
  expect(created, isNotNull);
  await controller.acquireSelectedLease(
    deviceId: _ownerDeviceId,
    canWrite: true,
  );
  return controller;
}

class _AttachmentSpyRelay extends FixtureRelayRepository {
  _AttachmentSpyRelay({super.clock});

  var uploadAttemptCount = 0;

  @override
  Future<AttachmentReceipt> uploadAttachmentChunk(
    AttachmentChunkUploadInput input,
  ) {
    uploadAttemptCount += 1;
    return super.uploadAttachmentChunk(input);
  }
}

/// 在第二块调用 Relay 前注入一次网络失败，确保重试从 controller 已确认的第一块继续。
class _FailAfterFirstChunkRelay extends FixtureRelayRepository {
  _FailAfterFirstChunkRelay({super.clock});

  final List<int> uploadedChunkIndexes = [];
  var completeAttemptCount = 0;
  var _didFailSecondChunk = false;

  @override
  Future<AttachmentReceipt> uploadAttachmentChunk(
    AttachmentChunkUploadInput input,
  ) async {
    uploadedChunkIndexes.add(input.chunkIndex);
    if (input.chunkIndex == 1 && !_didFailSecondChunk) {
      _didFailSecondChunk = true;
      throw const RelayFailure(
        RelayFailureKind.unavailable,
        '第二个 fixture 密文块暂时不可用。',
      );
    }
    return super.uploadAttachmentChunk(input);
  }

  @override
  Future<AttachmentReceipt> completeAttachment(AttachmentCompleteInput input) {
    completeAttemptCount += 1;
    return super.completeAttachment(input);
  }
}

class _DeterministicRandom implements Random {
  var _value = 0;

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => nextInt(1 << 20) / (1 << 20);

  @override
  int nextInt(int max) {
    _value += 1;
    return _value % max;
  }
}
