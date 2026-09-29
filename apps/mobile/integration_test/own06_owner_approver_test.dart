// OWN-06（v0.10.0 ADR-017）双机真机旅程·旧手机侧（approver）。
//
// 编排：node e2e-verify/mobile/run-android-pair.mjs。本机也是全新安装，因此
// 旅程分两段：
//   A. 本机先经「配对到已有 Relay」加入（编排器持隔离栈终端 owner 令牌批准），
//      成为第二个 active owner——这是后续以手机 UI 批准他人的权限前提；
//   B. 等待新手机（joiner）发起的 pending owner 请求出现在配对页清单（自动
//      拉取 + 手动刷新），核对比对码渲染，走「二次确认」批准——真实批准 UI 路径；
//   C. 打开设备管理：断言 joiner 设备行 active 且本机设备行仍 active（不撤销断言）；
//   D. 工作区列表出现 joiner 新建的会话并打开，等待 assistant 回复文本可见
//      （SSE 实时性；joiner 侧已真实发送，real_model 事实由 joiner 用例收口）。
//
// 必须以 --dart-define=RELAY_BASE_URL=<可达 Relay> 注入运行；默认 gate 显式跳过。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'package:agent_sessions_mobile/main.dart' as app;

const _joinerDisplayName = 'OWN06-Joiner-B';
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

