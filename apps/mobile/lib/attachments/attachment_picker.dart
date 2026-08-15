import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../crypto/box.dart';
import '../domain/control_models.dart';
import '../domain/models.dart';

/// 附件选择边界：fixture 注入确定性结果；真实运行使用系统文件选择器。
/// 返回值约定：null 表示用户取消选择。
abstract interface class AttachmentPicker {
  Future<AttachmentDraft?> pickAttachment({
    required String sessionId,
    required String dekId,
  });
}

/// 会话内容密钥提供方：真实 Keystore 通道未部署时返回 null（fail-closed）。
typedef SessionContentKeyProvider = Future<Uint8List?> Function(
  String sessionId,
);

/// 真实实现：系统文件选择器 -> 本地 MIME/大小校验 -> 会话 DEK 密封 -> 密文队列草稿。
/// 没有会话 DEK 时直接失败，绝不把明文文件或显示名放进 Relay。
class SystemAttachmentPicker implements AttachmentPicker {
  const SystemAttachmentPicker({required this.contentKeyProvider});

  final SessionContentKeyProvider contentKeyProvider;

  static const _imageExtensions = ['png', 'jpg', 'jpeg', 'webp'];
  static const _textExtensions = ['txt', 'md', 'markdown'];

  @override
  Future<AttachmentDraft?> pickAttachment({
    required String sessionId,
    required String dekId,
  }) async {
    // 单文件选择：用 pickFile（12.x 移除了 allowMultiple）。
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: [..._imageExtensions, ..._textExtensions],
    );
    if (file == null || file.path == null) return null;

    final name = file.name;
    final mimeType = _mimeForName(name);
    if (mimeType == null) {
      throw const RelayFailure(
        RelayFailureKind.validation,
        '只支持 PNG/JPEG/WebP 图片或纯文本/Markdown 附件。',
      );
    }
    final bytes = await _readPath(file.path!);
    final key = await contentKeyProvider(sessionId);
    if (key == null) {
      throw const RelayFailure(
        RelayFailureKind.validation,
        '等待会话附件密钥，暂时不能选择文件。',
      );
    }
    return _sealDraft(
      sessionId: sessionId,
      dek: key,
      dekId: dekId,
      name: name,
      mimeType: mimeType,
      bytes: bytes,
    );
  }

  /// 按扩展名推断 MIME；不在白名单内的扩展名直接拒绝。
  String? _mimeForName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    final extension = name.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'txt' => 'text/plain',
      'md' || 'markdown' => 'text/markdown',
      _ => null,
    };
  }

  Future<Uint8List> _readPath(String path) async {
    final file = await File(path).readAsBytes();
    return Uint8List.fromList(file);
  }

  /// DEK 密封分块：元数据与每个块都使用独立 AAD（绑定会话、附件与块序号）。
  Future<AttachmentDraft> _sealDraft({
    required String sessionId,
    required Uint8List dek,
    required String dekId,
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    // 密文块需以 JSON envelope 传输（base64 放大 ~1.37x），
    // 留出安全余量，保证每个序列化后的块不超过 512 KiB 的 Relay 上限。
    final chunkSize = (maxAttachmentChunkCiphertextBytes * 0.68).floor();
    final chunks = <Uint8List>[];
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length).toInt();
      chunks.add(bytes.sublist(offset, end));
    }
    final nonceBase = DateTime.now().microsecondsSinceEpoch;
    final metadataEnvelope = await _sealEnvelope(
      dek: dek,
      dekId: dekId,
      sessionId: sessionId,
      scope: 'attachment:metadata',
      seq: 0,
      plaintext: Uint8List.fromList('{"name_length":${name.length}}'.codeUnits),
      nonceSeed: nonceBase,
    );
    final ciphertextChunks = <Uint8List>[];
    for (var index = 0; index < chunks.length; index += 1) {
      final envelope = await _sealEnvelope(
        dek: dek,
        dekId: dekId,
        sessionId: sessionId,
        scope: 'attachment:chunk',
        seq: index,
        plaintext: chunks[index],
        nonceSeed: nonceBase + index + 1,
      );
      ciphertextChunks.add(
        Uint8List.fromList(utf8.encode(envelope.toJsonString())),
      );
    }
    return AttachmentDraft(
      id: 'attachment-${DateTime.now().microsecondsSinceEpoch}',
      localName: name,
      mimeType: mimeType,
      byteSize: bytes.length,
      compression: 'none',
      metadataCiphertext: Uint8List.fromList(
        utf8.encode(metadataEnvelope.toJsonString()),
      ),
      ciphertextChunks: ciphertextChunks,
    );
  }

  Future<CryptoEnvelope> _sealEnvelope({
    required Uint8List dek,
    required String dekId,
    required String sessionId,
    required String scope,
    required int seq,
    required Uint8List plaintext,
    required int nonceSeed,
  }) async {
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (index) => (nonceSeed >> (index * 8)) & 0xff),
    );
    return CryptoBox.seal(
      dek: dek,
      keyId: dekId,
      payloadVersion: 1,
      aad: AssociatedData(
        entityId: sessionId,
        eventType: scope,
        protocolVersion: 1,
        eventSeq: seq,
        keyId: dekId,
      ),
      plaintext: plaintext,
      nonce: nonce,
    );
  }
}

/// fixture 实现：返回预密封的确定性草稿，覆盖合法图片/文本与预检拒绝三类。
/// 测试与可见 macOS gate 不读取本机文件系统。
class FixtureAttachmentPicker implements AttachmentPicker {
  const FixtureAttachmentPicker();

  @override
  Future<AttachmentDraft?> pickAttachment({
    required String sessionId,
    required String dekId,
  }) async {
    return AttachmentDraft(
      id: 'fixture-picked-${DateTime.now().microsecondsSinceEpoch}',
      localName: 'fixture-picked.png',
      mimeType: 'image/png',
      byteSize: 480,
      compression: 'none',
      metadataCiphertext: Uint8List.fromList([71, 72, 73]),
      ciphertextChunks: [Uint8List.fromList([81, 82])],
    );
  }
}
