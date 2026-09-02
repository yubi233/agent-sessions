import 'package:agent_sessions_mobile/domain/control_models.dart';
import 'package:agent_sessions_mobile/ui/session/composer/session_model_seat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模型/推理等级单行状态入口与统一选择弹层的 widget 回归。
void main() {
  const catalog = SessionModelCatalog(
    model: 'fixture-model-a',
    effort: '中',
    models: ['fixture-model-a', 'fixture-model-b'],
    efforts: ['低', '中', '高'],
  );

  testWidgets('MOBILE-V05-09：单行状态入口在同一弹层切换模型和推理等级', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(
      _seatApp(
        catalog: catalog,
        onSelectModel: (model) async {
          selected.add('model:$model');
          return null;
        },
        onSelectEffort: (effort) async {
          selected.add('effort:$effort');
          return null;
        },
      ),
    );

    final trigger = find.byKey(const Key('session-model-seat-trigger'));
    expect(trigger, findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('session-model-seat'))).height,
      32,
    );
    expect(find.text('fixture-model-a'), findsOneWidget);
    expect(find.text('中'), findsOneWidget);

    // 当前模型是 no-op，不提交命令。
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-a')),
    );
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsNothing,
    );

    // 新模型和新推理等级都从同一个弹层提交。
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-b')),
    );
    await tester.pumpAndSettle();
    expect(selected, ['model:fixture-model-b']);

    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-effort-option-高')));
    await tester.pumpAndSettle();
    expect(selected, ['model:fixture-model-b', 'effort:高']);
  });

  testWidgets('MOBILE-V05-09：空目录、阻断原因和长文本不会破坏单行状态区', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _seatApp(
        catalog: const SessionModelCatalog(
          model: 'very-long-fixture-model-name-that-must-remain-on-one-line',
          effort: 'very-long-reasoning-effort-name',
          models: [],
          efforts: [],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final modelText = tester.widget<Text>(
      find.text('very-long-fixture-model-name-that-must-remain-on-one-line'),
    );
    final effortText = tester.widget<Text>(
      find.text('very-long-reasoning-effort-name'),
    );
    expect(modelText.maxLines, 1);
    expect(effortText.maxLines, 1);

    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-model-empty')), findsOneWidget);
    expect(find.byKey(const Key('session-effort-empty')), findsOneWidget);
  });

  testWidgets('MOBILE-V05-09：刷新失败保留目录并可重试', (tester) async {
    var failNextRefresh = true;
    var refreshCount = 0;
    await tester.pumpWidget(
      _seatApp(
        catalog: catalog,
        onRefresh: () async {
          refreshCount += 1;
          return SessionModelCatalogRefresh(
            catalog: catalog,
            error: failNextRefresh ? 'fixture 目录暂时不可用' : null,
          );
        },
      ),
    );

    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    expect(refreshCount, 1);
    expect(
      find.byKey(const Key('session-model-selection-catalog-error')),
      findsOneWidget,
    );
    expect(find.text('fixture 目录暂时不可用'), findsOneWidget);
    expect(
      find.byKey(const Key('session-model-option-fixture-model-a')),
      findsOneWidget,
    );

    failNextRefresh = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(refreshCount, 2);
    expect(
      find.byKey(const Key('session-model-selection-catalog-error')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-09：选择失败保留弹层并可继续重试', (tester) async {
    var failSelection = true;
    final attempts = <String>[];
    await tester.pumpWidget(
      _seatApp(
        catalog: catalog,
        onSelectModel: (model) async {
          attempts.add(model);
          return failSelection ? 'fixture 选择失败，请重试' : null;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-b')),
    );
    await tester.pumpAndSettle();
    expect(attempts, ['fixture-model-b']);
    expect(
      find.byKey(const Key('session-model-selection-error')),
      findsOneWidget,
    );
    expect(find.text('fixture 选择失败，请重试'), findsOneWidget);
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsOneWidget,
    );

    failSelection = false;
    await tester.tap(
      find.byKey(const Key('session-model-option-fixture-model-b')),
    );
    await tester.pumpAndSettle();
    expect(attempts, ['fixture-model-b', 'fixture-model-b']);
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-09：详情弹窗只展示安全摘要并恢复触发器焦点', (tester) async {
    await tester.pumpWidget(
      _seatApp(
        catalog: catalog,
        provider: 'dsh',
        providerVersion: 'v0.0.1',
        modelCapability: const CapabilityEntry(
          name: 'model_select',
          availability: CapabilityAvailability.native,
        ),
        effortCapability: const CapabilityEntry(
          name: 'effort_select',
          availability: CapabilityAvailability.unsupported,
          reason: 'Host 未提供推理等级控制。',
        ),
        effortBlockedReason: 'Host 未提供推理等级控制。',
      ),
    );

    await tester.tap(find.byKey(const Key('session-model-seat-details')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-model-details-dialog')),
      findsOneWidget,
    );
    expect(find.text('dsh'), findsOneWidget);
    expect(find.text('v0.0.1'), findsOneWidget);
    expect(find.text('可用'), findsOneWidget);
    expect(find.textContaining('模型 2 项，推理等级 3 项'), findsOneWidget);
    expect(find.text('effort_select 不可用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-model-details-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session-model-details-dialog')), findsNothing);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('session-model-seat-trigger')))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });

  testWidgets('MOBILE-V05-09：OpenCode 自动推理与上下文窗口显示在模型设置', (tester) async {
    const usage = SessionUsageSummary(
      inputTokens: 11900,
      outputTokens: 111,
      contextTokens: 12011,
      contextWindowTokens: 200000,
    );
    await tester.pumpWidget(
      _seatApp(
        catalog: const SessionModelCatalog(
          model: 'opencode/big-pickle',
          effort: null,
          models: ['opencode/big-pickle'],
          efforts: [],
        ),
        provider: 'opencode',
        modelDetail: const CapabilityModelDetail(
          contextWindowTokens: 200000,
          reasoning: true,
        ),
        usage: usage,
        effortCapability: const CapabilityEntry(
          name: 'effort_select',
          availability: CapabilityAvailability.unsupported,
          reason: 'OpenCode 当前默认模型使用自动推理，未提供可选推理档位。',
        ),
        effortBlockedReason: 'OpenCode 当前默认模型使用自动推理，未提供可选推理档位。',
      ),
    );

    expect(find.text('自动'), findsOneWidget);
    expect(find.text('推理等级不可用'), findsNothing);
    await tester.tap(find.byKey(const Key('session-model-seat-details')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-model-details-dialog')),
      findsOneWidget,
    );
    expect(find.text('自动（模型内置）'), findsOneWidget);
    expect(find.text('effort_select 不可用'), findsOneWidget);
    expect(find.text('用量统计'), findsOneWidget);
    expect(find.textContaining('输入 11.9k'), findsOneWidget);
    expect(find.textContaining('输出 111'), findsOneWidget);
    expect(find.textContaining('上下文 6%'), findsOneWidget);
    expect(find.textContaining('200.0k'), findsOneWidget);
  });

  testWidgets('MOBILE-V05-09：能力均被阻断时不打开选择弹层', (tester) async {
    await tester.pumpWidget(
      _seatApp(
        catalog: catalog,
        modelBlockedReason: '当前设备是只读状态',
        effortBlockedReason: '当前设备是只读状态',
      ),
    );

    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-09：Provider 不可用时入口 fail-closed', (tester) async {
    await tester.pumpWidget(
      _seatApp(catalog: catalog, providerAvailable: false),
    );

    final trigger = tester.widget<InkWell>(
      find.byKey(const Key('session-model-seat-trigger')),
    );
    expect(trigger.onTap, isNull);
    expect(trigger.canRequestFocus, isFalse);
    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-09：Escape 关闭选择弹层并恢复触发器焦点', (tester) async {
    await tester.pumpWidget(_seatApp(catalog: catalog));
    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsNothing,
    );
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('session-model-seat-trigger')))
          .focusNode
          ?.hasFocus,
      isTrue,
    );
  });
}

