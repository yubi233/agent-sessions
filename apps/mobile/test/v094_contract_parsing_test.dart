import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// V094 P0 契约冻结（计划 §2.2/§2.5）：Relay snapshot 的可选 command_id 关联
/// 投影与 controls 的可选权限展示目录（available_permission_mode_details）。
///
/// 契约要点：
/// 1. 新字段全部 additive 可选；旧 Relay/旧事件缺失时解析不抛错、值为空；
/// 2. 关联 ID 只用于消息事务状态，不冒充 Provider messageId；
/// 3. 展示目录只含 id/name/description 白名单，缺说明回退原 ID。
void main() {
  group('V094-06：snapshot 事件 command_id 关联投影', () {
    test('携带 command_id 的事件解析出关联，供消息事务使用', () {
      final event = RelaySessionEvent.fromRelayJson({
        'event_seq': 7,
        'event_type': 'user.message',
        'created_at_unix_ms': 1789000000000,
        'command_id': 'cmd_v094_1',
        'envelope': {'fixture_payload': {'kind': 'user_message'}},
      });
      expect(event.commandId, 'cmd_v094_1');
      expect(event.sequence, 7);
    });

    test('旧事件缺失 command_id 时保持 null（状态未确认降级，不猜测）', () {
      final event = RelaySessionEvent.fromRelayJson({
        'event_seq': 8,
        'event_type': 'user.message',
        'envelope': {'fixture_payload': {'kind': 'user_message'}},
      });
      expect(event.commandId, isNull);
    });
  });

  group('V094-26：controls 权限展示目录白名单解析', () {
    test('目录条目解析 id/name/description，超长值按 Relay 上限截断', () {
      final state = SessionControlState.fromRelayJson({
        'permission_mode': 'default',
        'available_permission_modes': ['default', 'plan'],
        'available_permission_mode_details': [
          {
            'id': 'default',
            'name': '默认模式',
            'description': '标准权限',
            'risk_level': 'internal-only',
          },
          {'id': 'plan', 'name': '计划', 'description': '长' * 600},
        ],
      });
      expect(state.availablePermissionModes, ['default', 'plan']);
      expect(state.availablePermissionModeDetails, hasLength(2));
      expect(state.availablePermissionModeDetails[0].id, 'default');
      expect(state.availablePermissionModeDetails[0].name, '默认模式');
      expect(state.availablePermissionModeDetails[0].description, '标准权限');
      // 白名单外字段不进入 DTO。
      expect(
        state.availablePermissionModeDetails[0]
            .toJsonDebugWhitelistKeys()
            .toSet(),
        {'id', 'name', 'description'},
      );
      // 超长描述截断到 512 rune（与 Relay 投影上限一致，防御性再截断）。
      expect(
        state.availablePermissionModeDetails[1].description.runes.length,
        512,
      );
    });

    test('旧 Relay 缺失目录字段时回退空列表（不抛错、UI 回退原 ID）', () {
      final state = SessionControlState.fromRelayJson({
        'permission_mode': 'danger-full-access',
        'available_permission_modes': ['danger-full-access'],
      });
      expect(state.availablePermissionModeDetails, isEmpty);
      expect(state.availablePermissionModes, ['danger-full-access']);
    });

    test('id 为空的非法条目被丢弃', () {
      final state = SessionControlState.fromRelayJson({
        'available_permission_modes': ['default'],
        'available_permission_mode_details': [
          {'id': '', 'name': '非法'},
          {'id': 'default', 'name': '默认'},
        ],
      });
      expect(state.availablePermissionModeDetails, hasLength(1));
      expect(state.availablePermissionModeDetails.single.id, 'default');
    });
  });
}

extension on SessionPermissionModeDetail {
  /// 测试辅助：暴露 DTO 实际承载的字段集合，验证白名单。
  List<String> toJsonDebugWhitelistKeys() => [
    if (id.isNotEmpty) 'id',
    if (name.isNotEmpty) 'name',
    if (description.isNotEmpty) 'description',
  ];
}
