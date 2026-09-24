import 'dart:convert';
import 'dart:math';

import 'package:agent_sessions_mobile/diagnostics/streaming_telemetry.dart';
import 'package:agent_sessions_mobile/domain/session_models.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixture_owner.dart';

/// 可步进的测试时钟：埋点 ts 的单调性与 latency 断言都由它保证。
DateTime _now = DateTime.utc(2026, 9, 5, 10, 0, 0);

const _ownerDeviceId = 'android-owner-fixture';

Future<void> _prepareOwner(FixtureRelayRepository relay) async {
  await bootstrapFixtureOwner(relay);
}

/// 稳定随机数让幂等键的测试环境可重复（与 session_controller_test 同口径）。
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

/// 分批吐出流式增量的 fixture relay（v0.8.7 门禁 2 专用）。
///
/// 语义对齐 localdev encoder：每条流式帧携带「全量已收文本」+ streaming:true，
/// 最后一帧为 streaming:false 的权威全文 + completed_turn 标记。每次快照拉取
/// 只推进一批，并把注入时钟前移 60ms——保证跨批埋点 ts 严格递增、批内不倒退。
class _BatchedStreamRelay extends FixtureRelayRepository {
  _BatchedStreamRelay({required super.clock, this.embedSecret = false});

  /// 审计红线探针：为 true 时正文嵌入唯一标记，导出负载零命中才算合格。
  final bool embedSecret;

  /// 批次吐出武装开关：createSession 会先做一次历史快照加载（与 send 无关），
  /// 测试在 sendMessage 前调用 [beginTurn]，保证批次与 send 轮询一一对应。
  bool _armed = false;

  void beginTurn() {
    _armed = true;
  }

  static const _secretMarker = 'AXIOM-SECRET-正文-9f2c';
  static const _fullText = '你好，世界！';
  // 每批的「全量已收文本」快照（localdev 契约），最后一批之后出权威全文。
  static const _batches = <List<String>>[
    <String>['你好', '你好，'],
    <String>['你好，世界'],
    <String>['你好，世界！'],
  ];

  int _fetchCount = 0;
  // 合成事件序号跨批连续递增：客户端以 lastSequence 作 afterSequence 续拉，
  // 每批新 seq 必须高于上一批，否则会被埋点/合并层的高水位去重丢弃。
  int _syntheticSeq = -1;

  String _text(String text) => embedSecret ? '$text$_secretMarker' : text;

  @override
  Future<SessionSnapshot> getSessionSnapshot(
    String sessionId, {
    int afterSequence = 0,
    int? beforeSequence,
    int? limit,
  }) async {
    final snapshot = await super.getSessionSnapshot(
      sessionId,
      afterSequence: afterSequence,
    );
    // 未武装前（会话创建/历史加载窗口）不吐批、不推进时钟。
    if (!_armed) return snapshot;
    if (_syntheticSeq < 0) {
      _syntheticSeq = snapshot.session.lastSequence;
    }
    final batch = _fetchCount < _batches.length
        ? _batches[_fetchCount]
        : null;
    final isFinal = _fetchCount == _batches.length;
    _fetchCount += 1;
    // 推进注入时钟：跨批 ts 严格递增，latency/since_last 断言以此为据。
    _now = _now.add(const Duration(milliseconds: 60));

    final events = <RelaySessionEvent>[];
    for (final text in batch ?? const <String>[]) {
      events.add(_frame(++_syntheticSeq, _text(text), streaming: true));
    }
    if (isFinal) {
      events.add(
        _frame(++_syntheticSeq, _text(_fullText), streaming: false, copy: true),
      );
      events.add(
        RelaySessionEvent(
          sequence: ++_syntheticSeq,
          eventType: 'turn.completed',
          envelope: const {
            'fixture_payload': {
              'kind': 'assistant_message',
              'label': 'Assistant',
              'completed_turn': true,
            },
          },
        ),
      );
    }
    return SessionSnapshot(
      session: snapshot.session.copyWith(
        // 在途批次必须保持 streaming，客户端轮询才会继续驱动下一批。
        status: isFinal ? MobileSessionStatus.idle : MobileSessionStatus.streaming,
        lastSequence: _syntheticSeq,
      ),
      events: events,
    );
  }

  RelaySessionEvent _frame(
    int seq,
    String text, {
    required bool streaming,
    bool copy = false,
  }) => RelaySessionEvent(
    sequence: seq,
    eventType: streaming ? 'message.delta' : 'message.completed',
    envelope: {
      'fixture_payload': {
        'kind': 'assistant_message',
        'label': 'Assistant',
        'text': text,
        'streaming': streaming,
        if (copy) 'copy_text': text,
      },
    },
  );
}

/// 导出负载事件列表（json 往返后泛型丢失，逐项还原为 Map）。
List<Map<String, Object?>> _allEvents(Map<String, Object?> exported) =>
    (exported['events']! as List)
        .map((event) => event as Map<String, Object?>)
        .toList();

