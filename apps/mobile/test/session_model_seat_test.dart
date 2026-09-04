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

  testWidgets('MOBILE-V05-09：多渠道分组目录展示渠道父级与同名模型子项', (tester) async {
    const groups = [
      CapabilityModelGroup(
        id: 'alpha',
        name: 'Alpha Cloud',
        models: [
          CapabilityModelOption(
            provider: 'alpha',
            value: 'dsh:model:alpha:shared',
            id: 'shared',
            name: 'Shared Alpha',
          ),
        ],
      ),
      CapabilityModelGroup(
        id: 'beta',
        name: 'Beta Gateway',
        models: [
          CapabilityModelOption(
            provider: 'beta',
            value: 'dsh:model:beta:shared',
            id: 'shared',
            name: 'Shared Beta',
            contextWindowTokens: 320000,
            reasoning: true,
            efforts: ['high'],
          ),
        ],
      ),
    ];
    final selected = <String>[];
    await tester.pumpWidget(
      _seatApp(
        catalog: SessionModelCatalog(
          model: 'dsh:model:beta:shared',
          effort: null,
          models: const [],
          efforts: const [],
          groups: groups,
        ),
        onSelectModel: (model) async {
          selected.add(model);
          return null;
        },
      ),
    );

    // 当前模型渲染友好名称而不是 opaque value。
    expect(find.text('dsh:model:beta:shared'), findsNothing);
    expect(find.text('Shared Beta'), findsOneWidget);

    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    // 两个渠道父级均显示；同名模型出现在各自渠道下。
    // 弹层打开后，"Shared Beta" 同时出现在单行座与弹层子项中。
    Finder inSheet(Finder finder) => find.descendant(
      of: find.byKey(const Key('session-model-selection-sheet')),
      matching: finder,
    );
    expect(find.text('Alpha Cloud'), findsOneWidget);
    expect(find.text('Beta Gateway'), findsOneWidget);
    expect(inSheet(find.text('Shared Alpha')), findsOneWidget);
    expect(inSheet(find.text('Shared Beta')), findsOneWidget);
    expect(
      find.byKey(const Key('session-model-option-dsh:model:alpha:shared')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('session-model-option-dsh:model:beta:shared')),
      findsOneWidget,
    );

    // 点击子模型提交 ACP 返回的 opaque value（不含渠道名猜测）。
    await tester.tap(
      find.byKey(const Key('session-model-option-dsh:model:alpha:shared')),
    );
    await tester.pumpAndSettle();
    expect(selected, ['dsh:model:alpha:shared']);
    expect(
      find.byKey(const Key('session-model-selection-sheet')),
      findsNothing,
    );
  });

  testWidgets('MOBILE-V05-09：分组目录中的选中态按 opaque value 匹配', (tester) async {
    const groups = [
      CapabilityModelGroup(
        id: 'alpha',
        name: 'Alpha Cloud',
        models: [
          CapabilityModelOption(
            provider: 'alpha',
            value: 'dsh:model:alpha:shared',
            id: 'shared',
            name: 'Shared Alpha',
          ),
        ],
      ),
      CapabilityModelGroup(
        id: 'beta',
        name: 'Beta Gateway',
        models: [
          CapabilityModelOption(
            provider: 'beta',
            value: 'dsh:model:beta:shared',
            id: 'shared',
            name: 'Shared Beta',
          ),
        ],
      ),
    ];
    await tester.pumpWidget(
      _seatApp(
        catalog: SessionModelCatalog(
          model: 'dsh:model:alpha:shared',
          effort: null,
          models: const [],
          efforts: const [],
          groups: groups,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();
    // 只有当前 opaque value 对应项被勾选，同名项不会被误标。
    final alphaIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('session-model-option-dsh:model:alpha:shared')),
        matching: find.byType(Icon),
      ),
    );
    final betaIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('session-model-option-dsh:model:beta:shared')),
        matching: find.byType(Icon),
      ),
    );
    expect(alphaIcon.icon, Icons.check_circle);
    expect(betaIcon.icon, Icons.circle_outlined);

    // 关闭弹层后再开详情；目录统计按分组模型总数展示。
    await tester.tap(find.byKey(const Key('session-model-selection-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('session-model-seat-details')));
    await tester.pumpAndSettle();
    expect(find.textContaining('模型 2 项，推理等级 0 项'), findsOneWidget);
    await tester.tap(find.byKey(const Key('session-model-details-close')));
    await tester.pumpAndSettle();
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

  testWidgets('V086：模型行尾展示当前生效/记忆的推理等级徽标', (tester) async {
    await tester.pumpWidget(
      _seatApp(
        catalog: catalog,
        // fixture-model-b 上次用「高」；记忆里不存在的等级不得展示。
        effortsByModel: const {'fixture-model-b': '高', 'fixture-model-b2': '无'},
      ),
    );
    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();

    // 选中模型展示当前生效等级（effort 列表里也有「中」，因此用 key 精确断言）。
    final activeBadge = tester.widget<Text>(
      find.byKey(const Key('session-model-option-fixture-model-a-effort')),
    );
    expect(activeBadge.data, '中');
    // 其它模型展示记忆的上次等级。
    final rememberedBadge = tester.widget<Text>(
      find.byKey(const Key('session-model-option-fixture-model-b-effort')),
    );
    expect(rememberedBadge.data, '高');
    // 记忆等级不在会话目录中时不展示（目录已变化的模型回退 Host 默认）。
    expect(
      find.byKey(const Key('session-model-option-fixture-model-b2-effort')),
      findsNothing,
    );
  });

  testWidgets('V086：分组目录徽标按模型自有 efforts 校验，无档位模型不显示', (
    tester,
  ) async {
    const groupedCatalog = SessionModelCatalog(
      model: 'gpt-a',
      effort: null,
      models: [],
      efforts: ['low', 'high'],
      groups: [
        CapabilityModelGroup(
          id: 'openai',
          name: 'openai',
          models: [
            CapabilityModelOption(
              provider: 'openai',
              value: 'gpt-a',
              id: 'gpt-a',
              name: 'GPT A',
              efforts: ['low', 'high'],
            ),
            CapabilityModelOption(
              provider: 'openai',
              value: 'gpt-b',
              id: 'gpt-b',
              name: 'GPT B',
              efforts: ['low'],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _seatApp(
        catalog: groupedCatalog,
        // gpt-b 自有目录只有 low：记忆里的 high 不展示，避免误导。
        effortsByModel: const {'gpt-b': 'high'},
      ),
    );
    await tester.tap(find.byKey(const Key('session-model-seat-trigger')));
    await tester.pumpAndSettle();

    // 选中模型 Host 未下发 effort 且该模型确有可选档位 → 展示「默认」。
    final defaultBadge = tester.widget<Text>(
      find.byKey(const Key('session-model-option-gpt-a-effort')),
    );
    expect(defaultBadge.data, '默认');
    // 记忆等级不在该模型自有目录中 → 不展示。
    expect(
      find.byKey(const Key('session-model-option-gpt-b-effort')),
      findsNothing,
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
  Map<String, String> effortsByModel = const {},
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
          effortsByModel: effortsByModel,
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
