// OWN-06（v0.10.0 ADR-017）双机真机旅程·新手机侧（joiner）。
//
// 编排：node e2e-verify/mobile/run-android-pair.mjs（两台物理设备并发各跑一个
// integration_test 文件，指向同一隔离 Relay）。本文件的角色：
//   1. 全新安装 → 「配对到已有 Relay」发起 owner 加入请求，展示比对码；
//   2. 等待旧手机（approver，own06_owner_approver_test.dart）在配对页批准；
//   3. 领取令牌进入已认证主页，断言双端共享的 DSH 工作区/会话列表可见；
//   4. 新建 DSH 会话并发送一次最小消息（real_model=true，经本机 Daemon→DSH 桥），
//      等待回合收口（assistant 回复事件落投影）。
//
// 口径：real_device=true、real_model=true（发送成功收口时）、fixture_data=false。
// 必须以 --dart-define=RELAY_BASE_URL=<可达 Relay> 注入运行；默认 gate 显式跳过。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:agent_sessions_mobile/main.dart' as app;

const _compareCodePattern = r'^\d{6}$';

Finder _firstWithKeyPrefix(String prefix) => find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith(prefix),
    );

Future<Finder> _waitForAny(
  WidgetTester tester,
  List<Finder> candidates, {
  Duration timeout = const Duration(seconds: 60),
  String? timeoutMessage,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    // 真实网络 I/O 必须跑在真实事件循环里（runAsync），见 v092_dsh_send_loop_test。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (final candidate in candidates) {
      if (candidate.evaluate().isNotEmpty) return candidate;
    }
  }
  throw TestFailure(
    timeoutMessage ?? '等待目标界面超时：${candidates.map((c) => c.toString())}',
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 60),
  String? timeoutMessage,
}) async {
  await _waitForAny(tester, [finder], timeout: timeout, timeoutMessage: timeoutMessage);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final injectedRelayBase = const String.fromEnvironment('RELAY_BASE_URL');
  final injectedRun = injectedRelayBase.trim().isNotEmpty;

  testWidgets('OWN-06 joiner：配对加入 → 领取令牌 → DSH 会话发送并收口', (tester) async {
    if (!injectedRun) {
      markTestSkipped(
        'OWN-06 joiner 必须经 run-android-pair.mjs 注入 RELAY_BASE_URL 运行'
        '（双机旅程由编排器统一拉起隔离栈）；默认 gate 显式跳过，不以无网形态误报。',
      );
      return;
    }
    unawaited(app.main());
    await tester.pump(const Duration(milliseconds: 500));

    // 阶段一：全新安装必须落在设备初始化页（隔离 Relay 已有账号 → 不允许 bootstrap）。
    final deviceConnect = find.byKey(const Key('device-connect-submit'));
    await _pumpUntil(
      tester,
      deviceConnect,
      timeout: const Duration(seconds: 90),
      timeoutMessage: 'OWN-06 joiner：全新安装未落在设备初始化页，无法发起配对加入',
    );

    // 阶段二：进入「配对到已有 Relay」并发起请求。
    await tester.tap(find.byKey(const Key('owner-pairing-link')));
    final nameField = find.byKey(const Key('owner-pairing-display-name'));
    await _pumpUntil(
      tester,
      nameField,
      timeout: const Duration(seconds: 30),
      timeoutMessage: 'OWN-06 joiner：配对页未渲染',
    );
    await tester.enterText(nameField, 'OWN06-Joiner-B');
    await tester.tap(find.byKey(const Key('owner-pairing-create')));

    // 阶段三：比对码展示（6 位数字）——批准前双端核对的 ADR-017 契约。
    final compareCodeCard = find.byKey(const Key('owner-pairing-compare-code'));
    await _pumpUntil(
      tester,
      compareCodeCard,
      timeout: const Duration(seconds: 30),
      timeoutMessage: 'OWN-06 joiner：创建请求后未展示比对码（服务端开关未开或请求被拒）',
    );
    final codeText = tester
        .widget<Text>(
          find.descendant(
            of: compareCodeCard,
            matching: find.byWidgetPredicate(
              (widget) => widget is Text && (widget.data ?? '').isNotEmpty,
            ),
          ),
        )
        .data!;
    debugPrint('[OWN06-JOINER] 比对码：$codeText');
    expect(
      RegExp(_compareCodePattern).hasMatch(codeText),
      isTrue,
      reason: '比对码必须是 6 位数字，实际：$codeText',
    );

    // 阶段四：等待旧手机批准（配对页自带 2s 轮询；批准后自动进主页）。
    final homeScreen = find.byKey(const Key('session-home-screen'));
    await _waitForAny(
      tester,
      [homeScreen],
      timeout: const Duration(minutes: 8),
      timeoutMessage:
          'OWN-06 joiner：等待批准超时——approver 端未在 8 分钟内批准本机请求',
    );
    debugPrint('[OWN06-JOINER] 已批准并领取令牌，进入已认证主页');

    // 阶段五：双端共享的 DSH 工作区列表可见（与 approver 同一账号投影）。
    final workspaceList = find.byKey(const Key('dsh-workspace-list-scroll'));
    await _pumpUntil(
      tester,
      workspaceList,
      timeout: const Duration(seconds: 120),
      timeoutMessage: 'OWN-06 joiner：已认证但 DSH 工作区列表未渲染',
    );

    // 阶段六：选择首个工作区并新建 DSH 会话（真实 daemon 自动 lease+start）。
    // 手机窄屏/宽屏形态的进入路径不同，逐级 fallback。
    for (final prefix in const [
      'dsh-workspace-select-',
      'dsh-workspace-expand-',
    ]) {
      final target = _firstWithKeyPrefix(prefix);
      if (target.evaluate().isNotEmpty) {
        await tester.tap(target.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
        break;
      }
    }
    final createButton = find.byKey(
      const Key('dsh-workspace-create-session-button'),
    );
    await _pumpUntil(
      tester,
      createButton,
      timeout: const Duration(seconds: 60),
      timeoutMessage: 'OWN-06 joiner：工作区详情未出现「新建会话」入口',
    );
    await tester.tap(createButton);
    final composerInput = find.byKey(const Key('session-composer-input'));
    await _pumpUntil(
      tester,
      composerInput,
      timeout: const Duration(seconds: 120),
      timeoutMessage: 'OWN-06 joiner：新建会话后未进入会话视图（lease/start 链路失败？）',
    );

    // 阶段七：发送最小消息（real_model 一次最小调用）并等待回合收口。
    await tester.enterText(composerInput, '请只回复：OK');
    await tester.tap(find.byKey(const Key('session-composer-primary-action')));
    debugPrint('[OWN06-JOINER] 消息已发送，等待回合收口');

    final stopButton = find.byKey(const Key('session-stop-button'));
    // 生成中先出现 stop 按钮（可选：渠道极快时可能跳过），随后消失即回合终态。
    await _waitForAny(
      tester,
      [stopButton, find.byKey(const Key('session-chat-view'))],
      timeout: const Duration(seconds: 30),
    );
    var settled = false;
    final settleDeadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(settleDeadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final stillRunning = stopButton.evaluate().isNotEmpty;
      final hasAssistantNode = _firstWithKeyPrefix('session-chat-node-')
          .evaluate()
          .length >= 2; // 用户节点 + 至少一个 assistant/推理节点。
      if (!stillRunning && hasAssistantNode) {
        settled = true;
        break;
      }
    }
    expect(
      settled,
      isTrue,
      reason: 'OWN-06 joiner：5 分钟内回合未收口（stop 按钮未消失或投影无 assistant 节点）'
          '——请核对隔离栈 daemon/DSH 桥与渠道可用性',
    );
    debugPrint('[OWN06-JOINER] 回合已收口：OWN-06 joiner 侧旅程完成');
  });
}
