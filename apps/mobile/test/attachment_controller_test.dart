import 'dart:math';
import 'dart:typed_data';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
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

  group('MOBILE-V05-17/P5-E5 图片 intake 预检', () {
    const limits = SessionImageLimits(
      maxImageBytes: 10 * 1024 * 1024,
      maxImagesPerMessage: 2,
      maxMessageImageBytes: 12 * 1024 * 1024,
      mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
    );

    test('类型 -> 数量 -> 单张 -> 总大小的错误优先级由同一 oracle 保证', () {
      AttachmentDraft image(String id, String mimeType, int bytes) => _draft(
        id: id,
        localName: '$id.png',
        mimeType: mimeType,
        byteSize: bytes,
      );

      expect(
        limits.validateBatch(
          existing: const [],
          incoming: [image('bad', 'image/tiff', 1)],
        ),
        contains('图片类型'),
      );

      expect(
        limits.validateBatch(
          existing: const [],
          incoming: [
            image('a', 'image/png', 1),
            image('b', 'image/png', 1),
            image('c', 'image/png', 1),
          ],
        ),
        contains('图片数量超过上限'),
      );

      expect(
        limits.validateBatch(
          existing: const [],
          incoming: [image('big', 'image/png', 11 * 1024 * 1024)],
        ),
        contains('单张图片超过限制'),
      );

      expect(
        limits.validateBatch(
          existing: const [],
          incoming: [
            image('a', 'image/png', 7 * 1024 * 1024),
            image('b', 'image/png', 7 * 1024 * 1024),
          ],
        ),
        contains('图片总大小超过限制'),
      );

      expect(
        limits.validateBatch(
          existing: const [],
          incoming: [
            image('a', 'image/png', 1),
            image('b', 'image/jpeg', 2),
          ],
        ),
        isNull,
      );
    });

    test('SessionController.addAttachmentDrafts 整批原子拒绝并保留原附件', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      final controller = await _prepareWritableSession(relay);
      expect(controller.addAttachmentDraft(_draft(id: 'img-1', localName: 'a.png', mimeType: 'image/png')), isTrue);
      expect(controller.addAttachmentDraft(_draft(id: 'img-2', localName: 'b.png', mimeType: 'image/png')), isTrue);
      expect(controller.attachments, hasLength(2));

      // 第三张超过 fixture 数量上限：整批拒收，不新增也不移除已有附件。
      final rejected = controller.addAttachmentDraft(
        _draft(id: 'img-3', localName: 'c.png', mimeType: 'image/png'),
      );
      expect(rejected, isFalse);
      expect(controller.attachments, hasLength(2));
      expect(controller.attachmentRejections, hasLength(1));
      expect(controller.attachmentRejections.single.reason, contains('图片数量超过上限'));

      // 未知 slash command 带图不阻断普通文本；已知 command 才原子拒绝。
      expect(controller.commandImageAdmissionError('普通文本'), isNull);
      expect(controller.commandImageAdmissionError('/unknown-command 文本'), isNull);
      expect(
        controller.commandImageAdmissionError('/goal 创建目标'),
        contains('不支持图片附件'),
      );
      expect(
        controller.commandImageAdmissionError('/permission danger-full-access'),
        contains('不支持图片附件'),
      );
    });
  });

  group('V085-02 attachments refs wire', () {
    test('上传完成后的附件以 opaque refs 随 send 密文发送；受理后清空队列', () async {
      final relay = _SendRefsSpyRelay(clock: () => _now);
      final controller = await _prepareWritableSession(relay);
      final draft = _draft(
        id: 'wire-image',
        localName: 'wire.png',
        mimeType: 'image/png',
        byteSize: 480,
      );
      expect(controller.addAttachmentDraft(draft), isTrue);
      await controller.uploadAttachment(
        attachmentId: draft.id,
        deviceId: _ownerDeviceId,
        canWrite: true,
      );
      expect(controller.attachments.single.phase, AttachmentTransferPhase.completed);

      await controller.sendMessage(
        message: '看这张图',
        deviceId: _ownerDeviceId,
        canWrite: true,
        awaitTurnCompletion: false,
      );
      expect(relay.submittedCiphertexts, isNotEmpty);
      // spy 记录的是 fixture_payload 本体（sendMessage 的 ciphertext['fixture_payload']），
      // 直接在其中定位携带 attachments refs 的 send 密文。
      final sendPayload = relay.submittedCiphertexts
          .lastWhere((entry) => entry['attachments'] != null, orElse: () => const {});
      final payload = sendPayload;
      final refs = (payload['attachments'] as List<dynamic>?) ?? const [];
      expect(refs, hasLength(1));
      final ref = refs.single as Map<String, dynamic>;
      expect(ref['attachment_id'], 'wire-image');
      expect(ref['mime'], 'image/png');
      expect(ref['size_bytes'], 480);
      // 草稿 sha256 缺省（null）时 refs 省略 sha256 键（Daemon 侧不校验）。
      expect(ref.containsKey('sha256'), isFalse);
      // 受理成功后附件队列清空（refs 已随密文发送，不重复引用）。
      expect(controller.attachments, isEmpty);
    });
  });
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 10, 30);

AttachmentDraft _draft({
  required String id,
  required String localName,
  String mimeType = 'text/markdown',
  int byteSize = 128,
}) => AttachmentDraft(
  id: id,
  localName: localName,
  mimeType: mimeType,
  byteSize: byteSize,
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

/// v0.8.5 §3.1：记录 session.send 的密文 payload，供 refs wire 断言。
class _SendRefsSpyRelay extends FixtureRelayRepository {
  _SendRefsSpyRelay({super.clock});

  final List<Map<String, dynamic>> submittedCiphertexts = [];

  @override
  Future<SessionCommandReceipt> submitSessionCommand(
    String sessionId,
    SessionCommandInput input,
  ) async {
    final payload = input.ciphertext?['fixture_payload'];
    if (payload is Map) {
      submittedCiphertexts.add(Map<String, dynamic>.from(payload));
    }
    return super.submitSessionCommand(sessionId, input);
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
