import 'dart:typed_data';

import 'models.dart';

/// Provider 能力只有三种公开状态；未知值和缺失项必须降级为 unsupported。
enum CapabilityAvailability {
  native('native', '原生'),
  emulated('emulated', '兼容'),
  unsupported('unsupported', '不可用');

  const CapabilityAvailability(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static CapabilityAvailability fromWire(Object? value) => switch (value) {
    'native' => CapabilityAvailability.native,
    'emulated' => CapabilityAvailability.emulated,
    _ => CapabilityAvailability.unsupported,
  };
}

/// 单项 capability 是 Relay/Daemon 声明的事实，客户端绝不根据 Provider 名称补猜。
class CapabilityEntry {
  const CapabilityEntry({
    required this.name,
    required this.availability,
    this.reason,
  });

  factory CapabilityEntry.fromRelayJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了无名称的能力项。');
    }
    final availability = CapabilityAvailability.fromWire(json['status']);
    final rawReason = json['reason'];
    return CapabilityEntry(
      name: name.trim(),
      availability: availability,
      reason: rawReason is String && rawReason.trim().isNotEmpty
          ? rawReason.trim()
          : availability == CapabilityAvailability.unsupported &&
                json['status'] is String &&
                json['status'] != 'unsupported'
          ? 'Provider 返回了未知能力状态。'
          : null,
    );
  }

  final String name;
  final CapabilityAvailability availability;
  final String? reason;

  bool get isSupported => availability != CapabilityAvailability.unsupported;
}

/// 一个 Provider 的能力快照。available=false 时所有入口都必须按 unavailable 处理。
class ProviderCapabilityProfile {
  const ProviderCapabilityProfile({
    required this.kind,
    required this.version,
    required this.available,
    required this.capabilities,
  });

  factory ProviderCapabilityProfile.fromRelayJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    if (kind is! String || kind.trim().isEmpty) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回了无名称的 Provider。',
      );
    }
    final rawCapabilities = json['capabilities'];
    if (rawCapabilities is! List) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay 返回的 Provider capability 格式错误。',
      );
    }
    return ProviderCapabilityProfile(
      kind: kind.trim(),
      version: json['version'] is String ? (json['version'] as String) : '',
      available: json['available'] == true,
      capabilities: rawCapabilities
          .whereType<Map>()
          .map(
            (entry) =>
                CapabilityEntry.fromRelayJson(Map<String, dynamic>.from(entry)),
          )
          .toList(growable: false),
    );
  }

  factory ProviderCapabilityProfile.unknown(String kind) =>
      ProviderCapabilityProfile(
        kind: kind.isEmpty ? 'unknown' : kind,
        version: '',
        available: false,
        capabilities: const [],
      );

  final String kind;
  final String version;
  final bool available;
  final List<CapabilityEntry> capabilities;

  /// provider 不可用和未声明能力都一律不可写，避免新能力被 UI 静默放行。
  CapabilityEntry capability(String name) {
    if (!available) {
      return CapabilityEntry(
        name: name,
        availability: CapabilityAvailability.unsupported,
        reason: 'Provider 当前不可用。',
      );
    }
    for (final entry in capabilities) {
      if (entry.name == name) return entry;
    }
    return CapabilityEntry(
      name: name,
      availability: CapabilityAvailability.unsupported,
      reason: 'Provider 未声明此能力。',
    );
  }
}

/// CapabilityMatrix 是 GET /v1/capabilities 的客户端投影。
class CapabilityMatrix {
  const CapabilityMatrix({required this.providers});

  factory CapabilityMatrix.fromRelayJson(Map<String, dynamic> json) {
    final rawProviders = json['providers'];
    if (rawProviders is! List) {
      throw const RelayFailure(
        RelayFailureKind.protocol,
        'Relay capability matrix 格式错误。',
      );
    }
    return CapabilityMatrix(
      providers: rawProviders
          .whereType<Map>()
          .map(
            (provider) => ProviderCapabilityProfile.fromRelayJson(
              Map<String, dynamic>.from(provider),
            ),
          )
          .toList(growable: false),
    );
  }

  static const empty = CapabilityMatrix(providers: []);

  final List<ProviderCapabilityProfile> providers;

