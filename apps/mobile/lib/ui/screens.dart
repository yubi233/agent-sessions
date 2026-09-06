import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/providers.dart';
import '../domain/models.dart';
import '../state/app_controller.dart';
import 'appearance_controls.dart';
import 'app_theme.dart';

class ConnectDeviceScreen extends ConsumerStatefulWidget {
  const ConnectDeviceScreen({super.key});

  @override
  ConsumerState<ConnectDeviceScreen> createState() =>
      _ConnectDeviceScreenState();
}

class _ConnectDeviceScreenState extends ConsumerState<ConnectDeviceScreen> {
  final _displayNameController = TextEditingController(text: '此 Android 控制端');

  @override
  void dispose() {
    _displayNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    if (app.phase == AppAuthPhase.booting) {
      return const _StatusScaffold(
        title: 'Agent Sessions',
        child: Center(
          child: CircularProgressIndicator(key: Key('app-bootstrap-progress')),
        ),
      );
    }
    return _StatusScaffold(
      title: '连接设备',
      errorMessage: app.errorMessage,
      child: _ScrollableCenter(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _AuthMark(),
              const SizedBox(height: AppSpacing.xxl),
              Text(
                '连接此 Android 控制端',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpacing.md),
              const Text(
                '无需账号登录。此设备会在本机安全存储中生成设备身份，并向 Relay 注册为首个 owner 或通过恢复码接管。',
              ),
              const SizedBox(height: AppSpacing.xl),
              TextField(
                key: const Key('device-display-name'),
                controller: _displayNameController,
                decoration: const InputDecoration(labelText: '设备名称'),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _connect(app),
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                key: const Key('device-connect-submit'),
                onPressed: app.isBusy ? null : () => _connect(app),
                icon: const Icon(Icons.phonelink_lock_outlined),
                label: app.isBusy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('初始化此设备'),
              ),
              TextButton.icon(
                key: const Key('recovery-link'),
                onPressed: app.isBusy ? null : () => context.go('/recovery'),
                icon: const Icon(Icons.key_outlined),
                label: const Text('使用恢复码接管'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _connect(AppController app) =>
      app.connectThisDevice(displayName: _displayNameController.text);
}

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _displayNameController = TextEditingController(text: '恢复的 Android 控制端');
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _displayNameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    return _StatusScaffold(
      title: '恢复设备',
      errorMessage: app.errorMessage,
      child: _ScrollableCenter(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _AuthMark(),
                const SizedBox(height: AppSpacing.xxl),
                Text(
                  '恢复此 Android 控制端',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.md),
                const Text('输入 owner 设备生成的一次性恢复码。这里不需要账号、邮箱或密码。'),
                const SizedBox(height: AppSpacing.xl),
                TextFormField(
                  key: const Key('recovery-display-name'),
                  controller: _displayNameController,
                  decoration: const InputDecoration(labelText: '设备名称'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  key: const Key('recovery-code'),
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: '恢复码'),
                  validator: (value) => value != null && value.trim().isNotEmpty
                      ? null
                      : '请输入恢复码。',
                  onFieldSubmitted: (_) => _recover(app),
                ),
                const SizedBox(height: AppSpacing.xl),
                FilledButton.icon(
                  key: const Key('recovery-submit'),
                  onPressed: app.isBusy ? null : () => _recover(app),
                  icon: const Icon(Icons.restore_outlined),
                  label: const Text('恢复'),
                ),
                TextButton.icon(
                  onPressed: () => context.go('/connect'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回连接设备'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _recover(AppController app) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await app.restoreWithRecoveryCode(
      _codeController.text,
      displayName: _displayNameController.text,
    );
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    return _StatusScaffold(
      title: 'Agent Sessions',
      errorMessage: app.errorMessage,
      actions: [
        IconButton(
          key: const Key('signout-button'),
          tooltip: '断开此设备',
          onPressed: app.isBusy ? null : app.signOut,
          icon: const Icon(Icons.logout),
        ),
      ],
      child: ListView(
        key: const Key('mobile-home-scroll'),
        children: [
          const _MobileSectionHeading('控制端'),
          Container(
            key: const Key('mobile-control-status'),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: app.requiresRecovery
                ? const ListTile(
                    key: Key('identity-recovery-required-state'),
                    leading: Icon(Icons.key_off_outlined),
                    title: Text('需要恢复本机身份'),
                  )
                : app.needsOwnerBootstrap
                ? _OwnerBootstrapPanel(app: app)
                : app.canManageDevices
                ? const ListTile(
                    key: Key('owner-ready-state'),
                    leading: Icon(Icons.verified_user_outlined),
                    title: Text('Owner 设备已连接'),
                    subtitle: Text('此 Android 可批准配对并控制会话。'),
                  )
                : app.hasOwner
                ? const ListTile(
                    key: Key('readonly-auth-state'),
                    leading: Icon(Icons.lock_outline),
                    title: Text('当前设备没有 Android 写权限'),
                    subtitle: Text('使用恢复码接管此设备。'),
                  )
                : const ListTile(
                    key: Key('unprovisioned-auth-state'),
                    leading: Icon(Icons.info_outline),
                    title: Text('尚未连接 Android owner'),
                    subtitle: Text('初始化此设备或使用恢复码接管。'),
                  ),
          ),
          const _MobileSectionHeading('安全与设备'),
          ListTile(
            key: const Key('recovery-code-page-link'),
            enabled: app.canManageDevices && !app.isBusy,
            leading: const Icon(Icons.password_outlined),
            title: const Text('恢复码'),
            trailing: const Icon(Icons.chevron_right),
            onTap: app.canManageDevices && !app.isBusy
                ? () => context.go('/recovery-code')
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('pairing-page-link'),
            enabled: app.canManageDevices && !app.isBusy,
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('二维码配对'),
            trailing: const Icon(Icons.chevron_right),
            onTap: app.canManageDevices && !app.isBusy
                ? () => context.go('/pairing')
                : null,
          ),
          const Divider(height: 1),
          ListTile(
            key: const Key('devices-page-link'),
            enabled: app.canManageDevices && !app.isBusy,
            leading: const Icon(Icons.devices_other_outlined),
            title: const Text('设备管理'),
            trailing: Text('${app.devices.length}'),
            onTap: app.canManageDevices && !app.isBusy
                ? () => context.go('/devices')
                : null,
          ),
          if (app.requiresRecovery) ...[
            const Divider(height: 1),
            ListTile(
              key: const Key('identity-recovery-page-link'),
              leading: const Icon(Icons.restore_outlined),
              title: const Text('使用恢复码'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.go('/recovery'),
            ),
          ],
        ],
      ),
    );
  }
}

class _OwnerBootstrapPanel extends StatelessWidget {
  const _OwnerBootstrapPanel({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.admin_panel_settings_outlined),
    title: const Text('完成此设备的 owner 安全初始化'),
    subtitle: const Text('Relay 已建立 owner 绑定，等待写入此设备公钥。'),
    trailing: FilledButton.icon(
      key: const Key('owner-bootstrap-button'),
      onPressed: app.isBusy ? null : app.bootstrapOwner,
      icon: const Icon(Icons.verified_user_outlined),
      label: const Text('建立'),
    ),
  );
}

/// owner 生成的恢复码仅在此页内存态展示；离开或确认后立即从 controller 清除。
class RecoveryCodeScreen extends ConsumerWidget {
  const RecoveryCodeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    final code = app.recoveryCode;
    return _StatusScaffold(
      title: '恢复码',
      errorMessage: app.errorMessage,
      leading: IconButton(
        key: const Key('recovery-code-back-button'),
        tooltip: '返回控制端',
        onPressed: () {
          app.dismissRecoveryCode();
          context.go('/home');
        },
        icon: const Icon(Icons.arrow_back),
      ),
      child: _ScrollableCenter(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: code == null
              ? FilledButton.icon(
                  key: const Key('recovery-code-generate-button'),
                  onPressed: app.canManageDevices && !app.isBusy
                      ? app.generateRecoveryCode
                      : null,
                  icon: const Icon(Icons.key_outlined),
                  label: const Text('生成恢复码'),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      label: '一次性恢复码',
                      child: Container(
                        key: const Key('recovery-code-value'),
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        child: SelectableText(
                          code,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      key: const Key('recovery-code-dismiss-button'),
                      onPressed: () {
                        app.dismissRecoveryCode();
                        context.go('/home');
                      },
                      child: const Text('已保存'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final _requestIdController = TextEditingController();

  @override
  void dispose() {
    _requestIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    return _StatusScaffold(
      title: '二维码配对',
      errorMessage: app.errorMessage,
      leading: IconButton(
        key: const Key('back-home-button'),
        tooltip: '返回控制端',
        onPressed: () => context.go('/home'),
        icon: const Icon(Icons.arrow_back),
      ),
      child: ListView(
        children: [
          OutlinedButton.icon(
            key: const Key('pairing-scan-open-button'),
            onPressed: app.isBusy ? null : () => _openScanner(app),
            icon: const Icon(Icons.photo_camera_back_outlined),
            label: const Text('打开相机扫码'),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const Key('pairing-request-id'),
            controller: _requestIdController,
            decoration: const InputDecoration(labelText: '扫描结果或配对请求 ID'),
            onSubmitted: (_) => _load(app),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            key: const Key('pairing-load-button'),
            onPressed: app.isBusy ? null : () => _load(app),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('读取配对请求'),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Text('待处理请求', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (app.pairings.isEmpty) const _EmptyState(text: '尚未读取配对请求。'),
          for (final request in app.pairings)
            _PairingRequestTile(request: request, app: app),
        ],
      ),
    );
  }

  Future<void> _load(AppController app) =>
      app.loadPairingRequest(_requestIdController.text);

  Future<void> _openScanner(AppController app) async {
    final requestId = await context.push<String>('/pairing/scan');
    if (!mounted || requestId == null) {
      return;
    }
    // 回填完整 payload，保留用户可见的配对来源，同时复用同一读取与授权链路。
    _requestIdController.text = PairingPayload.encode(requestId);
    await _load(app);
  }
}

class _PairingRequestTile extends StatelessWidget {
  const _PairingRequestTile({required this.request, required this.app});

  final PairingRequest request;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final canDecide = request.status == PairingStatus.pending && !app.isBusy;
    final payload = PairingPayload.encode(request.id);
    return Container(
      key: Key('pairing-request-${request.id}'),
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.qr_code_2),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.displayName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.micro),
                    Text(
                      '${request.role.wireValue} · ${request.status.wireValue}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // QR 与可复制 payload 绑定同一请求 ID；手动输入是无相机设备的等价路径。
              QrImageView(
                data: payload,
                size: AppSizes.qrImage,
                key: Key('pairing-qr-image-${request.id}'),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '短码：${PairingPayload.shortCode(request.id)}',
                      key: Key('pairing-short-code-${request.id}'),
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    SelectableText(
                      payload,
                      key: Key('pairing-qr-payload-${request.id}'),
                      maxLines: 3,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: Key('pairing-cancel-${request.id}'),
                  onPressed: canDecide
                      ? () => app.cancelPairing(request.id)
                      : null,
                  icon: const Icon(Icons.close),
                  label: const Text('取消'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: FilledButton.icon(
                  key: Key('pairing-approve-${request.id}'),
                  onPressed: canDecide
                      ? () => app.approvePairing(request.id)
                      : null,
                  icon: const Icon(Icons.check),
                  label: const Text('批准'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(appControllerProvider);
    return _StatusScaffold(
      title: '设备管理',
      errorMessage: app.errorMessage,
      leading: IconButton(
        key: const Key('back-home-button'),
        tooltip: '返回控制端',
        onPressed: () => context.go('/home'),
        icon: const Icon(Icons.arrow_back),
      ),
      child: ListView(
        children: [
          if (app.devices.isEmpty) const _EmptyState(text: '没有已绑定设备。'),
          for (final device in app.devices)
            _DeviceTile(device: device, app: app),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.app});

  final Device device;
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final activeOwnerCount = app.devices.where((item) => item.isOwner).length;
    final isLastOwner = device.isOwner && activeOwnerCount == 1;
    return ListTile(
      key: Key('device-${device.id}'),
      leading: Icon(
        device.status == DeviceStatus.active
            ? Icons.check_circle_outline
            : Icons.block_outlined,
      ),
      title: Text(device.displayName),
      subtitle: Text('${device.role.wireValue} · ${device.status.wireValue}'),
      trailing: IconButton(
        key: Key('device-revoke-${device.id}'),
        tooltip: isLastOwner ? '不能撤销最后一个 owner' : '撤销设备',
        onPressed:
            device.status == DeviceStatus.active && !isLastOwner && !app.isBusy
            ? () => app.revokeDevice(device.id)
            : null,
        icon: const Icon(Icons.link_off),
      ),
    );
  }
}

class _StatusScaffold extends StatelessWidget {
  const _StatusScaffold({
    required this.title,
    required this.child,
    this.errorMessage,
    this.leading,
    this.actions = const [],
  });

  final String title;
  final Widget child;
  final String? errorMessage;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('mobile-page-shell'),
    appBar: AppBar(
      title: _MobileHeaderTitle(title: title),
      leading: leading,
      actions: [const AppearanceMenu(), ...actions],
    ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            key: const Key('mobile-content-rail'),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              children: [
                if (errorMessage != null)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const Key('app-error-message'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: AppSpacing.md),
                      // 与内联错误横幅同款节奏：图标 24 + h12/v8。
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.sm,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.card),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: AppSizes.iconXl,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(child: Text(errorMessage!)),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 统一呈现居中标题和在线状态点，避免每个页面各自拼接不一致的移动端导航栏。
class _MobileHeaderTitle extends StatelessWidget {
  const _MobileHeaderTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Semantics(
    label: title,
    child: Row(
      key: const Key('mobile-header-title'),
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Container(
          key: const Key('mobile-header-status'),
          width: AppSizes.statusDot,
          height: AppSizes.statusDot,
          decoration: BoxDecoration(
            color: context.appColors.success,
            shape: BoxShape.circle,
          ),
        ),
      ],
    ),
  );
}

class _MobileSectionHeading extends StatelessWidget {
  const _MobileSectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    ),
  );
}

/// 认证与恢复页面在 200% 字号下允许纵向滚动，避免关键按钮被底部裁切。
class _ScrollableCenter extends StatelessWidget {
  const _ScrollableCenter({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
    child: Center(child: child),
  );
}

class _AuthMark extends StatelessWidget {
  const _AuthMark();

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('mobile-auth-intro'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: const Icon(Icons.hub_outlined),
      ),
      const SizedBox(height: AppSpacing.lg),
      Text('Agent Sessions', style: Theme.of(context).textTheme.titleLarge),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
    // 与全局空状态同节奏：icon32 + caption，替代裸文本。
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: AppSizes.iconEmpty,
            color: context.appColors.textSecondary,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    ),
  );
}
