import 'dart:math';

import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

void main() {
  group('MOBILE-03 MODE-01..03 capability 控制状态机', () {
    test('V07-02：模型目录与默认值只接受 Host 明确声明的安全选项', () {
      final parsed = CapabilityMatrix.fromRelayJson({
        'providers': [
          {
            'kind': 'opencode',
            'version': '1.17.13',
            'available': true,
            'capabilities': [
              {
                'name': 'model_select',
                'status': 'native',
                'options': ['opencode/big-pickle', 'opencode/mimo-v2.5-free'],
                'default': 'opencode/big-pickle',
                'model_details': {
                  'opencode/big-pickle': {
                    'context_window_tokens': 200000,
                    'reasoning': true,
                    'efforts': [],
                  },
                },
              },
            ],
          },
        ],
      });
      final capability = parsed.provider('opencode').capability('model_select');
      expect(capability.options, [
        'opencode/big-pickle',
        'opencode/mimo-v2.5-free',
      ]);
      expect(capability.defaultOption, 'opencode/big-pickle');
      expect(
        parsed.provider('opencode').defaultOptionFor('model_select'),
        'opencode/big-pickle',
      );
      final detail = parsed
          .provider('opencode')
          .modelDetailFor('model_select', 'opencode/big-pickle');
      expect(detail?.contextWindowTokens, 200000);
      expect(detail?.reasoning, isTrue);
      expect(detail?.efforts, isEmpty);

      final invalidDefault = CapabilityMatrix.fromRelayJson({
        'providers': [
          {
            'kind': 'opencode',
            'version': '1.17.13',
            'available': true,
            'capabilities': [
              {
                'name': 'model_select',
                'status': 'native',
                'options': ['opencode/big-pickle'],
                'default': 'paid/provider-model',
              },
            ],
          },
        ],
      });
      expect(
        invalidDefault
            .provider('opencode')
            .capability('model_select')
            .defaultOption,
        isNull,
      );
    });

    test('model_groups 解析渠道父级、推理档位与上下文窗口', () {
      final parsed = CapabilityMatrix.fromRelayJson({
        'providers': [
          {
            'kind': 'dsh',
            'version': '0.1.0',
            'available': true,
            'capabilities': [
              {
                'name': 'model_select',
                'status': 'native',
                'options': [
                  'dsh:model:channel-a:shared',
                  'dsh:model:channel-b:shared',
                ],
                'default': 'dsh:model:channel-b:shared',
                // 真实 adapter 同时填充 model_details（键=opaque value）。
                'model_details': {
                  'dsh:model:channel-b:shared': {
                    'context_window_tokens': 320000,
                    'reasoning': true,
                    'efforts': ['low', 'high'],
                  },
                },
                'model_groups': [
                  {
                    'id': 'channel-a',
                    'name': 'Channel A',
                    'models': [
                      {
                        'provider': 'channel-a',
                        'value': 'dsh:model:channel-a:shared',
                        'id': 'shared',
                        'name': 'Shared Alpha',
                        'context_window_tokens': 128000,
                        'reasoning': false,
                        'efforts': [],
                      },
                    ],
                  },
                  {
                    'id': 'channel-b',
                    'name': 'Channel B',
                    'models': [
                      {
                        'provider': 'channel-b',
                        'value': 'dsh:model:channel-b:shared',
                        'id': 'shared',
                        'name': 'Shared Beta',
                        'context_window_tokens': 320000,
                        'reasoning': true,
                        'efforts': ['low', 'high'],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      });
      final capability = parsed.provider('dsh').capability('model_select');
      // 同名模型被保留在各自渠道父级下，不塌缩。
      expect(capability.modelGroups, hasLength(2));
      expect(capability.modelGroups[0].id, 'channel-a');
      expect(capability.modelGroups[0].name, 'Channel A');
      expect(capability.modelGroups[0].models, hasLength(1));
      final alpha = capability.modelGroups[0].models.single;
      expect(alpha.provider, 'channel-a');
      expect(alpha.id, 'shared');
      expect(alpha.name, 'Shared Alpha');
      expect(alpha.contextWindowTokens, 128000);
      expect(alpha.reasoning, isFalse);
      expect(alpha.efforts, isEmpty);
      final beta = capability.modelGroups[1].models.single;
      expect(beta.provider, 'channel-b');
      expect(beta.value, 'dsh:model:channel-b:shared');
      expect(beta.contextWindowTokens, 320000);
      expect(beta.reasoning, isTrue);
      expect(beta.efforts, ['low', 'high']);
      // 目录 options 仍以 Host 声明的无歧义 value 呈现。
      expect(capability.options, [
        'dsh:model:channel-a:shared',
        'dsh:model:channel-b:shared',
      ]);
      expect(capability.defaultOption, 'dsh:model:channel-b:shared');
      // model_details 目录也保留该 opaque value 键（供详情查询）。
      final detail = parsed
          .provider('dsh')
          .modelDetailFor('model_select', 'dsh:model:channel-b:shared');
      expect(detail?.contextWindowTokens, 320000);
      expect(detail?.reasoning, isTrue);
      expect(detail?.efforts, ['low', 'high']);
    });

    test('model_groups 缺失或格式错误时安全降级为空目录', () {
      final parsed = CapabilityMatrix.fromRelayJson({
        'providers': [
          {
            'kind': 'dsh',
            'version': '0.1.0',
            'available': true,
            'capabilities': [
              {
                'name': 'model_select',
                'status': 'native',
                'options': ['dsh:model:channel-a:shared'],
                'default': 'dsh:model:channel-a:shared',
              },
            ],
          },
        ],
      });
      final capability = parsed.provider('dsh').capability('model_select');
      expect(capability.modelGroups, isEmpty);
      // 空组/无 provider 组会被过滤，非法项不进入目录。
      final filtered = CapabilityMatrix.fromRelayJson({
        'providers': [
          {
            'kind': 'dsh',
            'version': '0.1.0',
            'available': true,
            'capabilities': [
              {
                'name': 'model_select',
                'status': 'native',
                'options': ['valid'],
                'model_groups': [
                  {'id': '', 'name': 'Empty', 'models': []},
                  {
                    'id': 'missing-provider',
                    'name': 'Broken',
                    'models': [
                      {
                        'value': 'v-no-provider',
                        'id': 'x',
                        'name': 'No Provider',
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      });
      final filteredCapability = filtered
          .provider('dsh')
          .capability('model_select');
      expect(filteredCapability.modelGroups, isEmpty);
    });

    test('未知 capability 状态和能力读取失败均 fail-closed', () async {
      final parsed = CapabilityMatrix.fromRelayJson({
        'providers': [
          {
            'kind': 'future-provider',
            'version': 'fixture',
            'available': true,
            'capabilities': [
              {'name': 'plan', 'status': 'future-state'},
            ],
          },
        ],
      });
      final unknown = parsed.provider('future-provider').capability('plan');
      expect(unknown.availability, CapabilityAvailability.unsupported);
      expect(unknown.reason, 'Provider 返回了未知能力状态。');

      final relay = _UnavailableCapabilityFixture(clock: () => _now);
      await bootstrapFixtureOwner(relay);
      final controller = SessionController(relay: relay, clock: () => _now);
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

      expect(
        controller.controlBlockedReason('plan', canWrite: true),
        'Provider 当前不可用。',
      );
      expect(controller.capabilities.providers, isEmpty);
    });

    test('Plan、Goal 与高风险 Skill 共用 lease 和幂等命令链路，拒绝不提交命令', () async {
      final relay = FixtureRelayRepository(clock: () => _now);
      final controller = await _prepareWritableSession(relay);

      final highRisk = controller.controls.skills.singleWhere(
        (skill) => skill.risk == SkillRisk.high,
      );
      controller.requestSkillConfirmation(highRisk, canWrite: true);
      expect(controller.skillConfirmation?.skill.id, highRisk.id);
      expect(relay.submittedCommandCount, 0);

      controller.rejectSkillConfirmation();
      expect(controller.skillConfirmation, isNull);
      expect(relay.submittedCommandCount, 0);

      controller.requestSkillConfirmation(highRisk, canWrite: true);
      await controller.confirmSkill(deviceId: _ownerDeviceId, canWrite: true);
      expect(controller.skillConfirmation, isNull);
      expect(relay.submittedCommandCount, 1);

      await controller.approvePlan(deviceId: _ownerDeviceId, canWrite: true);
      expect(controller.controls.plan?.phase, PlanPhase.active);
      expect(relay.submittedCommandCount, 2);

      await controller.toggleGoal(deviceId: _ownerDeviceId, canWrite: true);
      expect(controller.controls.goal?.phase, GoalPhase.paused);
      expect(relay.submittedCommandCount, 3);
      expect(controller.errorMessage, isNull);
    });
  });
}

const _ownerDeviceId = 'android-owner-fixture';
final _now = DateTime.utc(2026, 8, 14, 10, 15);

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

/// 只替换 capability 读取，保留其余真实 fixture 行为，验证控制器失败时不会放行写入口。
class _UnavailableCapabilityFixture extends FixtureRelayRepository {
  _UnavailableCapabilityFixture({super.clock});

  @override
  Future<CapabilityMatrix> getCapabilities() async => throw const RelayFailure(
    RelayFailureKind.unavailable,
    '能力 fixture 暂时不可用。',
  );
}

/// 稳定随机数保证幂等键测试可重复；生产控制器默认使用 Random.secure。
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
