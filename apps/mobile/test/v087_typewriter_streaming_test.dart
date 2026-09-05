import 'dart:math';

import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/ui/session/chat/session_markdown_text.dart';
import 'package:agent_sessions_mobile/ui/session/chat/typewriter_reveal_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// 可步进的测试时钟：时间释放脚本的到期判定完全由它驱动（无真实等待）。
DateTime _now = DateTime.utc(2026, 9, 5, 12, 0, 0);

const _ownerDeviceId = 'android-owner-fixture';

Future<void> _prepareOwner(FixtureRelayRepository relay) async {
  await bootstrapFixtureOwner(relay);
}

/// 每次快照拉取推进测试时钟 [step]：让 send 在途轮询以「每次拉取 = 时间前进一步」
/// 的确定节奏驱动时间释放脚本（与真实时序解耦，无 flake）。
class _SteppingTimedRelay extends FixtureRelayRepository {
  _SteppingTimedRelay({required super.clock});

  /// 每次快照推进 30ms：与脚本 40/80/120ms 偏移配合形成确定到达序列。
  final Duration step = const Duration(milliseconds: 30);

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
  }) async {
    _now = _now.add(step);
    return super.getSessionSnapshot(sessionId, afterSequence: afterSequence);
  }
}

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

SessionController _controller(FixtureRelayRepository relay) => SessionController(
  relay: relay,
  clock: () => _now,
  random: _DeterministicRandom(),
);

Future<SessionController> _readySession(FixtureRelayRepository relay) async {
  await _prepareOwner(relay);
  final controller = _controller(relay);
  await controller.initialize();
  await controller.createSession(
    workspaceId: 'fixture-workspace',
    provider: 'opencode',
    deviceId: _ownerDeviceId,
    canWrite: true,
    autoStart: true,
  );
  return controller;
}

