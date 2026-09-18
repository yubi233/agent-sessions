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

/// 单个模型的安全能力元数据；只保留上下文窗口和推理目录，不含 Provider 配置。
class CapabilityModelDetail {
  const CapabilityModelDetail({
    this.contextWindowTokens = 0,
    this.reasoning = false,
    this.efforts = const [],
  });

  final int contextWindowTokens;
  final bool reasoning;
  final List<String> efforts;
}

class CapabilityModelOption {
  const CapabilityModelOption({
    required this.provider,
    required this.value,
    required this.id,
    required this.name,
    this.description,
    this.contextWindowTokens = 0,
    this.reasoning = false,
    this.efforts = const [],
  });

  factory CapabilityModelOption.fromRelayJson(Map<String, dynamic> json) {
    final provider = _nullableControlString(json['provider']) ?? '';
    final value = _nullableControlString(json['value']) ?? '';
    final id = _nullableControlString(json['id']) ?? '';
    final name = _nullableControlString(json['name']) ?? id;
    return CapabilityModelOption(
      provider: provider,
      value: value,
      id: id,
      name: name,
      description: _nullableControlString(json['description']),
      contextWindowTokens:
          _intFromControlJson(json['context_window_tokens']) ?? 0,
      reasoning: json['reasoning'] == true,
      efforts: _stringListFromControlJson(json['efforts']),
    );
  }

  final String provider;
  final String value;
  final String id;
  final String name;
  final String? description;
  final int contextWindowTokens;
  final bool reasoning;
  final List<String> efforts;
}

class CapabilityModelGroup {
  const CapabilityModelGroup({
    required this.id,
    required this.name,
    required this.models,
  });

  factory CapabilityModelGroup.fromRelayJson(Map<String, dynamic> json) {
    final id = _nullableControlString(json['id']) ?? '';
    final rawModels = json['models'];
    return CapabilityModelGroup(
      id: id,
      name: _nullableControlString(json['name']) ?? id,
      models: rawModels is List
          ? rawModels
                .whereType<Map>()
                .map(
                  (item) => CapabilityModelOption.fromRelayJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .where(
                  (item) =>
                      item.provider.isNotEmpty &&
                      item.value.isNotEmpty &&
                      item.id.isNotEmpty,
                )
                .toList(growable: false)
          : const [],
    );
  }

  final String id;
  final String name;
  final List<CapabilityModelOption> models;
}

/// 单项 capability 是 Relay/Daemon 声明的事实，客户端绝不根据 Provider 名称补猜。
class CapabilityEntry {
  const CapabilityEntry({
    required this.name,
    required this.availability,
    this.reason,
    this.options = const [],
    this.defaultOption,
    this.modelDetails = const {},
    this.modelGroups = const [],
  });

  factory CapabilityEntry.fromRelayJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const RelayFailure(RelayFailureKind.protocol, 'Relay 返回了无名称的能力项。');
    }
    final availability = CapabilityAvailability.fromWire(json['status']);
    final rawReason = json['reason'];
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions
              .whereType<String>()
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toSet()
              .toList(growable: false)
        : const <String>[];
    final rawDefault = json['default'];
    final defaultOption =
        rawDefault is String && options.contains(rawDefault.trim())
        ? rawDefault.trim()
        : null;
    final rawModelDetails = json['model_details'];
    final modelDetails = <String, CapabilityModelDetail>{};
    if (rawModelDetails is Map) {
      for (final entry in rawModelDetails.entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final value = Map<String, dynamic>.from(entry.value as Map);
        final rawEfforts = value['efforts'];
        modelDetails[entry.key as String] = CapabilityModelDetail(
          contextWindowTokens:
              _intFromControlJson(value['context_window_tokens']) ?? 0,
          reasoning: value['reasoning'] == true,
          efforts: rawEfforts is List
              ? rawEfforts.whereType<String>().toList(growable: false)
              : const [],
        );
      }
    }
    final rawModelGroups = json['model_groups'];
    final modelGroups = rawModelGroups is List
        ? rawModelGroups
              .whereType<Map>()
              .map(
                (item) => CapabilityModelGroup.fromRelayJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((group) => group.id.isNotEmpty && group.models.isNotEmpty)
              .toList(growable: false)
        : const <CapabilityModelGroup>[];
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
      options: options,
      defaultOption: defaultOption,
      modelDetails: modelDetails,
      modelGroups: modelGroups,
    );
  }

  final String name;
  final CapabilityAvailability availability;
  final String? reason;

  /// Host 提供的安全选项目录；客户端不得按 Provider 名称自行补全。
  final List<String> options;

  /// 只有同时存在于 [options] 中的默认值才被接受。
  final String? defaultOption;

  /// 按 provider/model 索引的模型安全元数据。
  final Map<String, CapabilityModelDetail> modelDetails;
  final List<CapabilityModelGroup> modelGroups;

  bool get isSupported => availability != CapabilityAvailability.unsupported;
}

