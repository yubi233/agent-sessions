import 'dart:async';

import 'package:flutter/material.dart';

/// 打字机释放动画全局回滚开关（v0.8.7 §3.2 P0 裁决）。
///
/// 默认开启；置 false 即回到「整段渲染」现状形态（v0.8.6 行为），作为回滚
/// 开关。V087-07 以置关断言回滚形态可用。
bool typewriterRevealEnabled = true;

/// 打字机释放动画的视觉 gate 采样面（V087-08）。
///
/// 记录最近一次释放推进的 (revealed, target) 字符数：视觉场景宿主按固定节拍
/// 读取并写入 streaming-gate 证据文件（门禁 1 的机读判定源）。生产路径无人
/// 消费，开销只是两次静态整数字段赋值。
class TypewriterRevealDiagnostics {
  int? revealed;
  int? target;

  void reset() {
    revealed = null;
    target = null;
  }
}

/// 打字机平滑释放文本（v0.8.7 §3.2 裁决：数据驱动为主 + 平滑释放为辅）。
///
/// fail-closed 约束（防「假打字机」伪造流式）：
///  1. 任何时刻渲染的字符都是「已到达数据」的**前缀**——动画只释放已到达
///     buffer，永不超前、不展示未到达内容；
///  2. 流式结束（[streaming]=false，completed 权威全文到达）立即整段显示并
///     停表（对账收敛，不允许动画尾滞）；
///  3. 数据回退（文本变短）按当前数据截断，不做任何补齐猜测；
///  4. [enabled]=false（或全局开关关闭）为回滚形态：整段渲染，无定时器。
///
/// 释放速率自适应落后量：每个 [tickInterval]（16ms，约一帧）释放
/// `落后字符数 ~/ [catchUpDivisor] + 1`，落后越多追得越快，到齐即停——
/// 数据到达慢时动画跟着慢，永远以数据为准。
class TypewriterRevealText extends StatefulWidget {
  const TypewriterRevealText({
    super.key,
    required this.text,
    required this.streaming,
    required this.builder,
    this.enabled,
    this.tickInterval = const Duration(milliseconds: 16),
    this.catchUpDivisor = 24,
  });

  /// 已到达的全量文本（localdev 投影契约：每帧全量已收文本整体替换）。
  final String text;

  /// 是否仍在流式；false 表示 completed 权威全文已到达。
  final bool streaming;

  /// 用释放出的文本前缀渲染。注入 builder 让释放逻辑与显示层（markdown /
  /// 纯文本）解耦，不改变既有渲染契约。
  final Widget Function(BuildContext context, String revealedText) builder;

  /// 逐实例开关；null 时取全局 [typewriterRevealEnabled]。
  final bool? enabled;

  /// 释放 tick 周期（16ms ≈ 一帧，测试可注入更粗粒度配合 pump）。
  final Duration tickInterval;

  /// 追赶除数：每 tick 释放 `落后 ~/ divisor + 1` 字符。
  final int catchUpDivisor;

  /// 视觉 gate 采样面（仅视觉场景宿主读写；见 [TypewriterRevealDiagnostics]）。
  static final TypewriterRevealDiagnostics diagnostics =
      TypewriterRevealDiagnostics();

  @override
  State<TypewriterRevealText> createState() => _TypewriterRevealTextState();
}

class _TypewriterRevealTextState extends State<TypewriterRevealText> {
  Timer? _timer;
  int _revealed = 0;

  bool get _effectiveEnabled => widget.enabled ?? typewriterRevealEnabled;

  @override
  void initState() {
    super.initState();
    // 首帧整段显示：动画只作用于「增量到达」阶段，避免会话打开时历史消息
    // 也逐字重放。
    _revealed = widget.text.length;
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant TypewriterRevealText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 数据回退按当前数据截断（fail-closed：渲染不超出已到达文本）。
    if (_revealed > widget.text.length) {
      _revealed = widget.text.length;
    }
    // completed 权威全文到达：立即追平（对账收敛），停掉释放定时器。
    if (!widget.streaming) {
      _revealed = widget.text.length;
    }
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// 按需启停释放定时器：仅「已启用 + 仍在流式 + 有未释放字符」时运行。
  void _syncTimer() {
    final needsTimer =
        _effectiveEnabled &&
        widget.streaming &&
        _revealed < widget.text.length;
    if (needsTimer) {
      _timer ??= Timer.periodic(widget.tickInterval, (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    final target = widget.text.length;
    if (_revealed >= target || !widget.streaming) {
      // 目标已追平或数据已终态：停表；终态兜底追平一次。
      if (_revealed < target) {
        setState(() => _revealed = target);
      }
      _timer?.cancel();
      _timer = null;
      return;
    }
    final behind = target - _revealed;
    // 自适应速率：落后越多追得越快（落后 ~/ 24 + 1），至少每 tick 1 字符。
    final grow = behind > 1 ? behind ~/ widget.catchUpDivisor + 1 : 1;
    setState(() {
      _revealed = (_revealed + grow > target) ? target : _revealed + grow;
    });
    if (_revealed >= target) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_effectiveEnabled) {
      // 回滚形态：整段渲染（v0.8.6 现状），不创建任何定时器。
      return widget.builder(context, widget.text);
    }
    final safeEnd = _revealed.clamp(0, widget.text.length);
    // 视觉 gate 采样以「实际渲染的前缀」为准（含 completed 追平帧）——
    // _tick 之外的对账收敛也必须反映到诊断面，否则终态样本会滞留旧值。
    TypewriterRevealText.diagnostics
      ..revealed = safeEnd
      ..target = widget.text.length;
    return widget.builder(context, widget.text.substring(0, safeEnd));
  }
}
