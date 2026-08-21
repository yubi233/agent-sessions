import 'package:agent_sessions_mobile/ui/session/composer/session_model_seat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.5/P5-E5：模型/effort 两级菜单的本地 widget 回归。
///
/// 这里直接注入 `SessionModelSeat` 的目录与回调，覆盖：
/// - root 到 model / effort 二级 pane 导航；
/// - 空目录空态；
/// - 目录加载失败与重试；
/// - 当前值 no-op 不写命令；
/// - Escape 在二级 pane 先返回 root 再关闭；
/// - 选择失败在菜单内 re-arm，不丢失 pane。
void main() {
  testWidgets('MOBILE-V05-09/P5-E5：两级菜单导航、当前值 no-op、选择写回调', (
    tester,
  ) async {
    final selected = <String>[];
    Future<String?> onSelectModel(String model) async {
      selected.add('model:$model');
      return null;
    }
    Future<String?> onSelectEffort(String effort) async {
      selected.add('effort:$effort');
      return null;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionModelSeat(
            model: 'fixture-model-a',
            effort: '中',
            models: const ['fixture-model-a', 'fixture-model-b'],
            efforts: const ['低', '中', '高'],
            modelBlockedReason: null,
            effortBlockedReason: null,
            busy: false,
            onRefresh: () async => null,
            onSelectModel: onSelectModel,
            onSelectEffort: onSelectEffort,
          ),
        ),
      ),
    );

    // 打开 root：出现模型与 effort 两个入口。
    await tester.tap(find.byKey(const Key('composer-model-select')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-model-pane-root')), findsOneWidget);
    expect(find.byKey(const Key('session-model-menu-model')), findsOneWidget);
    expect(find.byKey(const Key('session-model-menu-effort')), findsOneWidget);

    // 进入模型 pane，点当前模型是 no-op：不回调且关闭菜单。
    await tester.tap(find.byKey(const Key('session-model-menu-model')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-a')),
    );
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.byKey(const Key('session-model-menu')), findsNothing);

    // 重新打开并选择新模型：写回调并关闭。
    await tester.tap(find.byKey(const Key('composer-model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-menu-model')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-b')),
    );
    await tester.pumpAndSettle();
    expect(selected, ['model:fixture-model-b']);
    expect(find.byKey(const Key('session-model-menu')), findsNothing);

    // effort 同样先进入二级 pane，当前值 no-op，新值写回调。
    await tester.tap(find.byKey(const Key('composer-effort-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-menu-effort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-effort-option-中')));
    await tester.pumpAndSettle();
    expect(selected, ['model:fixture-model-b']);
    expect(find.byKey(const Key('session-model-menu')), findsNothing);

    await tester.tap(find.byKey(const Key('composer-effort-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-menu-effort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-effort-option-高')));
    await tester.pumpAndSettle();
    expect(selected, ['model:fixture-model-b', 'effort:高']);
  });

  testWidgets('MOBILE-V05-09/P5-E5：模型/effort 空目录显示空态，不渲染可点选项', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionModelSeat(
            model: null,
            effort: null,
            models: const [],
            efforts: const [],
            modelBlockedReason: null,
            effortBlockedReason: null,
            busy: false,
            onRefresh: () async => null,
            onSelectModel: (_) async => null,
            onSelectEffort: (_) async => null,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('composer-model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-menu-model')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-model-empty')), findsOneWidget);
    expect(find.byKey(const Key('session-model-option-')), findsNothing);

    await tester.tap(find.byKey(const Key('session-model-menu-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-effort-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-menu-effort')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-effort-empty')), findsOneWidget);
  });

  testWidgets('MOBILE-V05-09/P5-E5：目录加载失败显示错误并可重试', (tester) async {
    var failNextRefresh = true;
    var refreshCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionModelSeat(
            model: null,
            effort: null,
            models: const ['fixture-model-a'],
            efforts: const ['低'],
            modelBlockedReason: null,
            effortBlockedReason: null,
            busy: false,
            onRefresh: () async {
              refreshCount += 1;
              return failNextRefresh ? 'fixture 目录暂时不可用' : null;
            },
            onSelectModel: (_) async => null,
            onSelectEffort: (_) async => null,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('composer-model-select')));
    await tester.pumpAndSettle();
    expect(refreshCount, 1);
    expect(
      find.byKey(const Key('session-model-menu-error')),
      findsOneWidget,
    );
    expect(find.text('fixture 目录暂时不可用'), findsOneWidget);

    failNextRefresh = false;
    await tester.tap(find.byKey(const Key('session-model-menu-retry')));
    await tester.pumpAndSettle();
    expect(refreshCount, 2);
    expect(find.byKey(const Key('session-model-menu-error')), findsNothing);
    expect(find.byKey(const Key('session-model-pane-root')), findsOneWidget);
  });

  testWidgets('MOBILE-V05-09/P5-E5：Escape 在二级 pane 先返回 root 再关闭', (
    tester,
  ) async {
    final focusRequests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionModelSeat(
            model: 'fixture-model-a',
            effort: '低',
            models: const ['fixture-model-a'],
            efforts: const ['低'],
            modelBlockedReason: null,
            effortBlockedReason: null,
            busy: false,
            onRefresh: () async => null,
            onSelectModel: (model) async {
              focusRequests.add(model);
              return null;
            },
            onSelectEffort: (_) async => null,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('composer-model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-menu-model')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-model-pane-model')), findsOneWidget);

    // 第一次 Escape：从模型 pane 返回 root，不关闭菜单。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-model-pane-root')), findsOneWidget);
    expect(find.byKey(const Key('session-model-menu')), findsOneWidget);

    // 第二次 Escape：关闭整个菜单。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-model-menu')), findsNothing);
    expect(focusRequests, isEmpty);
  });

  testWidgets('MOBILE-V05-09/P5-E5：选择失败提示并保留 pane，可继续重试', (
    tester,
  ) async {
    var failSelection = true;
    final attempts = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionModelSeat(
            model: 'fixture-model-a',
            effort: null,
            models: const ['fixture-model-a', 'fixture-model-b'],
            efforts: const ['低'],
            modelBlockedReason: null,
            effortBlockedReason: null,
            busy: false,
            onRefresh: () async => null,
            onSelectModel: (model) async {
              attempts.add(model);
              return failSelection ? 'fixture 选择失败，请重试' : null;
            },
            onSelectEffort: (_) async => null,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('composer-model-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-menu-model')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-b')),
    );
    await tester.pumpAndSettle();

    // 失败：菜单保持打开，显示错误 notice，pane 未退出。
    expect(attempts, ['fixture-model-b']);
    expect(
      find.byKey(const Key('session-model-selection-notice')),
      findsOneWidget,
    );
    expect(find.text('fixture 选择失败，请重试'), findsOneWidget);
    expect(find.byKey(const Key('session-model-pane-model')), findsOneWidget);

    // 重试成功：写回调、关闭菜单。
    failSelection = false;
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-b')),
    );
    await tester.pumpAndSettle();
    expect(attempts, ['fixture-model-b', 'fixture-model-b']);
    expect(find.byKey(const Key('session-model-menu')), findsNothing);
  });
}