/// 一个 Provider 的能力快照。available=false 时所有入口都必须按 unavailable 处理。
class ProviderCapabilityProfile {
  const ProviderCapabilityProfile({
    required this.kind,
    required this.version,
    required this.available,
    required this.capabilities,
    this.factsSource = '',
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
      // v0.9.2 G1：facts_source 是 additive 字段，回答"谁在声明这份可用性"。
      // 旧 Relay 不返回该字段时必须解析为空串而不是报错，保持向后兼容。
      factsSource: json['facts_source'] is String
          ? (json['facts_source'] as String).trim()
          : '',
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
        factsSource: '',
        capabilities: const [],
      );

  final String kind;
  final String version;
  final bool available;
  final List<CapabilityEntry> capabilities;

  /// v0.9.2 G1：可用性事实来源（relay / terminal / unavailable；旧 Relay 为空串）。
  /// 该字段只用于诊断与解释，不参与门控决策——门控仍然只由 available 与
  /// 各能力的 status 决定，避免新增字段改变既有安全语义。
  final String factsSource;

  /// 该 Provider 是否由执行侧（Daemon/Terminal）声明可用。
  /// 云端 Relay 自己跑不了 DSH 时，手机看到的就是这种事实。
  bool get factsFromExecutionSide => factsSource == 'terminal';

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

  /// 返回 Host 为指定能力声明的默认选项；缺失或不在目录中时返回 null。
  String? defaultOptionFor(String name) => capability(name).defaultOption;

  /// 返回 Host 声明的安全选项目录副本，防止调用方修改 capability 快照。
  List<String> optionsFor(String name) =>
      List<String>.unmodifiable(capability(name).options);

  /// 返回 Host 声明的指定模型安全元数据；未知模型不猜测。
  CapabilityModelDetail? modelDetailFor(String name, String model) =>
      capability(name).modelDetails[model.trim()];
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
    this.ttftMs,
    this.decodeThroughput,
  });

  factory SessionUsageSummary.fromRelayJson(Map<String, dynamic> json) {
    final input = _intFromControlJson(json['input_tokens']) ?? 0;
    final output = _intFromControlJson(json['output_tokens']) ?? 0;
    final cacheRead = _intFromControlJson(json['cache_read_tokens']) ?? 0;
    final cacheWrite =
        _intFromControlJson(json['cache_write_tokens']) ??
        _intFromControlJson(json['cache_creation_tokens']) ??
        0;
    return SessionUsageSummary(
      inputTokens: input,
      outputTokens: output,
      contextTokens:
          _intFromControlJson(json['context_tokens']) ??
          input + output + cacheRead + cacheWrite,
      cacheReadTokens: cacheRead,
      cacheCreationTokens: cacheWrite,
      contextWindowTokens:
          _intFromControlJson(json['context_window_tokens']) ?? 0,
      ttftMs: _intFromControlJson(json['ttft_ms']),
      decodeThroughput: _doubleFromControlJson(json['decode_throughput']),
    );
  }

  final int inputTokens;
  final int outputTokens;
  final int contextTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final int contextWindowTokens;
  final int? ttftMs;
  final double? decodeThroughput;

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

