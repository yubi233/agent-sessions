import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.8.3 P5 能力矩阵消费回归（V083-22/24 客户端侧）：
/// deterministic overlay（dsh-v083-overlay.mjs 15/15）通过后，permission_mode/fork
/// 升为 native，question/plan/goal/skill_catalog/invoke_skill 以 dsh/* extension
/// 承载升为 emulated；attachments 的 Relay opaque ref 未接通保持 unsupported。
/// 客户端按矩阵三态消费：入口可用性与「为什么不可用」的 reason 都必须与矩阵一致。
void main() {
  // 与 internal/adapter/dsh successMatrix（P5 口径）同构的矩阵片段。
  Map<String, dynamic> dshCapability(String name, String status, String reason) => {
        'name': name,
        'status': status,
        if (reason.isNotEmpty) 'reason': reason,
      };

  CapabilityMatrix dshMatrix() => CapabilityMatrix.fromRelayJson({
        'providers': [
          {
            'kind': 'dsh',
            'version': '0.0.1',
            'available': true,
            'capabilities': [
              dshCapability('start', 'native', ''),
              dshCapability('resume', 'native', ''),
              dshCapability('abort', 'native', ''),
              dshCapability('kill', 'native', 'per-session 子进程进程组所有权'),
              dshCapability('model_select', 'native', ''),
              dshCapability('usage', 'native', ''),
              dshCapability('permission', 'emulated', '决策通道已接通但当前策略为取消而非静默批准'),
              dshCapability('permission_mode', 'native',
                  '全链路成立且 deterministic overlay 通过；session 级 mode 目录经 session 响应下发'),
              dshCapability('question', 'emulated', 'dsh/question 链路已接通；真实模型 turn 复验待授权（V083-26）'),
              dshCapability('plan', 'emulated', 'dsh/plan 链路已接通；真实模型 turn 复验待授权（V083-26）'),
              dshCapability('goal', 'emulated', 'dsh/goal 链路已接通；空 projection 经 overlay 验证，mutate 复验待授权（V083-26）'),
              dshCapability('skill_catalog', 'emulated', 'dsh/skill 链路已接通（descriptor 白名单 + 摘要 revision）；部署目录复验待授权'),
              dshCapability('invoke_skill', 'emulated', 'skill invoke admission 已接通（复用 prompt/cancel 生命周期）；真实执行复验待授权'),
              dshCapability('attachments', 'unsupported',
                  '桥 admission 与 SendContent 通道就绪；Relay opaque attachment ref 接入后按 deployment 条件升格'),
              dshCapability('fork', 'native',
                  '全链路成立且 deterministic overlay 通过（committed-prefix + 子会话绑定）'),
            ],
          },
        ],
      });

  test('V083-22：P5 gate 通过后 permission_mode/fork 为 native 且入口放行', () {
    final dsh = dshMatrix().provider('dsh');
    for (final name in ['permission_mode', 'fork']) {
      final capability = dsh.capability(name);
      expect(capability.availability, CapabilityAvailability.native,
          reason: '$name 全链路成立后应为 native');
      expect(capability.isSupported, isTrue, reason: '$name 入口放行');
      expect(capability.reason, contains('deterministic overlay'),
          reason: '$name reason 必须引用 gate 证据');
    }
  });

  test('V083-22：dsh/* extension 承载能力最高 emulated（不冒充 native）', () {
    final dsh = dshMatrix().provider('dsh');
    for (final name in ['question', 'plan', 'goal', 'skill_catalog', 'invoke_skill']) {
      final capability = dsh.capability(name);
      expect(capability.availability, CapabilityAvailability.emulated,
          reason: '$name 以 extension 承载上限 emulated');
      expect(capability.isSupported, isTrue, reason: '$name 入口按 emulated 放行');
      expect(capability.reason, contains('复验待授权'),
          reason: '$name reason 必须保留残余风险（V083-26）');
    }
  });

  test('V083-22：attachments 在 opaque ref 接入前保持 unsupported（不渲染入口）', () {
    final capability = dshMatrix().provider('dsh').capability('attachments');
    expect(capability.availability, CapabilityAvailability.unsupported);
    expect(capability.isSupported, isFalse, reason: 'attachments 不得出现写入口');
    expect(capability.reason, contains('opaque attachment ref'));
    expect(capability.reason, isNot(contains('仅接受 text 块')),
        reason: '失效旧口径不得残留');
  });

  test('V083-24：观察类能力不得因投影升格（delegation 保持 unsupported）', () {
    final matrix = CapabilityMatrix.fromRelayJson({
      'providers': [
        {
          'kind': 'dsh',
          'version': '0.0.1',
          'available': true,
          'capabilities': [
            dshCapability('delegate_session', 'unsupported', '桥未实现会话委托'),
            dshCapability('delegate_cross_provider', 'unsupported', '桥未实现跨 Provider 委托'),
          ],
        },
      ],
    });
    final dsh = matrix.provider('dsh');
    expect(dsh.capability('delegate_session').isSupported, isFalse);
    expect(dsh.capability('delegate_cross_provider').isSupported, isFalse);
  });
}
