import 'dart:math';

import 'package:agent_sessions_mobile/attachments/attachment_picker.dart';
import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// v0.8.8 能力矩阵收口回归（V088-06 / 迭代计划 §5）：
/// attachments 生产接线完成后矩阵按证据升格——本文件以「注入升格后矩阵」的
/// 方式锁定移动端消费语义：
///   1. 升格矩阵下 attachments 入口放行（controlBlockedReason 解除）；
///   2. 会话内容密钥缺失时入口维持 fail-closed（「等待会话附件密钥」）；
///   3. 升格前矩阵（unsupported，现行生产口径）入口仍阻断，reason 保留旧锚点；
///   4. 升格 reason 必须引用端到端证据（V088-09），旧口径不得残留。
/// 注意：真实矩阵升格发生在 P4（端到端证据入档后，§6.1 门禁 1），
/// 本文件不依赖真实 daemon 矩阵，全部通过注入验证客户端消费面。
/// 注入矩阵与内容密钥可用性的 fixture relay 子类（V088 客户端消费面）。
class _UpgradedCapabilityRelay extends FixtureRelayRepository {
  _UpgradedCapabilityRelay({required super.clock, required this.matrix});

  final CapabilityMatrix matrix;

  @override
  Future<CapabilityMatrix> getCapabilities() async => matrix;
}

void main() {
  final now = DateTime(2026, 9, 5, 12, 0, 0);

  CapabilityEntry entry(String name, String status, String reason) =>
      CapabilityEntry(
        name: name,
        availability: switch (status) {
          'native' => CapabilityAvailability.native,
          'emulated' => CapabilityAvailability.emulated,
          _ => CapabilityAvailability.unsupported,
        },
        reason: reason,
      );

  /// 升格后的矩阵片段（reason 措辞 = 迭代计划 §9.3 冻结模板）。
  /// controller 测试用 codex 会话（dsh 会话需 DSH 工作区归属），attachments
  /// 门控消费面与 provider 无关，因此 codex 档携带同一升格形状。
  CapabilityMatrix upgradedMatrix() => CapabilityMatrix(
        providers: [
          ProviderCapabilityProfile(
            kind: 'codex',
            version: '0.0.1',
            available: true,
            capabilities: [
              entry('start', 'native', ''),
              entry('attachments', 'emulated',
                  'opaque attachment ref 全链路成立（daemon 拉取出口 + 本机 DEK Open 契约 v0.8.8 §9.1 + 真实桥回合 V088-09 证据）；明文只经内存，Keystore 实机 gate 承接 V085'),
            ],
          ),
        ],
      );

  /// 升格前的 dsh 矩阵片段（现行生产口径：unsupported + 旧 reason）。
  CapabilityMatrix legacyMatrix() => CapabilityMatrix(
        providers: [
          ProviderCapabilityProfile(
            kind: 'codex',
            version: '0.0.1',
            available: true,
            capabilities: [
              entry('start', 'native', ''),
              entry('attachments', 'unsupported',
                  '桥 admission 与 SendContent 通道就绪；Relay opaque attachment ref 接入后按 deployment 条件升格'),
            ],
          ),
        ],
      );

  /// 构造「选中 dsh 会话 + 可写 + lease」的控制器（附件入口门控消费面）。
  Future<SessionController> prepareSession(
    _UpgradedCapabilityRelay relay,
  ) async {
    final owner = await bootstrapFixtureOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => now,
      random: _DeterministicRandom(),
      picker: const FixtureAttachmentPicker(),
    );
    await controller.initialize();
    final created = await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(created, isNotNull);
    await controller.acquireSelectedLease(
      deviceId: owner.deviceId,
      canWrite: true,
    );
    return controller;
  }

  test('V088-06a：升格矩阵下 attachments 入口放行（矩阵门控解除）', () async {
    final relay = _UpgradedCapabilityRelay(clock: () => now, matrix: upgradedMatrix());
    final controller = await prepareSession(relay);

    // 矩阵门控解除：capability 已支持、controlBlockedReason 不再阻断。
    final capability = controller.selectedProviderCapabilities
        .capability('attachments');
    expect(capability.isSupported, isTrue, reason: '升格后入口按矩阵放行');
    expect(
      controller.controlBlockedReason('attachments', canWrite: true),
      isNull,
      reason: '矩阵门控解除后 attachments 无能力级阻断',
    );
    // 全入口链路放行：密钥可用 + 图片限制投影 + 选择器在位 → 无任何阻断。
    expect(
      controller.attachmentPickBlockedReason(canWrite: true),
      isNull,
      reason: 'DEK 可用 + fixture 图片限制 + 注入选择器时入口完全可用',
    );
  });

  test('V088-06b：会话内容密钥缺失时入口维持 fail-closed（不因矩阵升格伪造可用）', () async {
    final relay = _UpgradedCapabilityRelay(clock: () => now, matrix: upgradedMatrix())
      ..contentKeysReady = false;
    final controller = await prepareSession(relay);

    final blocked = controller.attachmentPickBlockedReason(canWrite: true);
    expect(blocked, '等待会话附件密钥', reason: '无 DEK 会话禁选语义必须保持');
  });

  test('V088-06c：升格前矩阵（unsupported）入口仍阻断且 reason 保留旧锚点', () async {
    final relay = _UpgradedCapabilityRelay(clock: () => now, matrix: legacyMatrix());
    final controller = await prepareSession(relay);

    final capability = controller.selectedProviderCapabilities
        .capability('attachments');
    expect(capability.isSupported, isFalse);
    final blocked = controller.controlBlockedReason('attachments', canWrite: true);
    expect(blocked, isNotNull);
    expect(blocked, contains('opaque attachment ref'), reason: '旧口径 reason 是升格前的事实描述');
  });

  test('V088-06d：升格 reason 引用端到端证据（V088-09），旧口径不得残留', () {
    final reason = upgradedMatrix().provider('codex').capability('attachments').reason;
    expect(reason, contains('V088-09'), reason: 'reason 必须引用可复查证据（§6.1 门禁 1）');
    for (final stale in const ['未接通', '按 -32601 拒绝', '未实现']) {
      expect(reason, isNot(contains(stale)), reason: '升格后失效旧口径 $stale 不得残留');
    }
  });
}

/// 确定性随机源（与本目录既有 controller 测试同口径）。
class _DeterministicRandom implements Random {
  var _state = 7;
  @override
  bool nextBool() => _state.isEven;
  @override
  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return max == 0 ? 0 : _state % max;
  }
  @override
  double nextDouble() => nextInt(0x7fffffff) / 0x7fffffff;
}
