import 'package:agent_sessions_mobile/domain/terminal_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

void main() {
  final now = DateTime.utc(2026, 8, 16, 12);

  group('MOBILE-16 设置中心控制器', () {
    test('初始 loading，refresh 后 ready，设备/能力/终端均有值', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      await bootstrapFixtureOwner(relay);
      relay.replaceTerminals([
        _terminal(id: 'term_online', hostname: 'Build Mac', lastSeen: now),
        _terminal(
          id: 'term_stale',
          hostname: 'Stale Mac',
          lastSeen: now.subtract(const Duration(minutes: 3)),
        ),
      ]);
      final controller = SettingsController(relay: relay, clock: () => now);

      // 尚未读取时处于 loading，列表为空
      expect(controller.phase, SettingsSectionPhase.loading);
      expect(controller.devices, isEmpty);
      expect(controller.terminals, isEmpty);

      await controller.initialize();

      expect(controller.phase, SettingsSectionPhase.ready);
      expect(controller.devices, hasLength(1));
      expect(controller.devices.single.isOwner, isTrue);
      expect(controller.capabilities.providers, hasLength(4));
      expect(controller.terminals, hasLength(2));
      expect(controller.isRefreshing, isFalse);
      expect(controller.errorMessage, isNull);
    });

    test('usageUnavailable 恒为 true（ADR-010 未落地前不展示伪造统计）', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      await bootstrapFixtureOwner(relay);
      final controller = SettingsController(relay: relay, clock: () => now);

      // 初始即不可用，读取成功后也不会打开
      expect(controller.usageUnavailable, isTrue);
      await controller.initialize();
      expect(controller.phase, SettingsSectionPhase.ready);
      expect(controller.usageUnavailable, isTrue);
    });

    test('空列表时进入 ready 且 hasOwner 为 false', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = SettingsController(relay: relay, clock: () => now);

      await controller.initialize();

      expect(controller.phase, SettingsSectionPhase.ready);
      expect(controller.devices, isEmpty);
      expect(controller.terminals, isEmpty);
      expect(controller.hasOwner, isFalse);
      expect(controller.errorMessage, isNull);
    });

    test('Relay 失败时保留旧数据；无数据时 error 且可重试恢复', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      await bootstrapFixtureOwner(relay);
      relay.replaceTerminals([
        _terminal(
          id: 'term_retained',
          hostname: 'Retained Terminal',
          lastSeen: now,
        ),
      ]);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();
      expect(controller.phase, SettingsSectionPhase.ready);

      // 已有数据时刷新失败保留最后一份可信状态
      relay.setNetworkAvailable(false);
      await controller.refresh();
      expect(controller.phase, SettingsSectionPhase.ready);
      expect(controller.devices.single.id, 'android-owner-fixture');
      expect(controller.terminals.single.hostname, 'Retained Terminal');
      expect(controller.errorMessage, contains('不可用'));

      // 无数据时首屏失败进入 error
      final unavailableRelay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final firstLoad = SettingsController(
        relay: unavailableRelay,
        clock: () => now,
      );
      await firstLoad.initialize();
      expect(firstLoad.phase, SettingsSectionPhase.error);
      expect(firstLoad.devices, isEmpty);
      expect(firstLoad.terminals, isEmpty);
      expect(firstLoad.errorMessage, contains('不可用'));

      // 恢复网络后重试成功
      unavailableRelay.setNetworkAvailable(true);
      await firstLoad.refresh();
      expect(firstLoad.phase, SettingsSectionPhase.ready);
      expect(firstLoad.errorMessage, isNull);
    });

    test('availabilityFor 复用终端白名单推导 online/stale', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceTerminals([
        _terminal(
          id: 'term_online',
          hostname: 'Online Mac',
          lastSeen: now.subtract(const Duration(seconds: 20)),
        ),
        _terminal(
          id: 'term_stale',
          hostname: 'Stale Mac',
          lastSeen: now.subtract(const Duration(minutes: 3)),
        ),
        _terminal(
          id: 'term_offline',
          hostname: 'Offline Linux',
          status: TerminalConnectionStatus.offline,
          lastSeen: now.subtract(const Duration(minutes: 5)),
        ),
      ]);
      final controller = SettingsController(relay: relay, clock: () => now);
      await controller.initialize();

      expect(
        controller.availabilityFor(controller.terminals[0]),
        TerminalAvailability.online,
      );
      expect(
        controller.availabilityFor(controller.terminals[1]),
        TerminalAvailability.stale,
      );
      expect(
        controller.availabilityFor(controller.terminals[2]),
        TerminalAvailability.offline,
      );
    });
  });
}

TerminalSummary _terminal({
  required String id,
  required String hostname,
  TerminalConnectionStatus status = TerminalConnectionStatus.online,
  required DateTime lastSeen,
}) => TerminalSummary(
  id: id,
  hostname: hostname,
  platform: 'macos',
  status: status,
  protocolVersion: 1,
  daemonVersion: '0.4.0',
  lastSeen: lastSeen,
);
