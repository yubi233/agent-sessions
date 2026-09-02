import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.8.3 P4 能力门控回归（V083-24 客户端侧）：
/// 真实 DSH 能力矩阵在 P4 阶段对 question/plan/goal/skill_catalog/invoke_skill/
/// permission_mode/attachments/fork 仍为 unsupported（等 P5 deterministic overlay
/// 全链路升格）。客户端必须按矩阵三态消费：unsupported 能力一律不渲染写入口，
/// reason 原样可用于「为什么不可用」展示，不得凭 UI 存在猜测能力。
void main() {
  // 与 internal/adapter/dsh successMatrix（P3 后）同构的矩阵片段：
  // 桥已实现面（mode/fork/attachments）在链路收口前保持 unsupported，
  // reason 必须是「桥已实现 + 链路待接入」新口径。
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
              dshCapability('permission_mode', 'unsupported',
                  '桥已实现 session/set_mode；Go adapter/Relay/移动端链路接入后升格'),
              dshCapability('question', 'unsupported', '桥未实现提问通道（无 question 相关 wire 方法）'),
              dshCapability('plan', 'unsupported', '桥不广播 plan 变体，未接入计划能力'),
              dshCapability('goal', 'unsupported', '桥不广播 goal 事件'),
              dshCapability('skill_catalog', 'unsupported', '桥未实现技能目录通道'),
              dshCapability('invoke_skill', 'unsupported', '桥未实现技能调用方法'),
              dshCapability('attachments', 'unsupported',
                  '桥已实现图像 admission 且按 deployment 条件开启；Go opaque ref 链路接入后升格'),
              dshCapability('fork', 'unsupported', '桥已实现 session/fork；Go adapter/Relay 链路接入后升格'),
            ],
          },
        ],
      });

  test('V083-24：unsupported 能力不渲染写入口（门控真值）', () {
    final matrix = dshMatrix();
    final dsh = matrix.provider('dsh');
    for (final name in [
      'permission_mode',
      'question',
      'plan',
      'goal',
      'skill_catalog',
      'invoke_skill',
      'attachments',
      'fork',
    ]) {
      final capability = dsh.capability(name);
      expect(capability.availability, CapabilityAvailability.unsupported,
          reason: '$name 在 P4 阶段必须保持 unsupported');
      // 客户端写入口只对 native/emulated 开放：unsupported 意味着 composer 附件、
      // mode 选择器、question 面板、skill 目录等入口全部不渲染。
      expect(capability.isSupported, isFalse, reason: '$name 不得出现写入口');
    }
  });

  test('V083-24：桥已实现面的 reason 是链路待接入新口径（不残留失效文案）', () {
    final dsh = dshMatrix().provider('dsh');
    // 旧口径（桥配置固定 / 未实现 / 仅接受 text 块）在 P1 后已失效；
    // 客户端展示的「为什么不可用」必须如实反映桥新事实。
    expect(dsh.capability('permission_mode').reason, contains('桥已实现'));
    expect(dsh.capability('attachments').reason, contains('桥已实现'));
    expect(dsh.capability('fork').reason, contains('桥已实现'));
    expect(dsh.capability('permission_mode').reason, isNot(contains('桥配置固定')));
    expect(dsh.capability('attachments').reason, isNot(contains('仅接受 text 块')));
  });

  test('V083-24：native/emulated 能力仍开放入口（矩阵消费不被误伤）', () {
    final dsh = dshMatrix().provider('dsh');
    expect(dsh.capability('start').isSupported, isTrue);
    expect(dsh.capability('model_select').isSupported, isTrue);
    expect(dsh.capability('permission').isSupported, isTrue,
        reason: 'emulated 权限决策通道保持可用（一次性审批）');
  });
}
