import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_harness.dart';

/// V094 定向回归骨架（P0 登记，计划 §4-P0）：会话骨架布局预算。
///
/// 这些用例是**先红骨架**：在旧实现上可复现地失败，目标实现（P2）落地后转绿，
/// 用于区分"旧布局"与"目标布局"。数值来自计划 §3.2 布局验收预算：
/// - header（含 tabs）≤124dp；
/// - 空/单行 composer 含配置摘要 ≤144dp；
/// - 输入正文可用宽度 ≥ 输入容器内容宽度的 90%；
/// - 恢复/生成提示槽参与布局，不覆盖消息正文（V094-04）。
/// - "可操作"泛化承诺移除（V094-02，P1 文案先行锚点）。
///
/// 环境基线：360×800 逻辑尺寸、textScale 1.0、默认亮色主题（V094-20 矩阵由
/// 可见 fixture gate 另行覆盖）。
void main() {
  _withBaselineSurface(() {
    testWidgets('V094-08 骨架：header 含 tabs 高度 ≤124dp（紧凑标题）', (tester) async {
      await _openSession(tester);

      final headerRect = tester.getRect(
        find.byKey(const Key('session-strict-header')),
      );
      expect(
        headerRect.height,
        lessThanOrEqualTo(124),
        reason:
            'header（含 tabs）必须 ≤124dp（计划 §3.2），'
            '旧实现为 56dp 标题栏 + 常驻状态条 + 42dp tabs，实际 ${headerRect.height}',
      );
    });

    testWidgets('V094-10 骨架：正文输入宽度 ≥ composer 内容宽度 90%（全宽输入）', (
      tester,
    ) async {
      await _openSession(tester);

      final composerRect = tester.getRect(find.byKey(const Key('session-composer')));
      final inputRect = tester.getRect(
        find.byKey(const Key('session-composer-input')),
      );
      // composer 左右各留 AppSpacing.lg(16) 安全边距，内容宽度以输入容器为准。
      final contentWidth = composerRect.width - 16 * 2;
      expect(
        inputRect.width,
        greaterThanOrEqualTo(contentWidth * 0.9),
        reason:
            '正文与工具栏必须分行：输入区占内容宽度 ≥90%（计划 §3.2）。'
            '旧实现命令/附件/文本/发送共用一行，实际 ${inputRect.width}/$contentWidth',
      );
    });

    testWidgets('V094-09 骨架：空草稿 composer（含配置摘要）高度 ≤144dp', (tester) async {
      await _openSession(tester);

      final composerRect = tester.getRect(find.byKey(const Key('session-composer')));
      expect(
        composerRect.height,
        lessThanOrEqualTo(144),
        reason:
            '空/单行 composer 含配置摘要必须 ≤144dp（计划 §3.2）。'
            '旧实现输入后串联模型行/权限表单/空 helper，实际 ${composerRect.height}',
      );
    });

    testWidgets('V094-04 骨架：生成提示槽不覆盖消息正文（参与布局）', (tester) async {
      final harness = await _openSession(tester);

      // 发送一条消息让回合进入 streaming，生成提示（状态槽）出现。
      await enterVisible(
        tester,
        find.byKey(const Key('session-composer-input')),
        '状态槽覆盖检查',
      );
      await tapVisible(
        tester,
        find.byKey(const Key('session-composer-primary-action')),
      );
      await waitForVisible(
        tester,
        find.byKey(const Key('assistant-streaming-indicator')),
      );

      final listRect = tester.getRect(find.byKey(const Key('session-chat-view')));
      final indicatorRect = tester.getRect(
        find.byKey(const Key('assistant-streaming-indicator')),
      );
      final overlaps =
          indicatorRect.top < listRect.bottom &&
          indicatorRect.bottom > listRect.top;
      expect(
        overlaps,
        isFalse,
        reason:
            '状态槽必须参与布局，不得以 Positioned overlay 覆盖消息正文（V094-04）。'
            'indicator=$indicatorRect list=$listRect',
      );
      // harness 供后续扩展断言（滚动锚点、轨迹页可见性）。
      expect(harness.relay, isNotNull);
    });

    testWidgets('V094-02 骨架：头部不再出现"可操作"泛化承诺', (tester) async {
      await _openSession(tester);

      // 旧实现用 canWrite 直接拼出"可操作"，把角色承诺成可发送；
      // 目标实现角色写成"可控制/只读"，能力与连接单独表达。
      expect(
        find.text('可操作'),
        findsNothing,
        reason: '"可操作"不等于可发送（V094-02）：角色应表述为可控制/只读',
      );
    });

    testWidgets('V094-20 骨架：composer seat 按内容自然高，底部无 flex 份额留白', (tester) async {
      await _openSession(tester);

      final seatRect = tester.getRect(find.byKey(const Key('session-composer-seat')));
      final composerRect = tester.getRect(find.byKey(const Key('session-composer')));
      // seat 曾用 flex 3:2 瓜分剩余高度，内容不足时底部堆出大片空白。
      // composer（输入+工具行）是 seat 内最后的内容：其底边必须贴住 seat 底边；
      // 若回退成 flex 份额，内容顶对齐，composer.bottom 将明显小于 seat.bottom。
      // （基线 textScale 1.0 下 seat 内容不滚动，该等式成立；大字滚动场景由矩阵覆盖。）
      // 注意不直接断言 seat.bottom==surface 高：harness 经 MacBook 手机画布
      //（480x960 逻辑画布）渲染，getRect 返回画布坐标，贴底由矩阵截图人工视检。
      expect(
        seatRect.bottom - composerRect.bottom,
        lessThan(1),
        reason:
            'composer 必须贴住 seat 底部（seat 按内容自然高，flex:0 loose），'
            'seat.bottom=${seatRect.bottom} composer.bottom=${composerRect.bottom}',
      );
    });
  });
}

/// 统一 360×800 基线视口（计划 §3.2 的预算基准）。
void _withBaselineSurface(void Function() body) {
  // testWidgets 内部逐用例设置 surface，见 _openSession 前置。
  body();
}

Future<dynamic> _openSession(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(360, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final harness = await openWritableSessionForV094(tester);
  return harness;
}