/// V094-26：权限展示目录条目（Relay 白名单投影，additive）。
/// 只承载 id/name/description；name/description 允许为空（UI 显示「说明未提供」），
/// 不得据此推断安全语义，风险确认仍按能力门与既有勾选确认执行。
class SessionPermissionModeDetail {
  const SessionPermissionModeDetail({
    required this.id,
    this.name = '',
    this.description = '',
  });

  factory SessionPermissionModeDetail.fromRelayJson(Map<String, dynamic> json) {
    // 长度上限与 Relay 侧投影一致（128/512 rune），防御异常数据撑爆 UI。
    String capped(Object? value, int limit) {
      if (value is! String) return '';
      final trimmed = value.trim();
      final runes = trimmed.runes.toList(growable: false);
      if (runes.length <= limit) return trimmed;
      return String.fromCharCodes(runes.take(limit));
    }

    return SessionPermissionModeDetail(
      id: capped(json['id'], 128),
      name: capped(json['name'], 128),
      description: capped(json['description'], 512),
    );
  }

  final String id;
  final String name;

  /// 缺失时 UI 必须显示「说明未提供」，不能用 ID 猜测权限含义。
  final String description;
}

/// 会话控制面由已解密事件或 fixture 填充；空状态明确说明尚未获得该类事件。
class SessionControlState {
  const SessionControlState({
    required this.model,
    required this.effort,
    this.defaultModel,
    this.plan,
    this.goal,
    this.todos = const [],
    this.skills = const [],
    // v0.2/P3：模型/effort 目录与 usage 只来自已解密事件或 deterministic fixture。
    this.models = const [],
    this.efforts = const [],
    this.modelGroups = const [],
    this.imageLimits,
    this.usage,
    // v0.3/P0：permission mode 选择器（Happy sessionSetAgentModes 对齐）。
    this.permissionMode,
    this.availablePermissionModes = const [],
    // V094-26：可选权限展示目录（id/name/description 白名单投影）。
    this.availablePermissionModeDetails = const [],
  });

  const SessionControlState.empty()
    : model = null,
      effort = null,
      defaultModel = null,
      plan = null,
      goal = null,
      todos = const [],
      skills = const [],
      models = const [],
      efforts = const [],
      modelGroups = const [],
      imageLimits = null,
      usage = null,
      permissionMode = null,
      availablePermissionModes = const [],
      availablePermissionModeDetails = const [];

  factory SessionControlState.fromRelayJson(Map<String, dynamic> json) {
    final rawUsage = json['usage'];
    return SessionControlState(
      model: _nullableControlString(json['model']),
      defaultModel: _nullableControlString(json['default_model']),
      effort: _nullableControlString(json['effort']),
      models: _stringListFromControlJson(json['models']),
      efforts: _stringListFromControlJson(json['efforts']),
      modelGroups: _modelGroupsFromControlJson(json['model_groups']),
      usage: rawUsage is Map
          ? SessionUsageSummary.fromRelayJson(
              Map<String, dynamic>.from(rawUsage),
            )
          : null,
      permissionMode: _nullableControlString(json['permission_mode']),
      availablePermissionModes: _stringListFromControlJson(
        json['available_permission_modes'],
      ),
      // V094-26：展示目录是可选 additive 字段；旧 Relay 缺失时保持空列表，
      // UI 回退为原 ID 展示 + 「说明未提供」，不臆测跨 Provider 权限语义。
      availablePermissionModeDetails: _permissionModeDetailsFromControlJson(
        json['available_permission_mode_details'],
      ),
    );
  }

  final String? model;
  final String? effort;

