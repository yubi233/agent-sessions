import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app/providers.dart';
import '../domain/composer_preferences.dart';
import '../domain/control_models.dart';
import '../state/app_controller.dart';
import '../state/settings_controller.dart';
import '../storage/theme_preference_store.dart';
import 'app_theme.dart';

/// P3 设置中心索引页：只列可兑现的分区，不出现空入口。
/// 各分区只读展示白名单状态；token、恢复码明文与写控制不在此处暴露。
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return Scaffold(
      key: const Key('settings-screen'),
      appBar: AppBar(
        title: const Text('设置'),
        leading: IconButton(
          key: const Key('settings-back-button'),
          tooltip: '返回',
          onPressed: () => context.go('/home'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _SettingsBody(controller: settings),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsBody extends ConsumerWidget {
  const _SettingsBody({required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (controller.phase == SettingsSectionPhase.loading) {
      return const Center(
        key: Key('settings-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (controller.phase == SettingsSectionPhase.error) {
      return _SettingsError(
        message: controller.errorMessage ?? '设置数据暂时不可用。',
        onRetry: controller.refresh,
      );
    }
    final app = ref.watch(appControllerProvider);
    return ListView(
      key: const Key('settings-section-list'),
      children: [
        _SettingsSectionTile(
          key: const Key('settings-account-tile'),
          icon: Icons.person_outline,
          title: '账户',
          subtitle: _accountSubtitle(app),
          onTap: () => context.push('/settings/account'),
        ),
        _SettingsSectionTile(
          key: const Key('settings-appearance-tile'),
          icon: Icons.brightness_6_outlined,
          title: '外观',
          subtitle: '主题模式与强调色',
          onTap: () => context.push('/settings/appearance'),
        ),
        _SettingsSectionTile(
          key: const Key('settings-composer-tile'),
          icon: Icons.keyboard_outlined,
          title: '输入',
          subtitle: 'busy Enter 行为：排队或插话',
          onTap: () => context.push('/settings/composer'),
        ),
        _SettingsSectionTile(
          key: const Key('settings-agents-tile'),
          icon: Icons.memory_outlined,
          title: 'Agent 能力',
          subtitle: _agentsSubtitle(controller),
          onTap: () => context.push('/settings/agents'),
        ),
        _SettingsSectionTile(
          key: const Key('settings-usage-tile'),
          icon: Icons.bar_chart_outlined,
          title: '用量',
          subtitle: '今日、7 天与 30 天统计',
          onTap: () => context.push('/usage'),
        ),
        _SettingsSectionTile(
          key: const Key('settings-connect-tile'),
          icon: Icons.link_outlined,
          title: '连接',
          subtitle: _connectSubtitle(controller),
          onTap: () => context.push('/settings/connect'),
        ),
      ],
    );
  }

  String _accountSubtitle(AppController app) {
    if (app.hasOwner) return '已确认 owner 设备';
    if (app.devices.isEmpty) return '尚无设备';
    return '${app.devices.length} 台设备';
  }

  String _agentsSubtitle(SettingsController controller) {
    final providers = controller.capabilities.providers;
    if (providers.isEmpty) return '尚未读取 Provider 能力';
    final available = providers.where((profile) => profile.available).length;
    return '$available/${providers.length} 个 Provider 可用';
  }

  String _connectSubtitle(SettingsController controller) {
    final terminals = controller.terminals;
    if (terminals.isEmpty) return '尚无已确认的终端';
    return '${terminals.length} 台终端';
  }
}

/// 设置索引页的分区入口，遵循最小 48 高度与语义标签。
class _SettingsSectionTile extends StatelessWidget {
  const _SettingsSectionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: title,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minVerticalPadding: 12,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class _SettingsError extends StatelessWidget {
  const _SettingsError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    key: const Key('settings-error'),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 32),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          IconButton(
            key: const Key('settings-retry-button'),
            tooltip: '重试读取设置',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ),
  );
}

/// 账户分区：只读展示当前设备与已确认设备，不显示 token 或恢复码明文。
class SettingsAccountScreen extends ConsumerWidget {
  const SettingsAccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final devices = app.devices;
    return Scaffold(
      key: const Key('settings-account-screen'),
      appBar: AppBar(
        title: const Text('账户'),
        leading: IconButton(
          tooltip: '返回设置',
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              key: const Key('settings-account-list'),
              padding: const EdgeInsets.all(16),
              children: [
                Text('本机设备', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (devices.isEmpty)
                  const _SettingsEmptyHint(
                    key: Key('settings-account-empty'),
                    message: '尚未确认任何设备。',
                  )
                else
                  for (final device in devices)
                    ListTile(
                      key: Key('settings-account-device-${device.id}'),
                      dense: true,
                      leading: Icon(
                        device.isOwner
                            ? Icons.admin_panel_settings_outlined
                            : Icons.devices_other_outlined,
                      ),
                      title: Text(device.displayName),
                      subtitle: Text(device.isOwner ? 'owner 设备' : '已确认设备'),
                    ),
                const SizedBox(height: 16),
                const _SettingsBoundaryNote(
                  key: Key('settings-account-note'),
                  message: '恢复码与 token 不会在此页面显示。设备撤销请在认证页操作。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 外观分区：复用 P1 主题控制器，偏好仅本机持久化。
class SettingsAppearanceScreen extends ConsumerWidget {
  const SettingsAppearanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      key: const Key('settings-appearance-screen'),
      appBar: AppBar(
        title: const Text('外观'),
        leading: IconButton(
          tooltip: '返回设置',
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              key: const Key('settings-appearance-list'),
              padding: const EdgeInsets.all(16),
              children: [
                // 分组标题统一走 titleSmall 文本角色（16/w600），不再 ad-hoc。
                Text('主题模式', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                const _AppearanceModeSelector(),
                const SizedBox(height: 24),
                Text('强调色', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                const _AppearanceAccentSelector(),
                const SizedBox(height: 16),
                const _SettingsBoundaryNote(
                  key: Key('settings-appearance-note'),
                  message: '外观偏好只保存在本机，不会上传到 Relay。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppearanceModeSelector extends ConsumerWidget {
  const _AppearanceModeSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    return SegmentedButton<ThemePreferenceMode>(
      key: const Key('settings-appearance-mode'),
      segments: const [
        ButtonSegment(value: ThemePreferenceMode.system, label: Text('跟随系统')),
        ButtonSegment(value: ThemePreferenceMode.light, label: Text('浅色')),
        ButtonSegment(value: ThemePreferenceMode.dark, label: Text('深色')),
      ],
      selected: {theme.mode},
      onSelectionChanged: (selection) =>
          ref.read(themeControllerProvider).setMode(selection.first),
    );
  }
}

class _AppearanceAccentSelector extends ConsumerWidget {
  const _AppearanceAccentSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeControllerProvider);
    return Wrap(
      spacing: 8,
      children: [
        for (final accent in AppAccent.values)
          ChoiceChip(
            key: Key('settings-appearance-accent-${accent.name}'),
            label: Text(accent.label),
            selected: theme.accent == accent,
            onSelected: (_) =>
                ref.read(themeControllerProvider).setAccent(accent),
          ),
      ],
    );
  }
}

/// Agent 能力分区：只读展示 Provider 能力三态，与能力矩阵页同源。
class SettingsComposerScreen extends ConsumerWidget {
  const SettingsComposerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      key: const Key('settings-composer-screen'),
      appBar: AppBar(
        title: const Text('输入'),
        leading: IconButton(
          tooltip: '返回设置',
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              key: const Key('settings-composer-list'),
              padding: const EdgeInsets.all(16),
              children: [
                // 分组标题统一走 titleSmall 文本角色（16/w600），不再 ad-hoc。
                Text(
                  'busy Enter 行为',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                const _ComposerEnterBehaviorSelector(),
                const SizedBox(height: 16),
                const _SettingsBoundaryNote(
                  key: Key('settings-composer-note'),
                  message:
                      '会话生成中按 Enter：排队先把消息收进本地队列，插话则直接发送。Shift+Enter 永远换行，Cmd/Ctrl+Enter 用于显式全部插话。该偏好只保存在本机。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerEnterBehaviorSelector extends ConsumerWidget {
  const _ComposerEnterBehaviorSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(composerPreferenceControllerProvider);
    return SegmentedButton<ComposerEnterBehavior>(
      key: const Key('settings-composer-enter-behavior'),
      segments: const [
        ButtonSegment(value: ComposerEnterBehavior.queue, label: Text('排队')),
        ButtonSegment(value: ComposerEnterBehavior.steer, label: Text('插话')),
      ],
      selected: {preference.enterBehavior},
      onSelectionChanged: (selection) => ref
          .read(composerPreferenceControllerProvider)
          .setEnterBehavior(selection.first),
    );
  }
}

class SettingsAgentsScreen extends ConsumerWidget {
  const SettingsAgentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final providers = settings.capabilities.providers;
    return Scaffold(
      key: const Key('settings-agents-screen'),
      appBar: AppBar(
        title: const Text('Agent 能力'),
        leading: IconButton(
          tooltip: '返回设置',
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              key: const Key('settings-agents-list'),
              padding: const EdgeInsets.all(16),
              children: [
                if (providers.isEmpty)
                  const _SettingsEmptyHint(
                    key: Key('settings-agents-empty'),
                    message: '尚未读取 Provider 能力。',
                  )
                else
                  for (final profile in providers)
                    _ProviderCapabilityCard(profile: profile),
                const SizedBox(height: 16),
                const _SettingsBoundaryNote(
                  key: Key('settings-agents-note'),
                  message: '能力状态来自 Relay 声明，未声明或探测失败的能力一律按不可用处理。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderCapabilityCard extends StatelessWidget {
  const _ProviderCapabilityCard({required this.profile});

  final ProviderCapabilityProfile profile;

  @override
  Widget build(BuildContext context) {
    final availability = profile.available ? '可用' : '不可用';
    return Container(
      key: Key('settings-agents-provider-${profile.kind}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.appColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  profile.kind,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                availability,
                key: Key('settings-provider-status-${profile.kind}'),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: profile.available
                      ? context.appColors.success
                      : context.appColors.neutral,
                ),
              ),
            ],
          ),
          if (profile.version.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '版本 ${profile.version}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in profile.capabilities)
                Tooltip(
                  message: _capabilityTooltip(entry),
                  child: Chip(
                    key: Key(
                      'settings-capability-${profile.kind}-${entry.name}',
                    ),
                    avatar: Icon(_capabilityIcon(entry), size: 16),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(entry.name),
                        const SizedBox(width: 4),
                        Text(_capabilityLabel(entry)),
                      ],
                    ),
                    labelStyle: Theme.of(context).textTheme.labelSmall,
                    visualDensity: VisualDensity.compact,
                    backgroundColor: _capabilityChipColor(context, entry),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // 能力三态必须同时使用图标、文字和颜色，避免色觉差异导致写能力误判。
  String _capabilityLabel(CapabilityEntry entry) =>
      switch (entry.availability) {
        CapabilityAvailability.native => '原生',
        CapabilityAvailability.emulated => '兼容',
        CapabilityAvailability.unsupported => '不可用',
      };

  IconData _capabilityIcon(CapabilityEntry entry) =>
      switch (entry.availability) {
        CapabilityAvailability.native => Icons.check_circle_outline,
        CapabilityAvailability.emulated => Icons.sync_alt,
        CapabilityAvailability.unsupported => Icons.block_outlined,
      };

  String _capabilityTooltip(CapabilityEntry entry) {
    final state = _capabilityLabel(entry);
    final reason = entry.reason;
    return reason == null
        ? '${entry.name}：$state'
        : '${entry.name}：$state；$reason';
  }

  Color? _capabilityChipColor(BuildContext context, CapabilityEntry entry) {
    final colors = context.appColors;
    return switch (entry.availability) {
      CapabilityAvailability.native => colors.success.withValues(alpha: 0.12),
      CapabilityAvailability.emulated => colors.warning.withValues(alpha: 0.12),
      // 第三态不再裸奔 M3 默认底：用抬升面同族浅色，保持三态同一视觉语言。
      CapabilityAvailability.unsupported => colors.surfaceRaised,
    };
  }
}

/// 用量分区：ADR-010 服务端聚合契约落地前明确显示不可用，不伪造统计数字。
class SettingsUsageScreen extends ConsumerWidget {
  const SettingsUsageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      key: const Key('settings-usage-screen'),
      appBar: AppBar(
        title: const Text('用量'),
        leading: IconButton(
          tooltip: '返回设置',
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              key: const Key('settings-usage-list'),
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  key: const Key('settings-usage-unavailable'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: context.appColors.surfaceRaised,
                    border: Border.all(color: context.appColors.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '用量统计暂不可用。它需要 Daemon 上报白名单计数并经 Relay 聚合（ADR-010）后才会展示，当前不会显示估算值。',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 连接分区：只读终端状态 + 配对入口导航，不在此页复制任何数据。
class SettingsConnectScreen extends ConsumerWidget {
  const SettingsConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final terminals = settings.terminals;
    return Scaffold(
      key: const Key('settings-connect-screen'),
      appBar: AppBar(
        title: const Text('连接'),
        leading: IconButton(
          tooltip: '返回设置',
          onPressed: () => context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              key: const Key('settings-connect-list'),
              padding: const EdgeInsets.all(16),
              children: [
                Text('已确认终端', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (terminals.isEmpty)
                  const _SettingsEmptyHint(
                    key: Key('settings-connect-empty'),
                    message: '尚无已确认的终端。',
                  )
                else
                  for (var index = 0; index < terminals.length; index += 1)
                    ListTile(
                      key: Key('settings-connect-terminal-$index'),
                      dense: true,
                      leading: const Icon(Icons.computer_outlined),
                      title: Text(terminals[index].hostname),
                      subtitle: Text(
                        '${terminals[index].platform} · Daemon ${terminals[index].daemonVersion ?? '版本未知'}',
                      ),
                    ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('settings-connect-pairing-button'),
                  onPressed: () => context.push('/pairing'),
                  icon: const Icon(Icons.qr_code_scanner_outlined),
                  label: const Text('配对新终端'),
                ),
                const SizedBox(height: 8),
                const _SettingsBoundaryNote(
                  key: Key('settings-connect-note'),
                  message: '终端重启与工作区关联需要后续受控 Daemon 契约，当前不可用。',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsEmptyHint extends StatelessWidget {
  const _SettingsEmptyHint({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Center(
      // 与全局空状态同节奏：icon32 + caption，保留原 message 文案。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 32,
            color: context.appColors.textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _SettingsBoundaryNote extends StatelessWidget {
  const _SettingsBoundaryNote({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.appColors.surfaceRaised,
      border: Border.all(color: context.appColors.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );
}
