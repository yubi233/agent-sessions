import 'package:agent_sessions_mobile/domain/usage_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/usage_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// MOBILE-20：用量统计页只读状态机（ADR-010）。
/// 覆盖 loading→ready、空摘要降级、窗口切换、Relay 失败保留旧数据与重试、
/// 以及 todayProviders 的 UTC 今日过滤。
void main() {
  final now = DateTime.utc(2026, 8, 16, 12);

  UsageDayAggregate day({
    required String provider,
    required String utcDay,
    int input = 0,
    int output = 0,
  }) => UsageDayAggregate(
    provider: provider,
    utcDay: utcDay,
    inputTokens: input,
    outputTokens: output,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
  );

  UsageSummary summary({
    int days = 30,
    String utcToday = '2026-08-16',
    List<UsageDayAggregate>? providers,
  }) => UsageSummary(
    days: days,
    utcToday: utcToday,
    providers: providers ?? [],
  );

  group('MOBILE-20 用量控制器', () {
    test('loading→ready：预置摘要后 hasData=true 且 days 正确', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceUsageSummary(
        summary(
          providers: [
            day(
              provider: 'codex',
              utcDay: '2026-08-16',
              input: 1200,
              output: 800,
            ),
          ],
        ),
      );
      final controller = UsageController(relay: relay);

      // 尚未读取时处于 loading，无任何估算数据。
      expect(controller.phase, UsagePhase.loading);
      expect(controller.hasData, isFalse);
      expect(controller.todayProviders, isEmpty);

      await controller.initialize();

      expect(controller.phase, UsagePhase.ready);
      expect(controller.hasData, isTrue);
      expect(controller.days, 30);
      expect(controller.summary.days, 30);
      expect(controller.summary.totals, (1200, 800));
      expect(controller.errorMessage, isNull);
      expect(controller.isRefreshing, isFalse);
    });

    test('空摘要→unavailable 且 hasData=false（客户端不估算）', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      final controller = UsageController(relay: relay);

      await controller.initialize();

      expect(controller.phase, UsagePhase.unavailable);
      expect(controller.hasData, isFalse);
      expect(controller.summary.providers, isEmpty);
      expect(controller.summary, same(UsageSummary.empty));
      expect(controller.errorMessage, isNull);
    });

    test('切换窗口 refresh(7/30) 更新 days 与摘要', () async {
      // 用按窗口返回不同摘要的子类 fixture 模拟 7/30 天聚合差异。
      final relay = _WindowAwareRelay(clock: () => now)
        ..replaceUsageSummary(
          summary(
            days: 30,
            providers: [
              day(provider: 'codex', utcDay: '2026-08-16', input: 300),
            ],
          ),
        )
        ..replaceUsageSummary(
          summary(
            days: 7,
            utcToday: '2026-08-16',
            providers: [
              day(provider: 'claude', utcDay: '2026-08-16', input: 100),
            ],
          ),
        );
      final controller = UsageController(relay: relay);

      await controller.initialize();
      expect(controller.days, 30);
      expect(controller.summary.providers.single.provider, 'codex');

      await controller.refresh(7);
      expect(controller.days, 7);
      expect(controller.summary.days, 7);
      expect(controller.summary.providers.single.provider, 'claude');
      expect(controller.phase, UsagePhase.ready);

      await controller.refresh(30);
      expect(controller.days, 30);
      expect(controller.summary.days, 30);
      expect(controller.summary.providers.single.provider, 'codex');
    });

    test('RelayFailure 保留旧数据；无数据时 error 且网络恢复后可重试', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceUsageSummary(
        summary(
          providers: [
            day(provider: 'codex', utcDay: '2026-08-16', input: 500),
          ],
        ),
      );
      final controller = UsageController(relay: relay);
      await controller.initialize();
      expect(controller.phase, UsagePhase.ready);

      // 已有数据时刷新失败：保留最后一份可信摘要，不进入 error。
      relay.setNetworkAvailable(false);
      await controller.refresh(30);
      expect(controller.phase, UsagePhase.ready);
      expect(controller.summary.providers.single.provider, 'codex');
      expect(controller.hasData, isTrue);
      expect(controller.errorMessage, contains('不可用'));

      // 无数据时首屏失败进入 error，可重试。
      final unavailableRelay = FixtureRelayRepository(clock: () => now)
        ..setNetworkAvailable(false);
      final firstLoad = UsageController(relay: unavailableRelay);
      await firstLoad.initialize();
      expect(firstLoad.phase, UsagePhase.error);
      expect(firstLoad.hasData, isFalse);
      expect(firstLoad.summary.providers, isEmpty);
      expect(firstLoad.errorMessage, contains('不可用'));

      // 恢复网络并预置数据后重试成功进入 ready。
      unavailableRelay.setNetworkAvailable(true);
      unavailableRelay.replaceUsageSummary(
        summary(
          providers: [
            day(provider: 'opencode', utcDay: '2026-08-16', input: 88),
          ],
        ),
      );
      await firstLoad.refresh(30);
      expect(firstLoad.phase, UsagePhase.ready);
      expect(firstLoad.errorMessage, isNull);
      expect(firstLoad.hasData, isTrue);
      expect(firstLoad.summary.providers.single.provider, 'opencode');
    });

    test('todayProviders 只按 UTC 今日日桶过滤', () async {
      final relay = FixtureRelayRepository(clock: () => now);
      relay.replaceUsageSummary(
        summary(
          providers: [
            day(provider: 'codex', utcDay: '2026-08-16', input: 100),
            day(provider: 'claude', utcDay: '2026-08-15', input: 200),
            day(provider: 'opencode', utcDay: '2026-08-16', input: 300),
            day(provider: 'openclaw', utcDay: '2026-08-01', input: 400),
          ],
        ),
      );
      final controller = UsageController(relay: relay);
      await controller.initialize();

      expect(controller.hasData, isTrue);
      final today = controller.todayProviders;
      expect(today, hasLength(2));
      expect(today.map((item) => item.provider), containsAll(['codex', 'opencode']));
      expect(today.every((item) => item.utcDay == '2026-08-16'), isTrue);
    });
  });
}

/// 按请求窗口返回不同摘要的 fixture 子类，验证窗口切换时摘要随 days 更新。
class _WindowAwareRelay extends FixtureRelayRepository {
  _WindowAwareRelay({super.clock});

  final Map<int, UsageSummary> _byDays = {};

  @override
  void replaceUsageSummary(UsageSummary summary) {
    _byDays[summary.days] = summary;
  }

  @override
  Future<UsageSummary> getUsageSummary({int days = 30}) async =>
      _byDays[days] ?? UsageSummary.empty;
}