/// 提取导出负载里的帧类事件（排除 stream_poll 节奏采样）。
List<Map<String, Object?>> _frameEvents(Map<String, Object?> exported) =>
    _allEvents(exported)
        .where((event) => event['type'] != 'stream_poll')
        .toList();

List<Map<String, Object?>> _pollEvents(Map<String, Object?> exported) =>
    _allEvents(exported)
        .where((event) => event['type'] == 'stream_poll')
        .toList();

void main() {
  // V087-02：完整流式回合的埋点序列——首字延迟、逐 delta 增量/累计、终态对账。
  test('V087-02 流式回合埋点：字段齐全、seq 严格递增、增量与对账正确', () async {
    final relay = _BatchedStreamRelay(clock: () => _now);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );
    // 在途窗口收窄到毫秒级：分批到达由 relay 逐批吐出驱动，测试秒级完成。
    controller.foregroundPollAttempts = 8;
    controller.pollInterval = const Duration(milliseconds: 1);
    relay.beginTurn();

    await controller.sendMessage(
      message: '讲个笑话',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    final exported = controller.streamingTelemetry.export();
    expect(exported['schema_version'], kStreamingTelemetrySchemaVersion);

    final frames = _frameEvents(exported);
    final types = frames.map((event) => event['type']).toList();
    expect(types, [
      'stream_first_delta',
      'stream_delta',
      'stream_delta',
      'stream_delta',
      'stream_completed_reconcile',
    ]);

    // seq 严格递增（去重高水位 + 时间线序的正确性副产品）。
    final seqs = frames.map((event) => event['seq'] as int).toList();
    for (var i = 1; i < seqs.length; i++) {
      expect(seqs[i], greaterThan(seqs[i - 1]));
    }

    // 首字延迟 = 首帧观测时刻 - send 受理时刻（每批步进 60ms → 恰为 60）。
    expect(frames.first['latency_ms'], 60);
    expect(frames.first['kind'], 'assistant');

    // 逐 delta 增量与累计：'你好'→'你好，'→'你好，世界'→'你好，世界！'。
    final deltas = frames.where((e) => e['type'] == 'stream_delta').toList();
    expect(deltas.map((e) => e['delta_chars']), [1, 2, 1]);
    expect(deltas.map((e) => e['cumulative_chars']), [3, 5, 6]);
    // 批内两帧同一时钟刻（since_last=0 合法），跨批由 60ms 步进驱动。
    expect(deltas.map((e) => e['since_last_ms']), [0, 60, 60]);

    // 终态对账：completed 全文 6 字 == 最后流式帧 6 字。
    final reconcile = frames.last;
    expect(reconcile['final_chars'], 6);
    expect(reconcile['last_stream_chars'], 6);
    expect(reconcile['consistent'], isTrue);

    // 轮询节奏采样：初始一批 + 三次在途轮询；本批新事件量与计划表一致。
    final polls = _pollEvents(exported);
    expect(polls.map((e) => e['attempt']), [0, 1, 2, 3]);
    expect(polls.map((e) => e['new_events']), [2, 1, 1, 2]);
    for (final poll in polls) {
      expect(poll['fetch_ms'], isA<int>());
    }

    // 全量 ts 非递减（同批同刻允许相等，跨批由时钟步进保证递增）。
    final allEvents = _allEvents(exported)
        .map((event) => event['ts'] as String)
        .toList();
    for (var i = 1; i < allEvents.length; i++) {
      expect(
        DateTime.parse(allEvents[i]).isBefore(DateTime.parse(allEvents[i - 1])),
        isFalse,
      );
    }
  });

  // V087-03：审计红线——导出负载只含白名单元数据字段，正文字符串零命中。
  test('V087-03 埋点审计：导出不含正文标记，字段键在 schema 白名单内', () async {
    final relay = _BatchedStreamRelay(clock: () => _now, embedSecret: true);
    await _prepareOwner(relay);
    final controller = SessionController(
      relay: relay,
      clock: () => _now,
      random: _DeterministicRandom(),
    );
    await controller.initialize();
    await controller.createSession(
      workspaceId: 'fixture-workspace',
      provider: 'opencode',
      deviceId: _ownerDeviceId,
      canWrite: true,
      autoStart: true,
    );
    controller.foregroundPollAttempts = 8;
    controller.pollInterval = const Duration(milliseconds: 1);
    relay.beginTurn();

    await controller.sendMessage(
      message: '审计探针',
      deviceId: _ownerDeviceId,
      canWrite: true,
    );

    final encoded = jsonEncode(controller.streamingTelemetry.export());
    // 正文标记出现在每一条帧文本里，但绝不能泄漏进埋点导出。
    expect(encoded.contains(_BatchedStreamRelay._secretMarker), isFalse);

    // schema v1 字段白名单：事件键集必须逐型精确匹配，多一字段即违规。
    final allowed = <String, Set<String>>{
      'stream_first_delta': {'seq', 'kind', 'message_id', 'latency_ms'},
      'stream_delta': {
        'seq',
        'kind',
        'message_id',
        'delta_chars',
        'cumulative_chars',
        'since_last_ms',
        'block',
      },
      'stream_completed_reconcile': {
        'seq',
        'kind',
        'message_id',
        'final_chars',
        'last_stream_chars',
        'consistent',
      },
      'stream_poll': {'session_id', 'attempt', 'new_events', 'fetch_ms'},
    };
    final events = _allEvents(controller.streamingTelemetry.export())
        .where((event) => allowed.containsKey(event['type']))
        .toList();
    expect(events, isNotEmpty);
    for (final event in events) {
      expect(
        event.keys.toSet().difference({'type', 'ts'}),
        allowed[event['type']! as String],
        reason: '事件 ${event['type']} 出现白名单之外的字段',
      );
    }
  });

  // sink 直测：基线外帧不进埋点、seq 高水位去重、新回合基线清账、ring 容量上限。
  test('V087-02 sink 直测：基线外忽略、重复 seq 去重、新回合清帧状态、ring 容量淘汰最旧', () {
    final telemetry = StreamingTelemetry(capacity: 3, now: () => _now);

    // send 基线之外（历史加载路径）的帧不产生埋点。
    telemetry.observeStreamingFrame(
      sessionId: 's1',
      seq: 1,
      kind: 'assistant',
      messageId: null,
      text: '历史全文',
      streaming: false,
    );
    expect(telemetry.events.where((event) => event.type != 'stream_poll'), isEmpty);

    // 回合开始：首帧作为 stream_first_delta 记录。
    telemetry.observeSendAccepted();
    telemetry.observeStreamingFrame(
      sessionId: 's1',
      seq: 2,
      kind: 'assistant',
      messageId: null,
      text: '你好',
      streaming: true,
    );
    // 同一 seq 的全量重解析/重复投递不产生重复埋点。
    telemetry.observeStreamingFrame(
      sessionId: 's1',
      seq: 2,
      kind: 'assistant',
      messageId: null,
      text: '你好',
      streaming: true,
    );
    // 非 assistant/thought 通道不进埋点。
    telemetry.observeStreamingFrame(
      sessionId: 's1',
      seq: 3,
      kind: 'tool',
      messageId: null,
      text: '工具输出',
      streaming: true,
    );
    final frameEvents = telemetry.events
        .where((event) => event.type != 'stream_poll')
        .toList();
    expect(frameEvents.length, 1);
    expect(frameEvents.single.type, 'stream_first_delta');

    // 新回合基线清掉帧状态：同身份下一帧重新作为首帧（而非累计增量）。
    telemetry.observeSendAccepted();
    telemetry.observeStreamingFrame(
      sessionId: 's1',
      seq: 4,
      kind: 'assistant',
      messageId: null,
      text: '新回合',
      streaming: true,
    );
    final last = telemetry.events.last;
    expect(last.type, 'stream_first_delta');
    expect(last.fields['latency_ms'], 0);

    // 容量 3：再灌 5 条只保留最新 3 条。
    for (var i = 0; i < 5; i++) {
      telemetry.observePoll(
        sessionId: 's1',
        attempt: i,
        newEvents: 0,
        fetchMs: 1,
      );
    }
    expect(telemetry.length, 3);
  });

  // V087-12 真实桥事实：回答按 step 分多条 assistant 消息（新块累积重新开始，
  // message_id 缺失无法区分身份）。sink 以累计回退检测新块并递增 block 序号，
  // 块内增量与累计保持单调，reconcile 以当前块对账。
  test('V087-12 sink 多块流：累计回退递增 block、块内单调、终态按当前块对账', () {
    final telemetry = StreamingTelemetry(now: () => _now);
    telemetry.observeSendAccepted();
    var seq = 0;
    void frame(String text, {bool streaming = true}) {
      telemetry.observeStreamingFrame(
        sessionId: 's1',
        seq: ++seq,
        kind: 'assistant',
        messageId: null,
        text: text,
        streaming: streaming,
      );
    }

    frame('第一块'); // block 0 首帧
    frame('第一块续'); // block 0 增量
    frame('二'); // 累计回退 → block 1 起点
    frame('第二块'); // block 1 增量
    frame('第二块', streaming: false); // 终态对账（completed 全文=当前块）

    final deltas = telemetry.events
        .where((event) => event.type == 'stream_delta')
        .toList();
    // 块 0：'第一块'→首帧不计 delta（first_delta），'第一块续'→delta；
    // 块 1：'二'（回退帧）+ '第二块' 两条 delta。
    expect(deltas.map((e) => e.fields['block']), [0, 1, 1]);
    expect(deltas.map((e) => e.fields['cumulative_chars']), [4, 1, 3]);
    final reconcile = telemetry.events
        .firstWhere((event) => event.type == 'stream_completed_reconcile');
    expect(reconcile.fields['consistent'], isTrue);
    expect(reconcile.fields['final_chars'], 3);
  });
}
