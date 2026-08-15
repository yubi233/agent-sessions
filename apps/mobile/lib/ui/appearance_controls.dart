import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../storage/theme_preference_store.dart';

/// P1 在完整设置中心落地前提供轻量本机外观入口，不触碰账户或 Relay 数据。
class AppearanceMenu extends ConsumerWidget {
  const AppearanceMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(themeControllerProvider);
    return PopupMenuButton<_AppearanceAction>(
      key: const Key('appearance-menu-button'),
      tooltip: '外观',
      icon: const Icon(Icons.brightness_6_outlined),
      onSelected: (action) {
        final controller = ref.read(themeControllerProvider);
        switch (action) {
          case _AppearanceAction.system:
            unawaited(controller.setMode(ThemePreferenceMode.system));
          case _AppearanceAction.light:
            unawaited(controller.setMode(ThemePreferenceMode.light));
          case _AppearanceAction.dark:
            unawaited(controller.setMode(ThemePreferenceMode.dark));
          case _AppearanceAction.ocean:
            unawaited(controller.setAccent(AppAccent.ocean));
          case _AppearanceAction.mint:
            unawaited(controller.setAccent(AppAccent.mint));
          case _AppearanceAction.berry:
            unawaited(controller.setAccent(AppAccent.berry));
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<_AppearanceAction>(
          enabled: false,
          child: Text('外观'),
        ),
        _modeItem(
          key: const Key('appearance-mode-system'),
          value: _AppearanceAction.system,
          label: '跟随系统',
          selected: appearance.mode == ThemePreferenceMode.system,
        ),
        _modeItem(
          key: const Key('appearance-mode-light'),
          value: _AppearanceAction.light,
          label: '浅色',
          selected: appearance.mode == ThemePreferenceMode.light,
        ),
        _modeItem(
          key: const Key('appearance-mode-dark'),
          value: _AppearanceAction.dark,
          label: '深色',
          selected: appearance.mode == ThemePreferenceMode.dark,
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<_AppearanceAction>(
          enabled: false,
          child: Text('强调色'),
        ),
        _accentItem(
          key: const Key('appearance-accent-ocean'),
          value: _AppearanceAction.ocean,
          accent: AppAccent.ocean,
          selected: appearance.accent,
        ),
        _accentItem(
          key: const Key('appearance-accent-mint'),
          value: _AppearanceAction.mint,
          accent: AppAccent.mint,
          selected: appearance.accent,
        ),
        _accentItem(
          key: const Key('appearance-accent-berry'),
          value: _AppearanceAction.berry,
          accent: AppAccent.berry,
          selected: appearance.accent,
        ),
        if (appearance.persistenceError != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem<_AppearanceAction>(
            enabled: false,
            child: Text(
              appearance.persistenceError!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }

  CheckedPopupMenuItem<_AppearanceAction> _modeItem({
    required Key key,
    required _AppearanceAction value,
    required String label,
    required bool selected,
  }) => CheckedPopupMenuItem<_AppearanceAction>(
    key: key,
    value: value,
    checked: selected,
    child: Text(label),
  );

  CheckedPopupMenuItem<_AppearanceAction> _accentItem({
    required Key key,
    required _AppearanceAction value,
    required AppAccent accent,
    required AppAccent selected,
  }) => CheckedPopupMenuItem<_AppearanceAction>(
    key: key,
    value: value,
    checked: accent == selected,
    child: Text(accent.label),
  );
}

enum _AppearanceAction { system, light, dark, ocean, mint, berry }