void main() {
  // V087-04：时间释放脚本——delta 按偏移逐帧到期，completed 到期释放终态；
  // 客户端在收紧档轮询下收到逐步到达的全量文本帧（localdev 语义）。
  test('V087-04 fixture 时间释放：逐帧到期 + completed 释放 + 最终单一生长节点', () async {
    final relay = _SteppingTimedRelay(clock: () => _now);
    relay.timedStreamSchedule = TimedStreamSchedule(
      offsets: const [
        Duration(milliseconds: 40),
        Duration(milliseconds: 80),
        Duration(milliseconds: 120),
      ],
      fullTexts: const ['你好', '你好，世界', '你好，世界！'],
      finalText: '你好，世界！',
      completedAfter: const Duration(milliseconds: 160),
    );
    final controller = await _readySession(relay);
    controller.foregroundPollAttempts = 12;
    controller.activePollInterval = const Duration(milliseconds: 1);
    controller.pollInterval = const Duration(milliseconds: 200);

    await controller.sendMessage(
      message: 'v087 timed',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    // 到达节奏由「每次快照 +30ms」确定：初始帧未到期（0），随后三帧逐帧到达，
    // completed 帧与终态标记同批到达（2）。任何帧序错乱都会破坏该序列。
    // 初始批=2：命令回执路径有一次额外快照把时钟推到 +60（用户消息+首帧同批
    // 可见）；此后三帧按步进逐帧到达，最后 completed+终态标记同批（2）。
    final polls = controller.streamingTelemetry.events
        .where((event) => event.type == 'stream_poll')
        .map((event) => event.fields['new_events'])
        .toList();
    expect(polls, [2, 1, 1, 1, 0, 2]);

    // 首字延迟 = 60ms（第一次快照 +30 时首帧 40ms 尚未到期）。
    final firstDelta = controller.streamingTelemetry.events
        .firstWhere((event) => event.type == 'stream_first_delta');
    expect(firstDelta.fields['latency_ms'], 60);

    // 增量到达：首帧记为 stream_first_delta（累计 2），其后的 stream_delta
    // 累计 [5,6]（每批恰好一帧，localdev 全量文本语义）。
    final cumulative = controller.streamingTelemetry.events
        .where((event) => event.type == 'stream_delta')
        .map((event) => event.fields['cumulative_chars'])
        .toList();
    expect(cumulative, [5, 6]);

    // 终态：completed 全文替换生长节点，时间线只剩单一 assistant 气泡。
    final assistantNodes = controller.timeline
        .where(
          (event) =>
              event.kind == SessionTimelineKind.assistantMessage &&
              !event.completedTurn,
        )
        .toList();
    expect(assistantNodes.length, 1);
    expect(assistantNodes.single.text, '你好，世界！');
    expect(assistantNodes.single.isStreaming, isFalse);

    // 终态对账一致。
    final reconcile = controller.streamingTelemetry.events
        .firstWhere((event) => event.type == 'stream_completed_reconcile');
    expect(reconcile.fields['consistent'], isTrue);
  });

  // V087-05：在途轮询收紧档——send 在途前台窗口使用 activePollInterval（1ms）
  // 而非 pollInterval（200ms）；若误用后者，7 次轮询将耗时 ≥1.4s。
  test('V087-05 在途收紧档：收紧间隔驱动轮询节奏，窗口语义与超时收敛不回归', () async {
    final relay = _SteppingTimedRelay(clock: () => _now);
    relay.timedStreamSchedule = TimedStreamSchedule(
      offsets: const [
        Duration(milliseconds: 40),
        Duration(milliseconds: 80),
        Duration(milliseconds: 120),
        Duration(milliseconds: 160),
      ],
      fullTexts: const ['一', '一二', '一二三', '一二三四'],
      finalText: '一二三四',
      completedAfter: const Duration(milliseconds: 200),
    );
    final controller = await _readySession(relay);
    controller.foregroundPollAttempts = 12;
    controller.activePollInterval = const Duration(milliseconds: 1);
    // 故意把一般档拉大到 200ms：在途循环若误用 pollInterval，整个回合将
    // 至少 7×200ms=1.4s，800ms 上限即可判负。
    controller.pollInterval = const Duration(milliseconds: 200);

    final watch = Stopwatch()..start();
    await controller.sendMessage(
      message: 'v087 timed',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(800));

    // 到达节奏：初始 0 帧 → 四帧逐帧 → 空批 → 终态批。
    // 同 V087-04：初始批含用户消息+首帧（额外快照已把时钟推到 +60）。
    final polls = controller.streamingTelemetry.events
        .where((event) => event.type == 'stream_poll')
        .map((event) => event.fields['new_events'])
        .toList();
    // 帧偏移 40/80/120/160、步进 30：+60 处首帧与用户消息同批，
    // +150 拍无新帧（帧4 偏移 160 尚未到期），+210 拍终态批。
    expect(polls, [2, 1, 1, 1, 0, 1, 2]);

    // 后台续轮/超时收敛语义不回归：终态已在前台到达，后台不再续跑
    // （turnInFlight 复位由 sendMessage 完成路径保证）。
    expect(controller.isTurnTimedOut(controller.selectedSessionId), isFalse);
  });

  // V087-04（直接可见性）：手动步进时钟，逐点断言 snapshot 只暴露已到期帧，
  // 且会话行 lastSequence 修正为可见最大 seq（否则未到期帧永远不可见）。
  test('V087-04 快照可见性：未到期帧隐藏、lastSequence 修正、到期即释放', () async {
    final relay = FixtureRelayRepository(clock: () => _now);
    relay.timedStreamSchedule = TimedStreamSchedule(
      offsets: const [
        Duration(milliseconds: 30),
        Duration(milliseconds: 60),
        Duration(milliseconds: 90),
      ],
      fullTexts: const ['甲', '甲乙', '甲乙丙'],
      finalText: '甲乙丙',
      completedAfter: const Duration(milliseconds: 120),
    );
    final controller = await _readySession(relay);
    final sessionId = controller.selectedSessionId!;
    controller.foregroundPollAttempts = 4;
    controller.activePollInterval = const Duration(milliseconds: 1);
    final sending = controller.sendMessage(
      message: 'v087 timed',
      deviceId: _ownerDeviceId,
      canWrite: true,
      awaitTurnCompletion: false,
    );
    // 让初始拉取（send 受理后）先完成：此刻脚本刚起步，无 delta 到期。
    await Future<void>.delayed(const Duration(milliseconds: 20));

    Future<List<SessionTimelineEvent>> visibleDeltaFrames() async {
      final snapshot = await relay.getSessionSnapshot(sessionId);
      return snapshot.events
          .map(SessionTimelineEvent.fromRelayEvent)
          .where(
            (event) =>
                event.kind == SessionTimelineKind.assistantMessage &&
                event.isStreaming,
          )
          .toList();
    }

    // t0：一帧都未到期。
    expect((await visibleDeltaFrames()), isEmpty);

    // +30ms：第一帧到期可见，且会话行 lastSequence = 该帧 seq。
    _now = _now.add(const Duration(milliseconds: 30));
    var snapshot = await relay.getSessionSnapshot(sessionId);
    expect((await visibleDeltaFrames()).length, 1);
    expect(
      snapshot.session.lastSequence,
      snapshot.events
          .map((event) => event.sequence)
          .reduce((left, right) => left > right ? left : right),
    );

    // +60ms：第二帧到期。
    _now = _now.add(const Duration(milliseconds: 30));
    snapshot = await relay.getSessionSnapshot(sessionId);
    expect((await visibleDeltaFrames()).length, 2);

    // +150ms：completed 全文与终态到期释放。
    _now = _now.add(const Duration(milliseconds: 90));
    snapshot = await relay.getSessionSnapshot(sessionId);
    final kinds = snapshot.events
        .map(SessionTimelineEvent.fromRelayEvent)
        .where((event) => event.kind == SessionTimelineKind.assistantMessage)
        .toList();
    expect(kinds.any((event) => !event.isStreaming), isTrue);
    expect(kinds.any((event) => event.completedTurn), isTrue);

    // 后台续轮收口回合（真实 500ms 一拍，给足两拍）。
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await sending;
  });

  // ---------- TypewriterRevealText 组件测试（V087-06/07） ----------

  // V087-06：打字机释放——增量到达阶段前缀渐进生长；不超前 buffer；
  // completed 到达立即对账收敛。
  testWidgets('V087-06 打字机释放：渐进生长、不超前、completed 立即收敛', (
    tester,
  ) async {
    typewriterRevealEnabled = true;
    addTearDown(() => typewriterRevealEnabled = true);
    final log = _RevealLog();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TypewriterRevealText(
            text: '你好',
            streaming: true,
            tickInterval: const Duration(milliseconds: 16),
            builder: log.build,
          ),
        ),
      ),
    );
    // 首帧整段显示（动画只作用于增量到达阶段）。
    expect(log.last, '你好');

    // 数据增长到 5 字符：第一拍仍未释放新字符（16ms tick 未到期）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TypewriterRevealText(
            text: '你好，世界',
            streaming: true,
            tickInterval: const Duration(milliseconds: 16),
            builder: log.build,
          ),
        ),
      ),
    );
    expect(log.last, '你好');

    // 每 tick 释放 1 字符（落后 3 ~/ 24 + 1）：48ms 后追平目标。
    await tester.pump(const Duration(milliseconds: 16));
    expect(log.last, '你好，');
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(log.last, '你好，世界');

    // 追平后再 pump 也不超前 buffer（未到达字符绝不出现）。
    await tester.pump(const Duration(milliseconds: 160));
    expect(log.last, '你好，世界');

    // completed 权威全文到达：立即整段显示（对账收敛，无动画尾滞）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TypewriterRevealText(
            text: '你好，世界！',
            streaming: false,
            tickInterval: const Duration(milliseconds: 16),
            builder: log.build,
          ),
        ),
      ),
    );
    expect(log.last, '你好，世界！');
  });

  // V087-06：partial Markdown 中间态——半开代码块/未闭合标记随释放推进，
  // display-safe 渲染全程不抛异常，completed 后完整渲染。
  testWidgets('V087-06 partial Markdown：半开中间态不崩，终态完整渲染', (
    tester,
  ) async {
    typewriterRevealEnabled = true;
    addTearDown(() => typewriterRevealEnabled = true);
    final fullText = '# 标题\n\n正文段落。\n\n```dart\nvoid main() {}\n```\n';
    final stages = <String>[
      fullText.substring(0, 6),
      fullText.substring(0, 14),
      // 半开代码块：fence 已开未闭合。
      fullText.substring(0, 28),
      fullText,
    ];
    var stage = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TypewriterRevealText(
              text: stages[stage],
              streaming: stage < stages.length - 1,
              tickInterval: const Duration(milliseconds: 16),
              builder: (context, revealedText) =>
                  SessionMarkdownText(text: revealedText, color: Colors.black),
            ),
          ),
        ),
      ),
    );
    for (stage = 1; stage < stages.length; stage++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => TypewriterRevealText(
                text: stages[stage],
                streaming: stage < stages.length - 1,
                tickInterval: const Duration(milliseconds: 16),
                builder: (context, revealedText) => SessionMarkdownText(
                  text: revealedText,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
      );
      // 释放推进到当前 stage 全文（半开中间态只要求不崩 + 有内容渲染）。
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.byType(SessionMarkdownText), findsOneWidget);
  });

  // V087-07：回滚开关置关——数据更新即刻整段渲染（v0.8.6 现状形态）。
  testWidgets('V087-07 回滚形态：开关置关时整段渲染、无渐进释放', (tester) async {
    typewriterRevealEnabled = false;
    addTearDown(() => typewriterRevealEnabled = true);
    final log = _RevealLog();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TypewriterRevealText(
            text: '第一段',
            streaming: true,
            tickInterval: const Duration(milliseconds: 16),
            builder: log.build,
          ),
        ),
      ),
    );
    expect(log.last, '第一段');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TypewriterRevealText(
            text: '第一段第二段第三段',
            streaming: true,
            tickInterval: const Duration(milliseconds: 16),
            builder: log.build,
          ),
        ),
      ),
    );
    // 置关：新数据即刻整段渲染，无 tick、无渐进。
    expect(log.last, '第一段第二段第三段');
    await tester.pump(const Duration(milliseconds: 64));
    expect(log.last, '第一段第二段第三段');
  });
}

/// 记录 builder 每次构建收到的释放前缀（断言渐进释放序列）。
class _RevealLog {
  final List<String> values = <String>[];

  Widget build(BuildContext context, String revealedText) {
    values.add(revealedText);
    return Text(revealedText, key: const Key('reveal-output'));
  }

  String get last => values.isEmpty ? '' : values.last;
}