/// 静默等待：出现返回 true，超时返回 false（供 409 重试循环判定）。
Future<bool> _waitQuiet(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// 以 owner 身份发起加入请求并等待批准（阶段 A 的共享路径）。
Future<void> _joinAsSecondOwner(WidgetTester tester) async {
  final deviceConnect = find.byKey(const Key('device-connect-submit'));
  await _pumpUntil(
    tester,
    deviceConnect,
    timeout: const Duration(seconds: 90),
    timeoutMessage: 'OWN-06 approver：全新安装未落在设备初始化页',
  );
  await tester.tap(find.byKey(const Key('owner-pairing-link')));
  final nameField = find.byKey(const Key('owner-pairing-display-name'));
  await _pumpUntil(
    tester,
    nameField,
    timeout: const Duration(seconds: 30),
    timeoutMessage: 'OWN-06 approver：配对页未渲染',
  );
  debugPrint('[OWN06-APPROVER] 配对页已渲染，输入设备名');
  await tester.enterText(nameField, 'OWN06-Approver-A');

  // 单 pending 治理：与 joiner 并发创建的输家会吃 409（按钮仍在）——
  // 本端请求由编排器泵即时批准消费，重试几轮内必然成功。
  final compareCodeCard = find.byKey(const Key('owner-pairing-compare-code'));
  final createButton = find.byKey(const Key('owner-pairing-create'));
  final createDeadline = DateTime.now().add(const Duration(minutes: 3));
  var requestCreated = false;
  var attempts = 0;
  while (DateTime.now().isBefore(createDeadline)) {
    attempts += 1;
    final hit = createButton.evaluate().isNotEmpty;
    if (attempts % 5 == 1) {
      // 错误回显在 _StatusScaffold 的 app-error-message 座位；tap 失败原因必须可见。
      final errorWidget = find.byKey(const Key('app-error-message'));
      final errorText = errorWidget.evaluate().isEmpty
          ? '无'
          : tester.widget<Text>(errorWidget.first).data ?? '(空)';
      debugPrint('[OWN06-APPROVER] 创建重试 #$attempts（按钮在场=$hit，页面错误=$errorText）');
    }
    await tester.tap(createButton, warnIfMissed: false);
    if (await _waitQuiet(tester, compareCodeCard)) {
      requestCreated = true;
      debugPrint('[OWN06-APPROVER] 比对码已展示（重试 #$attempts）');
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  debugPrint('[OWN06-APPROVER] 重试结束 attempts=$attempts requestCreated=$requestCreated');
  expect(
    requestCreated,
    isTrue,
    reason: 'OWN-06 approver：3 分钟重试内仍未拿到比对码（单 pending 重试全失败）',
  );
  debugPrint('[OWN06-APPROVER] 加入请求已创建，等待编排器（终端 owner）批准');
  await _waitForAny(
    tester,
    [find.byKey(const Key('session-home-screen'))],
    timeout: const Duration(minutes: 8),
    timeoutMessage: 'OWN-06 approver：8 分钟内未被终端 owner 批准（编排器审批泵失败？）',
  );
  debugPrint('[OWN06-APPROVER] 本机已加入为 owner');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final injectedRelayBase = const String.fromEnvironment('RELAY_BASE_URL');
  final injectedRun = injectedRelayBase.trim().isNotEmpty;

  testWidgets('OWN-06 approver：加入 → UI 批准 joiner → 双 owner 行 active → 实时看到回复', (
    tester,
  ) async {
    if (!injectedRun) {
      markTestSkipped(
        'OWN-06 approver 必须经 run-android-pair.mjs 注入 RELAY_BASE_URL 运行；'
        '默认 gate 显式跳过，不以无网形态误报。',
      );
      return;
    }
    unawaited(app.main());
    await tester.pump(const Duration(milliseconds: 500));

    // 阶段 A：本机先加入为第二个 owner。
    await _joinAsSecondOwner(tester);

    // 阶段 B：进入配对页，等待 joiner 的 pending 请求（清单自动拉取；
    // 未出现时周期性点「刷新」）。
    final homeContext = tester.element(
      find.byKey(const Key('session-home-screen')),
    );
    GoRouter.of(homeContext).go('/pairing');
    await _pumpUntil(
      tester,
      find.byKey(const Key('pairing-refresh-button')),
      timeout: const Duration(seconds: 30),
      timeoutMessage: 'OWN-06 approver：配对页未渲染（缺刷新按钮）',
    );
    final joinerTile = find.text(_joinerDisplayName);
    final refreshButton = find.byKey(const Key('pairing-refresh-button'));
    final approveDeadline = DateTime.now().add(const Duration(minutes: 8));
    var tileFound = false;
    while (DateTime.now().isBefore(approveDeadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (joinerTile.evaluate().isNotEmpty) {
        tileFound = true;
        break;
      }
      if (refreshButton.evaluate().isNotEmpty) {
        await tester.tap(refreshButton, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 200));
      }
    }
    expect(
      tileFound,
      isTrue,
      reason: 'OWN-06 approver：8 分钟内配对页清单未出现 joiner 请求'
          '（自动清单/刷新链路缺陷，或 joiner 未发起请求）',
    );
    // 比对码渲染：pending 清单中的 owner 请求必须带 6 位比对码。
    final codeTextFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data != null &&
          widget.data!.startsWith('比对码 '),
    );
    expect(codeTextFinder, findsWidgets);
    final codeShown = tester.widget<Text>(codeTextFinder.first).data!;
    final code = codeShown.replaceAll(RegExp(r'[^0-9]'), '');
    expect(
      RegExp(_compareCodePattern).hasMatch(code),
      isTrue,
      reason: '批准端渲染的比对码必须是 6 位数字，实际：$codeShown',
    );
    debugPrint('[OWN06-APPROVER] joiner 请求已可见，比对码：$code');

    // 以 UI 路径批准：点批准 → 二次确认对话框 → 提交。
    final approveButton = _firstWithKeyPrefix('pairing-approve-').first;
    await tester.ensureVisible(approveButton);
    await tester.pump();
    await tester.tap(approveButton, warnIfMissed: false);
    await _pumpUntil(
      tester,
      find.byKey(const Key('pairing-owner-confirm-dialog')),
      timeout: const Duration(seconds: 30),
      timeoutMessage: 'OWN-06 approver：owner 请求批准未弹二次确认（比对码核对契约回退）',
    );
    await tester.tap(find.byKey(const Key('pairing-owner-confirm-submit')));
    debugPrint('[OWN06-APPROVER] 已批准 joiner 请求');

    // 阶段 C：设备管理——joiner 行 active + 本机行仍 active（不撤销断言）。
    final homeAgain = tester.element(find.byKey(const Key('back-home-button')));
    GoRouter.of(homeAgain).go('/devices');
    final joinerDeviceRow = find.text(_joinerDisplayName);
    await _pumpUntil(
      tester,
      joinerDeviceRow,
      timeout: const Duration(seconds: 60),
      timeoutMessage: 'OWN-06 approver：设备管理页未出现 joiner 设备行',
    );
    // 本机设备行仍 active：当前设备名OWN06-Approver-A 存在即代表未被撤销。
    expect(find.text('OWN06-Approver-A'), findsWidgets);
    debugPrint('[OWN06-APPROVER] 双 owner 设备行均在（不撤销断言通过）');

    // 阶段 D：工作区列表出现 joiner 会话 → 打开 → 等待 assistant 回复可见。
    GoRouter.of(tester.element(find.byKey(const Key('back-home-button'))))
        .go('/home');
    final workspaceList = find.byKey(const Key('dsh-workspace-list-scroll'));
    await _pumpUntil(
      tester,
      workspaceList,
      timeout: const Duration(seconds: 120),
      timeoutMessage: 'OWN-06 approver：返回主页后 DSH 工作区列表未渲染',
    );
    // joiner 的会话出现在工作区会话列表（双端同一列表断言）。手机窄屏下会话
    // 列表在工作区详情内：先展开/进入首个工作区，各形态逐级 fallback。
    for (final prefix in const [
      'dsh-workspace-expand-',
      'dsh-workspace-select-',
    ]) {
      final target = _firstWithKeyPrefix(prefix);
      if (target.evaluate().isNotEmpty) {
        await tester.tap(target.first, warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
        break;
      }
    }
    final sessionItem = _firstWithKeyPrefix('dsh-workspace-session-');
    await _pumpUntil(
      tester,
      sessionItem,
      timeout: const Duration(minutes: 6),
      timeoutMessage: 'OWN-06 approver：工作区会话列表未出现 joiner 新建会话（列表实时性缺陷）',
    );
    await tester.tap(sessionItem.first);
    final chatView = find.byKey(const Key('session-chat-view'));
    await _pumpUntil(
      tester,
      chatView,
      timeout: const Duration(seconds: 60),
      timeoutMessage: 'OWN-06 approver：打开 joiner 会话失败',
    );
    // 实时看到回复：transcript 中出现用户节点之外的第 2 个节点座位
    //（assistant 回复或其推理流）——joiner 侧发送后 SSE 投影到达本机。
    final seatDeadline = DateTime.now().add(const Duration(minutes: 5));
    var replyVisible = false;
    while (DateTime.now().isBefore(seatDeadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (_firstWithKeyPrefix('session-chat-node-').evaluate().length >= 2) {
        replyVisible = true;
        break;
      }
    }
    expect(
      replyVisible,
      isTrue,
      reason: 'OWN-06 approver：5 分钟内未实时看到 joiner 会话的回复投影'
          '（SSE 实时性或 joiner 发送失败）',
    );
    debugPrint('[OWN06-APPROVER] 已实时看到 joiner 会话的回复投影：OWN-06 approver 侧旅程完成');
  });
}
