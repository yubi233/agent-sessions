import 'package:agent_sessions_mobile/domain/session_projection_models.dart';
import 'package:agent_sessions_mobile/ui/session/trajectory/session_trajectory_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.5/P6-B：Trajectory 视图直接组件回归。
///
/// 直接注入 `SessionTrajectoryView` 的 display-safe records，覆盖：
/// - turn 分组头；
/// - 默认只显示最近窗口 + load older；
/// - record inspector 打开/关闭；
/// - Overview timeline 范围选择过滤 ledger；
/// - mode 切换清空范围选区；
/// - 搜索索引节流后 streaming partial 仍可被检索。
void main() {
  List<TrajectoryRecord> records({
    int count = 12,
    String turnPrefix = 'turn-',
  }) => [
    for (var i = 1; i <= count; i += 1)
      TrajectoryRecord(
        key: 'trajectory:$i',
        sequence: i,
        kind: i.isEven ? ConversationNodeKind.tool : ConversationNodeKind.user,
        label: i.isEven ? '工具步骤 $i' : '用户消息 $i',
        status: i.isEven ? '运行中' : null,
        summary: '摘要 $i',
        turnId: '$turnPrefix${((i - 1) ~/ 3) + 1}',
        isStreaming: i == count,
        createdAt: DateTime.utc(2026, 8, 21, 0, 0, i),
      ),
  ];

  testWidgets('MOBILE-V05-11/P6-B：turn 分组头、load older 与 record inspector', (
    tester,
  ) async {
    final items = records(count: 12);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionTrajectoryView(
            records: items,
            inspectTarget: null,
            onInspectConsumed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认只显示最近 10 条，因此出现 load older。
    expect(
      find.byKey(const Key('session-trajectory-load-older')),
      findsOneWidget,
    );
    // turn 分组头存在；最近窗口从较早 turn 开始，因此首个可建分组头是 turn-1。
    expect(
      find.byKey(const Key('trajectory-turn-header-turn-1')),
      findsWidgets,
    );

    // 点击可见记录行打开检查器（取最近窗口靠前的一行，避免底部越界）。
    final firstVisibleRow = find.byKey(const Key('trajectory-row-trajectory:3'));
    await tester.ensureVisible(firstVisibleRow);
    await tester.pumpAndSettle();
    await tester.tap(firstVisibleRow);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-trajectory-inspector')),
      findsOneWidget,
    );
    expect(find.textContaining('序列 3'), findsOneWidget);

    // 关闭检查器。
    await tester.tap(
      find.byKey(const Key('session-trajectory-inspector-close')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-trajectory-inspector')),
      findsNothing,
    );

    // 加载更早轨迹后，最近窗口扩展，按钮消失。
    await tester.scrollUntilVisible(
      find.byKey(const Key('session-trajectory-load-older')),
      -120,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('session-trajectory-ledger')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(
      find.byKey(const Key('session-trajectory-load-older')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-trajectory-load-older')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-11/P6-B：Overview timeline 范围选择过滤，mode 切换清空选区', (
    tester,
  ) async {
    final items = records(count: 5);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionTrajectoryView(
            records: items,
            inspectTarget: null,
            onInspectConsumed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 初始没有清除选区按钮。
    expect(
      find.byKey(const Key('session-trajectory-range-clear')),
      findsNothing,
    );

    // 在 Overview 上横向拖动，制造一个范围选区。
    await tester.drag(
      find.byKey(const Key('session-trajectory-overview')),
      const Offset(30, 0),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-trajectory-range-clear')),
      findsOneWidget,
    );

    // 范围选区会过滤 ledger：不可能仍然看到全部 5 个 record row。
    final visibleRows = find.byWidgetPredicate(
      (widget) =>
          widget.key != null &&
          widget.key.toString().contains('trajectory-row-trajectory:'),
    );
    final rowCountBefore = visibleRows.evaluate().length;
    expect(rowCountBefore, lessThan(5));

    // 切换 mode 清空范围选区。
    await tester.scrollUntilVisible(
      find.byKey(const Key('session-trajectory-mode-toggle')),
      -120,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('session-trajectory-ledger')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(
      find.byKey(const Key('session-trajectory-mode-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-trajectory-range-clear')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-11/P6-B：搜索索引节流保留 streaming partial', (
    tester,
  ) async {
    final items = records(count: 4);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionTrajectoryView(
            records: items,
            inspectTarget: null,
            onInspectConsumed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('session-trajectory-search')),
      -120,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('session-trajectory-ledger')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(
      find.byKey(const Key('session-trajectory-search')),
      '摘要 4',
    );
    // 搜索索引延迟 250ms 后生效；streaming partial 仍在 records 中，应可检索。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('trajectory-row-trajectory:4')),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('session-trajectory-ledger')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.byKey(const Key('trajectory-row-trajectory:4')),
      findsOneWidget,
    );
  });
}