  /// Relay/Host 明确声明的默认模型；缺失时保持 null，不做名称猜测。
  final String? defaultModel;
  final SessionPlanSummary? plan;
  final SessionGoalSummary? goal;
  final List<SessionTodoItem> todos;
  final List<SessionSkillDescriptor> skills;
  final List<String> models;
  final List<String> efforts;
  final List<CapabilityModelGroup> modelGroups;
  final SessionImageLimits? imageLimits;
  final SessionUsageSummary? usage;
  final String? permissionMode;
  final List<String> availablePermissionModes;

  /// V094-26：权限展示目录（id/name/description 白名单）。
  /// name/description 允许为空；UI 按「缺说明回退原 ID」渲染。
  final List<SessionPermissionModeDetail> availablePermissionModeDetails;

  SessionControlState copyWith({
    String? model,
    String? effort,
    String? defaultModel,
    SessionPlanSummary? plan,
    SessionGoalSummary? goal,
    bool clearGoal = false,
    List<SessionTodoItem>? todos,
    List<SessionSkillDescriptor>? skills,
    List<String>? models,
    List<String>? efforts,
    List<CapabilityModelGroup>? modelGroups,
    SessionImageLimits? imageLimits,
    SessionUsageSummary? usage,
    String? permissionMode,
    List<String>? availablePermissionModes,
    List<SessionPermissionModeDetail>? availablePermissionModeDetails,
  }) => SessionControlState(
    model: model ?? this.model,
    effort: effort ?? this.effort,
    defaultModel: defaultModel ?? this.defaultModel,
    plan: plan ?? this.plan,
    goal: clearGoal ? null : goal ?? this.goal,
    todos: todos ?? this.todos,
    skills: skills ?? this.skills,
    models: models ?? this.models,
    efforts: efforts ?? this.efforts,
    modelGroups: modelGroups ?? this.modelGroups,
    imageLimits: imageLimits ?? this.imageLimits,
    usage: usage ?? this.usage,
    permissionMode: permissionMode ?? this.permissionMode,
    availablePermissionModes:
        availablePermissionModes ?? this.availablePermissionModes,
    availablePermissionModeDetails:
        availablePermissionModeDetails ?? this.availablePermissionModeDetails,
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
    // v0.8.5 §3.1：附件明文 SHA-256（密封前登记）。Daemon 解密后复算对照；
    // fixture 或旧草稿缺省为 null（发送时该 ref 不带 sha256，daemon 侧不校验）。
    this.plaintextSHA256Hex,
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
  final String? plaintextSHA256Hex;

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

String? _nullableControlString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

int? _intFromControlJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

double? _doubleFromControlJson(Object? value) {
  if (value is num) return value.toDouble();
  return null;
}

List<String> _stringListFromControlJson(Object? value) => value is List
    ? value
          .whereType<String>()
          .where((item) => item.trim().isNotEmpty)
          .map((item) => item.trim())
          .toList(growable: false)
    : const [];

/// V094-26：权限展示目录解析。只接受 id/name/description 白名单字段；
/// id 为空的条目丢弃，长度对齐 Relay 侧上限（防御性再截断，不信任上游）。
List<SessionPermissionModeDetail> _permissionModeDetailsFromControlJson(
  Object? value,
) => value is List
    ? value
          .whereType<Map>()
          .map(
            (item) => SessionPermissionModeDetail.fromRelayJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .where((detail) => detail.id.isNotEmpty)
          .toList(growable: false)
    : const [];

List<CapabilityModelGroup> _modelGroupsFromControlJson(Object? value) =>
    value is List
    ? value
          .whereType<Map>()
          .map(
            (item) => CapabilityModelGroup.fromRelayJson(
              Map<String, dynamic>.from(item),
            ),
          )
          .where((group) => group.id.isNotEmpty && group.models.isNotEmpty)
          .toList(growable: false)
    : const [];