Widget _seatApp({
  required SessionModelCatalog catalog,
  String? provider,
  String? providerVersion,
  bool providerAvailable = true,
  CapabilityEntry modelCapability = const CapabilityEntry(
    name: 'model_select',
    availability: CapabilityAvailability.native,
  ),
  CapabilityEntry effortCapability = const CapabilityEntry(
    name: 'effort_select',
    availability: CapabilityAvailability.native,
  ),
  String? modelBlockedReason,
  String? effortBlockedReason,
  SessionUsageSummary? usage,
  CapabilityModelDetail? modelDetail,
  Future<SessionModelCatalogRefresh> Function()? onRefresh,
  Future<String?> Function(String model)? onSelectModel,
  Future<String?> Function(String effort)? onSelectEffort,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SessionModelSeat(
          provider: provider,
          providerVersion: providerVersion,
          providerAvailable: providerAvailable,
          catalog: catalog,
          modelCapability: modelCapability,
          effortCapability: effortCapability,
          modelBlockedReason: modelBlockedReason,
          effortBlockedReason: effortBlockedReason,
          modelDetail: modelDetail,
          usage: usage,
          onRefresh:
              onRefresh ??
              () async => SessionModelCatalogRefresh(catalog: catalog),
          onSelectModel: onSelectModel ?? (_) async => null,
          onSelectEffort: onSelectEffort ?? (_) async => null,
        ),
      ),
    ),
  );
}
