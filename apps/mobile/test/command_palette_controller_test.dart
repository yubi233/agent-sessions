import 'dart:math';

import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/command_palette_controller.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// MOBILE-22：命令面板只读索引状态机。
/// 覆盖导航命令完整登记、无选中会话门控、capability fail-closed、
/// 当前账号会话索引，以及 filter 的标题/副标题匹配。
void main() {
  final now = DateTime.utc(2026, 8, 16, 12);
  const ownerDeviceId = 'android-owner-fixture';

  Future<FixtureRelayRepository> fixtureWithSessions() async {
    final relay = FixtureRelayRepository(clock: () => now);
    await bootstrapFixtureOwner(relay);
    await relay.createSession(
      CreateMobileSessionInput(
        workspaceId: 'workspace-a',
        provider: 'codex',
        deviceId: ownerDeviceId,
      ),
    );
    await relay.createSession(
      CreateMobileSessionInput(
        workspaceId: 'workspace-b',
        provider: 'claude',
        deviceId: ownerDeviceId,
      ),
    );
    return relay;
  }

  Future<SessionController> sessionControllerWith(
    FixtureRelayRepository relay,
  ) async {
    final controller = SessionController(
      relay: relay,
      clock: () => now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    return controller;
  }

  group('MOBILE-22 命令面板控制器', () {
    test('导航类命令全部有 route 且 blockedReason=null', () async {
      final relay = await fixtureWithSessions();
      final sessions = await sessionControllerWith(relay);
      final palette = CommandPaletteController(sessionController: sessions);

      palette.filter('');

      final navigate = palette.results
          .where((command) => command.kind == PaletteCommandKind.navigate)
          .toList();
      expect(navigate, hasLength(6));
      for (final command in navigate) {
        expect(command.route, isNotNull, reason: command.title);
        expect(command.blockedReason, isNull, reason: command.title);
        expect(command.action, isNull);
      }
      // 只索引已注册路由，不含未实现的路径。
      expect(
        navigate.map((command) => command.route),
        containsAll([
          '/settings',
          '/terminals',
          '/sessions/recent',
          '/devices',
          '/pairing',
          '/sessions/new',
        ]),
      );
    });

    test('无选中会话时 resume/stop/openFiles/openGit 全部 blocked', () async {
      final relay = await fixtureWithSessions();
      final sessions = await sessionControllerWith(relay);
      expect(sessions.selectedSessionId, isNull);
      final palette = CommandPaletteController(sessionController: sessions);

      palette.filter('');

      final resume = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.resume,
      );
      final stop = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.stop,
      );
      final files = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.openFiles,
      );
      final git = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.openGit,
      );
      expect(resume.blockedReason, '当前没有选中会话。');
      expect(stop.blockedReason, '当前没有选中会话。');
      expect(files.blockedReason, '当前没有选中会话。');
      expect(git.blockedReason, '当前没有选中会话。');
    });

    test('Provider 未声明 abort/resume 时 capability fail-closed', () async {
      final relay = await fixtureWithSessions();
      final sessions = await sessionControllerWith(relay);
      // 选中 claude 会话：claude 未声明 resume/abort 能力。
      await sessions.selectSession('session-fixture-002');
      expect(sessions.selectedSession?.provider, 'claude');

      final palette = CommandPaletteController(sessionController: sessions);
      palette.filter('');

      final resume = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.resume,
      );
      final stop = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.stop,
      );
      expect(resume.blockedReason, contains('未声明'));
      // 未获取 lease 时 stop 先被租约门控阻断。
      expect(stop.blockedReason, '当前会话暂不可操作。');
      // 浏览/查看 Git 是只读索引，选中会话后不被 capability 阻断。
      final files = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.openFiles,
      );
      final git = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.openGit,
      );
      expect(files.blockedReason, isNull);
      expect(git.blockedReason, isNull);

      // 获取 lease 后 stop 仍然因 capability 缺失而阻断（fail-closed）。
      await sessions.acquireSelectedLease(
        deviceId: ownerDeviceId,
        canWrite: true,
      );
      expect(sessions.hasSelectedLease, isTrue);
      palette.filter('');
      final stopWithLease = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.stop,
      );
      expect(stopWithLease.blockedReason, contains('未声明'));

      // 有 lease + 能力时 stop 可执行；但 resume 走只读门控恒被阻断（见下方说明）。
      await sessions.selectSession('session-fixture-001');
      await sessions.acquireSelectedLease(
        deviceId: ownerDeviceId,
        canWrite: true,
      );
      palette.filter('');
      final codexStop = palette.results.firstWhere(
        (command) => command.action == PaletteControlAction.stop,
      );
      expect(codexStop.blockedReason, isNull);
    });

    test('会话列表索引当前账号可见会话', () async {
      final relay = await fixtureWithSessions();
      final sessions = await sessionControllerWith(relay);
      final palette = CommandPaletteController(sessionController: sessions);

      palette.filter('');

      final sessionCommands = palette.results
          .where((command) => command.kind == PaletteCommandKind.session)
          .toList();
      expect(sessionCommands, hasLength(2));
      final ids = sessionCommands.map((command) => command.sessionId).toSet();
      expect(ids, containsAll(['session-fixture-001', 'session-fixture-002']));
      for (final command in sessionCommands) {
        expect(command.route, isNull);
        expect(command.blockedReason, isNull);
        expect(command.title, isNotEmpty);
        expect(command.subtitle, contains('·'));
      }
      // 会话标题来自白名单展示名，副标题包含 Provider 与状态标签。
      expect(
        sessionCommands.map((command) => command.subtitle),
        containsAll(['codex · 空闲', 'claude · 空闲']),
      );
    });

    test('filter 按 title/subtitle 过滤，空查询显示全部', () async {
      final relay = await fixtureWithSessions();
      final sessions = await sessionControllerWith(relay);
      final palette = CommandPaletteController(sessionController: sessions);

      // 空查询：全部已登记命令（6 导航 + 4 控制 + 2 会话）。
      palette.filter('');
      expect(palette.query, '');
      expect(palette.results, hasLength(12));

      // 按 title 过滤。
      palette.filter('设置');
      expect(palette.results, hasLength(1));
      expect(palette.results.single.title, '设置');

      // 大小写不敏感。
      palette.filter('SETTINGS');
      expect(palette.results, hasLength(1));
      expect(palette.results.single.title, '设置');

      // 按 subtitle 过滤：codex 会话副标题命中会话索引。
      palette.filter('codex');
      final codex = palette.results;
      expect(codex, isNotEmpty);
      expect(
        codex.every(
          (command) =>
              command.subtitle.toLowerCase().contains('codex') ||
              command.title.toLowerCase().contains('codex'),
        ),
        isTrue,
      );

      // 查询首尾空白被裁剪。
      palette.filter('  恢复  ');
      expect(palette.query, '恢复');
      expect(
        palette.results.map((command) => command.title),
        contains('恢复当前会话'),
      );

      // 无匹配：结果为空。
      palette.filter('不存在的关键字');
      expect(palette.results, isEmpty);
    });
  });
}

/// 稳定随机数让幂等键的测试环境可重复，但产品默认使用 Random.secure。
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
