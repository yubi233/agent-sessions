import 'package:agent_sessions_mobile/state/session_composer_controller.dart';
import 'package:agent_sessions_mobile/ui/session/composer/session_queue_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.5/P5：QueueDock 交互回归（对应《迭代计划v0.5.md》MOBILE-V05-07）。
///
/// 主流程侧的多队列折叠/展开、编辑/steer/失败 notice 由
/// `session_screens_test.dart` 的「MOBILE-V05-07/P5-A」系列覆盖；本文件直接以
/// `SessionQueueDock` 组件注入构造数据，覆盖主流程当前尚不产生、但契约必须
/// fail-closed 的「非文本/不可变队列项」只读形态：
/// - 非文本项编辑按钮禁用，并展示可见的禁用原因；
/// - 不可变项不渲染可误触的 steer 动作；
/// - 可编辑文本项仍提供 edit + steer 动作。
void main() {
  testWidgets('MOBILE-V05-07/P5-A：非文本/不可变队列项禁用编辑并展示原因、不渲染 steer', (
    tester,
  ) async {
    final items = <QueuedComposerMessage>[
      const QueuedComposerMessage(id: 'text-1', text: '可编辑文本'),
      const QueuedComposerMessage(
        id: 'img-1',
        text: '[图片单元测试]',
        editable: false,
        steerable: false,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionQueueDock(
            messages: items,
            onRemove: (_) {},
            onEdit: (_, _) {},
            onSteer: (_) {},
            onSendAll: () {},
            running: false,
          ),
        ),
      ),
    );
    await tester.pump();

    // 2 项且非 busy：首尾两项都可见（首=text-1、尾=img-1），不出现「还有 N 条」。
    expect(find.text('可编辑文本'), findsOneWidget);
    expect(find.text('[图片单元测试]'), findsOneWidget);
    expect(find.textContaining('未显示'), findsNothing);

    // 非文本/不可变项：编辑按钮禁用，并显示禁用原因文案。
    expect(
      find.byKey(const Key('session-queue-edit-blocked-img-1')),
      findsOneWidget,
    );
    final blockedEdit = tester.widget<IconButton>(
      find.byKey(const Key('session-queue-edit-img-1')),
    );
    expect(blockedEdit.onPressed, isNull);

    // 不可变项不渲染可误触的 steer 动作；可编辑文本项仍提供 steer。
    expect(find.byKey(const Key('session-queue-steer-img-1')), findsNothing);
    expect(find.byKey(const Key('session-queue-steer-text-1')), findsOneWidget);

    // 点击禁用的编辑按钮不会进入编辑态。
    await tester.tap(
      find.byKey(const Key('session-queue-edit-img-1')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(
      find.byKey(const Key('session-queue-edit-input-img-1')),
      findsNothing,
    );
  });
}