  ProviderCapabilityProfile provider(String kind) {
    for (final profile in providers) {
      if (profile.kind == kind) return profile;
    }
    return ProviderCapabilityProfile.unknown(kind);
  }
}

enum PlanPhase {
  draft('draft', '草稿'),
  awaitingApproval('awaiting_approval', '等待确认'),
  active('active', '进行中'),
  rejected('rejected', '已拒绝');

  const PlanPhase(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

/// Plan 正文来源于本地已解密事件或 deterministic fixture，不从 Relay 白名单元数据推断。
class SessionPlanSummary {
  const SessionPlanSummary({
    required this.title,
    required this.summary,
    required this.phase,
  });

  final String title;
  final String summary;
  final PlanPhase phase;

  SessionPlanSummary copyWith({PlanPhase? phase}) => SessionPlanSummary(
    title: title,
    summary: summary,
    phase: phase ?? this.phase,
  );
}

enum GoalPhase {
  active('active', '进行中'),
  paused('paused', '已暂停'),
  completed('completed', '已完成');

  const GoalPhase(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

/// Goal 与跨工具子代理无关；它只描述当前会话的本地目标状态。
class SessionGoalSummary {
  const SessionGoalSummary({
    required this.title,
    required this.progressLabel,
    required this.phase,
  });

  final String title;
  final String progressLabel;
  final GoalPhase phase;

  SessionGoalSummary copyWith({GoalPhase? phase}) => SessionGoalSummary(
    title: title,
    progressLabel: progressLabel,
    phase: phase ?? this.phase,
  );
}

enum SkillRisk {
  normal('normal', '常规'),
  high('high', '高风险');

  const SkillRisk(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

enum TodoItemStatus {
  pending('pending', '待处理'),
  inProgress('in_progress', '进行中'),
  completed('completed', '已完成');

  const TodoItemStatus(this.wireValue, this.label);

  final String wireValue;
  final String label;
}

/// v0.5/P5-E4：Todo 是 Host 投影的 whole-list snapshot。
///
/// Flutter 端只读展示，不提供本地编辑、删除或重排；列表为空时 input.dock 不渲染。
class SessionTodoItem {
  const SessionTodoItem({required this.content, required this.status});

  final String content;
  final TodoItemStatus status;
}

/// Skill catalog 只保留可展示的最小摘要；参数和 Provider 私有 payload 留在加密边界内。
class SessionSkillDescriptor {
  const SessionSkillDescriptor({
    required this.id,
    required this.title,
    required this.summary,
    required this.risk,
  });

  final String id;
  final String title;
  final String summary;
  final SkillRisk risk;
}

/// 脱敏 usage 摘要：只展示计数，不渲染 prompt 或回复正文。
/// v0.3/P1：扩展 cache 计数与 context 窗口，用于上下文占用警告。
class SessionUsageSummary {
  const SessionUsageSummary({
    required this.inputTokens,
    required this.outputTokens,
    required this.contextTokens,
    this.cacheReadTokens = 0,
    this.cacheCreationTokens = 0,
    this.contextWindowTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int contextTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final int contextWindowTokens;

  /// 上下文占用比例；无窗口信息时返回 null（不触发警告）。
  double? get contextRatio {
    if (contextWindowTokens <= 0) return null;
    if (contextTokens <= 0) return 0;
    return contextTokens / contextWindowTokens;
  }

  /// 展示文案只含计数。
  String get label {
    final base =
        '↑${_compact(inputTokens)} · ↓${_compact(outputTokens)} · 上下文 ${_compact(contextTokens)}';
    if (cacheReadTokens > 0 || cacheCreationTokens > 0) {
      return '$base · 缓存 ${_compact(cacheReadTokens + cacheCreationTokens)}';
    }
    return base;
  }

  static String _compact(int value) {
    if (value < 1000) return '$value';
    if (value < 1000 * 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '${(value / (1000 * 1000)).toStringAsFixed(1)}m';
  }

  /// UI 展示用（与 _compact 相同逻辑，供 warning 文案复用）。
  static String compactForDisplay(int value) => _compact(value);
}

/// Host 投影的图片接纳限制。
///
/// 这些值只用于 composer 的快速预检，Relay/Daemon 仍必须在真正接收密文时
/// 重新校验。投影缺失时不能由客户端猜测 Provider 的图片词汇或额度。
class SessionImageLimits {
  const SessionImageLimits({
    required this.maxImageBytes,
    required this.maxImagesPerMessage,
    required this.maxMessageImageBytes,
    required this.mediaTypes,
  });

  final int maxImageBytes;
  final int maxImagesPerMessage;
  final int maxMessageImageBytes;
  final List<String> mediaTypes;

  bool accepts(String mimeType) => mediaTypes.contains(mimeType);

  /// 按 DeepSeek Harness 的 intake 顺序检查整批图片：类型、数量、单张大小、总大小。
  /// 返回 null 表示快速预检通过；结构和密文分块校验仍由 [AttachmentDraft.validate] 完成。
  String? validateBatch({
    required Iterable<AttachmentDraft> existing,
    required Iterable<AttachmentDraft> incoming,
  }) {
    final currentImages = existing.where((draft) => draft.isImage).toList();
    final incomingImages = incoming.where((draft) => draft.isImage).toList();

    for (final draft in incomingImages) {
      if (!accepts(draft.mimeType)) {
        return '图片类型 ${draft.mimeType} 不受当前会话支持。';
      }
    }

    // 替换同 id 草稿时不重复计数，避免重试/重新选择把旧项算两次。
    final replacedIds = incoming.map((draft) => draft.id).toSet();
    final retainedImages = currentImages
        .where((draft) => !replacedIds.contains(draft.id))
        .toList(growable: false);
    if (retainedImages.length + incomingImages.length > maxImagesPerMessage) {
      return '图片数量超过上限（最多 $maxImagesPerMessage 张）。';
    }

    for (final draft in incomingImages) {
      if (draft.byteSize > maxImageBytes) {
        return '单张图片超过限制（最大 ${formatByteCount(maxImageBytes)}）。';
      }
    }
    final totalBytes = [
      ...retainedImages,
      ...incomingImages,
    ].fold<int>(0, (sum, draft) => sum + draft.byteSize);
    if (totalBytes > maxMessageImageBytes) {
      return '图片总大小超过限制（最大 ${formatByteCount(maxMessageImageBytes)}）。';
    }
    return null;
  }
}

/// 统一的脱敏字节数文案；只展示限制，不输出文件内容或路径。
String formatByteCount(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KiB';
  return '$bytes B';
}

/// 会话控制面由已解密事件或 fixture 填充；空状态明确说明尚未获得该类事件。
class SessionControlState {
  const SessionControlState({
    required this.model,
    required this.effort,
    this.plan,
    this.goal,
    this.todos = const [],
    this.skills = const [],
    // v0.2/P3：模型/effort 目录与 usage 只来自已解密事件或 deterministic fixture。
    this.models = const [],
    this.efforts = const [],
    this.imageLimits,
    this.usage,
    // v0.3/P0：permission mode 选择器（Happy sessionSetAgentModes 对齐）。
    this.permissionMode,
    this.availablePermissionModes = const [],
  });

  const SessionControlState.empty()
    : model = null,
      effort = null,
      plan = null,
      goal = null,
      todos = const [],
      skills = const [],
      models = const [],
      efforts = const [],
      imageLimits = null,
      usage = null,
      permissionMode = null,
      availablePermissionModes = const [];

  final String? model;
  final String? effort;
  final SessionPlanSummary? plan;
  final SessionGoalSummary? goal;
  final List<SessionTodoItem> todos;
  final List<SessionSkillDescriptor> skills;
  final List<String> models;
  final List<String> efforts;
  final SessionImageLimits? imageLimits;
  final SessionUsageSummary? usage;
  final String? permissionMode;
  final List<String> availablePermissionModes;

  SessionControlState copyWith({
    String? model,
    String? effort,
    SessionPlanSummary? plan,
    SessionGoalSummary? goal,
    bool clearGoal = false,
    List<SessionTodoItem>? todos,
    List<SessionSkillDescriptor>? skills,
    List<String>? models,
    List<String>? efforts,
    SessionImageLimits? imageLimits,
    SessionUsageSummary? usage,
    String? permissionMode,
    List<String>? availablePermissionModes,
  }) => SessionControlState(
    model: model ?? this.model,
    effort: effort ?? this.effort,
    plan: plan ?? this.plan,
    goal: clearGoal ? null : goal ?? this.goal,
    todos: todos ?? this.todos,
    skills: skills ?? this.skills,
    models: models ?? this.models,
    efforts: efforts ?? this.efforts,
    imageLimits: imageLimits ?? this.imageLimits,
    usage: usage ?? this.usage,
    permissionMode: permissionMode ?? this.permissionMode,
    availablePermissionModes:
        availablePermissionModes ?? this.availablePermissionModes,
  );
}

/// 高风险 Skill 仅能先进入此本地确认态；创建确认态本身不能触发 Provider 或 Relay 写请求。
class SkillConfirmation {
  const SkillConfirmation({required this.skill});

  final SessionSkillDescriptor skill;
}

const maxImageAttachmentBytes = 10 * 1024 * 1024;
const maxTextAttachmentBytes = 1 * 1024 * 1024;
const maxAttachmentChunks = 64;
const maxAttachmentChunkCiphertextBytes = 512 * 1024;
const maxAttachmentMetadataCiphertextBytes = 16 * 1024;

/// AttachmentDraft 只保存在内存：localName 供 chip 展示，绝不序列化到 Relay 请求或本地缓存。
class AttachmentDraft {
  AttachmentDraft({
    required this.id,
    required this.localName,
    required this.mimeType,
    required this.byteSize,
    required this.compression,
    required Uint8List metadataCiphertext,
    required List<Uint8List> ciphertextChunks,
  }) : metadataCiphertext = Uint8List.fromList(metadataCiphertext),
       ciphertextChunks = List<Uint8List>.unmodifiable(
         ciphertextChunks.map(Uint8List.fromList),
       );

  final String id;
  final String localName;
  final String mimeType;
  final int byteSize;
  final String compression;
  final Uint8List metadataCiphertext;
  final List<Uint8List> ciphertextChunks;

  int get totalChunks => ciphertextChunks.length;

  bool get isImage => mimeType.startsWith('image/');

  /// 所有白名单和边界在本机先失败；Relay 仍会重复校验，不能把客户端校验作为信任边界。
  void validate() {
    if (id.trim().isEmpty || id.length > 128 || localName.trim().isEmpty) {
      throw const RelayFailure.validation('附件缺少本地标识。');
    }
    if (byteSize <= 0 || totalChunks < 1 || totalChunks > maxAttachmentChunks) {
      throw const RelayFailure.validation('附件大小或分块数超出限制。');
    }
    if (metadataCiphertext.isEmpty ||
        metadataCiphertext.length > maxAttachmentMetadataCiphertextBytes) {
      throw const RelayFailure.validation('附件元数据密文无效。');
    }
    final accepted = switch (mimeType) {
      'image/png' || 'image/jpeg' || 'image/webp' || 'image/gif' =>
        compression == 'none' && byteSize <= maxImageAttachmentBytes,
      'text/plain' || 'text/markdown' =>
        (compression == 'none' || compression == 'gzip') &&
            byteSize <= maxTextAttachmentBytes,
      _ => false,
    };
    if (!accepted) {
      throw const RelayFailure.validation('只支持 10 MiB 内图片或 1 MiB 内文本附件。');
    }
    for (final chunk in ciphertextChunks) {
      if (chunk.isEmpty || chunk.length > maxAttachmentChunkCiphertextBytes) {
        throw const RelayFailure.validation('附件密文分块无效。');
      }
    }
  }
}

/// 上传 DTO 不携带 localName；Relay 只获得密文、MIME、大小、压缩方式与会话 fencing 信息。
class AttachmentChunkUploadInput {
  const AttachmentChunkUploadInput({
    required this.attachmentId,
    required this.sessionId,
    required this.mimeType,
    required this.byteSize,
    required this.compression,
    required this.metadataCiphertext,
    required this.chunkIndex,
    required this.totalChunks,
    required this.ciphertext,
    required this.idempotencyKey,
    required this.leaseEpoch,
    required this.deviceId,
  });

  final String attachmentId;
  final String sessionId;
  final String mimeType;
  final int byteSize;
  final String compression;
  final Uint8List metadataCiphertext;
  final int chunkIndex;
  final int totalChunks;
  final Uint8List ciphertext;
  final String idempotencyKey;
  final int leaseEpoch;
  final String deviceId;

  void validate() {
    if (sessionId.trim().isEmpty ||
        idempotencyKey.trim().isEmpty ||
        deviceId.trim().isEmpty ||
        leaseEpoch <= 0 ||
        totalChunks < 1 ||
        totalChunks > maxAttachmentChunks ||
        chunkIndex < 0 ||
        chunkIndex >= totalChunks) {
      throw const RelayFailure.validation('附件上传缺少会话控制信息。');
    }
    AttachmentDraft(
      id: attachmentId,
      // 仅为复用白名单校验而构造的内存占位；此值不会进入任何 HTTP DTO。
      localName: 'opaque-local-draft',
      mimeType: mimeType,
      byteSize: byteSize,
      compression: compression,
      metadataCiphertext: metadataCiphertext,
      ciphertextChunks: List<Uint8List>.filled(totalChunks, ciphertext),
    ).validate();
  }
}

class AttachmentCompleteInput {
  const AttachmentCompleteInput({
    required this.attachmentId,
    required this.sessionId,
    required this.totalChunks,
    required this.idempotencyKey,
    required this.leaseEpoch,
    required this.deviceId,
  });

  final String attachmentId;
  final String sessionId;
  final int totalChunks;
  final String idempotencyKey;
  final int leaseEpoch;
  final String deviceId;

  void validate() {
    if (attachmentId.trim().isEmpty ||
        sessionId.trim().isEmpty ||
        idempotencyKey.trim().isEmpty ||
        deviceId.trim().isEmpty ||
        leaseEpoch <= 0 ||
        totalChunks < 1 ||
        totalChunks > maxAttachmentChunks) {
      throw const RelayFailure.validation('附件完成请求无效。');
    }
  }
}

/// 回执不回显密文或显示名，上传器仅用它驱动本地进度与幂等提示。
class AttachmentReceipt {
  const AttachmentReceipt({
    required this.attachmentId,
    required this.chunkIndex,
    required this.status,
    required this.idempotent,
  });

  factory AttachmentReceipt.fromRelayJson(Map<String, dynamic> json) {
    final index = json['chunk_index'];
    final idempotent = json['idempotent'];
    if (index is! num || idempotent is! bool) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 附件回执格式错误。');
    }
    return AttachmentReceipt(
      attachmentId: _requiredControlString(json, 'attachment_id'),
      chunkIndex: index.toInt(),
      status: _requiredControlString(json, 'status'),
      idempotent: idempotent,
    );
  }

  final String attachmentId;
  final int chunkIndex;
  final String status;
  final bool idempotent;
}

enum AttachmentTransferPhase { queued, uploading, failed, completed }

/// 上传进度只在当前会话控制器内存中存在，应用重启后不会把 localName 或明文恢复到缓存。
class AttachmentTransfer {
  const AttachmentTransfer({
    required this.draft,
    required this.phase,
    this.completedChunks = 0,
    this.errorMessage,
  });

  final AttachmentDraft draft;
  final AttachmentTransferPhase phase;
  final int completedChunks;
  final String? errorMessage;

  double get progress => draft.totalChunks == 0
      ? 0
      : completedChunks.clamp(0, draft.totalChunks).toDouble() /
            draft.totalChunks;

  AttachmentTransfer copyWith({
    AttachmentTransferPhase? phase,
    int? completedChunks,
    String? errorMessage,
    bool clearError = false,
  }) => AttachmentTransfer(
    draft: draft,
    phase: phase ?? this.phase,
    completedChunks: completedChunks ?? this.completedChunks,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

/// 本机预检拒绝也要在 composer 可见，但不生成上传请求或持久化记录。
class AttachmentRejection {
  const AttachmentRejection({required this.localName, required this.reason});

  final String localName;
  final String reason;
}

String _requiredControlString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw RelayFailure(RelayFailureKind.protocol, 'Relay 响应缺少 $field。');
  }
  return value;
}
