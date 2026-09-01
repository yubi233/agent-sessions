import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V081-01 MobileWorkspace 安全投影', () {
    test('DSH workspace 使用 Relay display_name 而不是 opaque project_id', () {
      final workspace = MobileWorkspace.fromRelayJson(const {
        'id': 'ws_opaque',
        'project_id': 'proj_opaque',
        'terminal_id': 'term_opaque',
        'origin': 'dsh',
        'display_name': 'agent-sessions',
      });

      expect(workspace.origin, MobileWorkspaceOrigin.dsh);
      expect(workspace.isDsh, isTrue);
      expect(workspace.label, 'agent-sessions');
    });

    test('未知 origin 和缺失显示名保守降级为 managed', () {
      final workspace = MobileWorkspace.fromRelayJson(const {
        'id': 'ws_opaque',
        'project_id': 'proj_opaque',
        'terminal_id': 'term_opaque',
        'origin': 'future-provider',
        'display_name': '/private/path/must-not-be-trusted',
      });

      expect(workspace.origin, MobileWorkspaceOrigin.managed);
      expect(workspace.isDsh, isFalse);
      expect(workspace.label, 'proj_opaque');
    });
  });
}
