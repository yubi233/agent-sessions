import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/app/router.dart';
import 'package:agent_sessions_mobile/main.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/storage/theme_preference_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// v0.8.8 P3b（V088-13 / 迭代计划 §9.4）：localdev 深链优先于恢复导航。
/// V087-12 帧实证：冷启动下 App 自身的恢复导航晚于深链落地，把目标会话页
/// 覆盖为"新对话"空态页。修复 = `_openSessionWhenReady` 落地后做有限次
/// "再断言"（路由或选中会话被覆盖即重新落地），并把冷启动等待窗口放宽到 60s。
/// 本测试在 macOS 画布路径（与 localdev 真实壳同构）直接驱动 coordinator：
/// ① 深链落地目标会话页；② 注入一次覆盖导航后，再断言循环把页面拉回。
void main() {
  testWidgets('V088-13：深链落地后被覆盖的会话页会被再断言拉回', (tester) async {
    // flutter_test 在测试体结束时校验 foundation 变量复位——必须 try/finally
    // 在体内恢复，addTearDown 来不及。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final relay = FixtureRelayRepository();
    final tokens = InMemorySecureTokenStore();
    final identities = InMemoryDeviceIdentityStore();
    final owner = await bootstrapFixtureOwner(
      relay,
      tokens: tokens,
      identities: identities,
    );

    // 预置一个真实存在于 fixture 的会话（深链目标）。
    final seeder = SessionController(relay: relay);
    await seeder.initialize();
    final created = await seeder.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'codex',
      deviceId: owner.deviceId,
      canWrite: true,
    );
    expect(created, isNotNull, reason: '深链目标会话必须真实存在');
    final sessionId = created!.id;

    late final ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        key: const ValueKey('v088-deeplink-scope'),
        overrides: [
          relayRepositoryProvider.overrideWithValue(relay),
          secureTokenStoreProvider.overrideWithValue(tokens),
          deviceIdentityStoreProvider.overrideWithValue(identities),
          encryptedCacheStoreProvider.overrideWithValue(
            InMemoryEncryptedCacheStore(),
          ),
          themePreferenceStoreProvider.overrideWithValue(
            InMemoryThemePreferenceStore(),
          ),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            // useMacBookPhoneCanvas=true + macOS 平台 → 与 localdev 壳同构，
            // coordinator 挂载并消费 localVisualSessionId 深链。
            return AgentSessionsApp(
              useMacBookPhoneCanvas: true,
              localVisualSessionId: sessionId,
            );
          },
        ),
      ),
    );

    // 1. 深链落地：等待认证 → 会话列表就绪 → 导航到目标会话页。
    final targetLocation = '/sessions/$sessionId';
    var landed = false;
    for (var i = 0; i < 60 && !landed; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      final current = container
          .read(appRouterProvider)
          .routeInformationProvider
          .value
          .uri
          .toString();
      landed = current.startsWith(targetLocation);
    }
    expect(landed, isTrue, reason: '深链应在就绪后落地目标会话页');

    // 2. 模拟"恢复导航"覆盖：路由被拉回首页且选中会话被清空。
    container.read(appRouterProvider).go('/home');
    await tester.pump(const Duration(milliseconds: 50));

    // 3. 再断言循环（500ms × 20）应把页面与选中会话拉回深链目标。
    var restored = false;
    for (var i = 0; i < 60 && !restored; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      final current = container
          .read(appRouterProvider)
          .routeInformationProvider
          .value
          .uri
          .toString();
      final selected = container
          .read(sessionControllerProvider)
          .selectedSessionId;
      restored = current.startsWith(targetLocation) && selected == sessionId;
    }
    expect(restored, isTrue, reason: '深链在位时被覆盖的会话页必须被重新落地');
    // 排空再断言循环的挂起 500ms timer：settled 分支返回前需让当前 tick 触发，
    // 否则 widget tree 释放时仍有 pending timer（flutter_test 不变量）。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  }, timeout: const Timeout(Duration(minutes: 2)));
}
