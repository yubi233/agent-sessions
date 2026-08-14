import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/providers.dart';
import '../domain/models.dart';
import '../state/app_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
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
      title: '登录',
      errorMessage: app.errorMessage,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _AuthMark(),
                const SizedBox(height: 28),
                Text('登录', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 20),
                TextFormField(
                  key: const Key('login-email'),
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(labelText: '邮箱'),
                  validator: (value) =>
                      value != null && value.contains('@') ? null : '请输入有效邮箱。',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('login-password'),
                  controller: _passwordController,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(labelText: '密码'),
                  validator: (value) =>
                      value != null && value.isNotEmpty ? null : '请输入密码。',
                  onFieldSubmitted: (_) => _signIn(app),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('login-submit'),
                  onPressed: app.isBusy ? null : () => _signIn(app),
                  icon: const Icon(Icons.login),
                  label: app.isBusy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
                TextButton.icon(
                  key: const Key('recovery-link'),
                  onPressed: app.isBusy ? null : () => context.go('/recovery'),
                  icon: const Icon(Icons.key_outlined),
                  label: const Text('使用恢复码'),
                ),
                TextButton.icon(
                  key: const Key('register-link'),
                  onPressed: app.isBusy ? null : () => context.go('/register'),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('创建首个 owner'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _signIn(AppController app) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await app.signIn(
      LoginCredentials(
        email: _emailController.text,
        password: _passwordController.text,
      ),
    );
  }
}

/// 首次注册会触发 Relay 的初始 owner 创建与本机公钥 bootstrap，不能由普通登录替代。
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    return _StatusScaffold(
      title: '创建 owner',
      errorMessage: app.errorMessage,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _AuthMark(),
                const SizedBox(height: 28),
                Text(
                  '创建首个 Android owner',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const Key('register-email'),
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: '邮箱'),
                  validator: (value) =>
                      value != null && value.contains('@') ? null : '请输入有效邮箱。',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('register-password'),
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                  validator: (value) =>
                      value != null && value.isNotEmpty ? null : '请输入密码。',
                  onFieldSubmitted: (_) => _register(app),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('register-submit'),
                  onPressed: app.isBusy ? null : () => _register(app),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('创建并建立 owner'),
                ),
                TextButton.icon(
                  onPressed: () => context.go('/login'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _register(AppController app) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await app.registerOwner(
      LoginCredentials(
        email: _emailController.text,
        password: _passwordController.text,
      ),
    );
  }
}

class RecoveryScreen extends ConsumerStatefulWidget {
  const RecoveryScreen({super.key});

  @override
  ConsumerState<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends ConsumerState<RecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    return _StatusScaffold(
      title: '恢复账户',
      errorMessage: app.errorMessage,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _AuthMark(),
                const SizedBox(height: 28),
                Text(
                  '恢复此 Android 控制端',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const Key('recovery-email'),
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(labelText: '邮箱'),
                  validator: (value) =>
                      value != null && value.contains('@') ? null : '请输入有效邮箱。',
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('recovery-submit'),
                  onPressed: app.isBusy ? null : () => _recover(app),
                  icon: const Icon(Icons.restore_outlined),
                  label: const Text('恢复'),
                ),
                TextButton.icon(
                  onPressed: () => context.go('/login'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回登录'),
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
      _emailController.text,
      _codeController.text,
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
          tooltip: '退出登录',
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
              borderRadius: BorderRadius.circular(8),
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
                    title: Text('Owner 已建立'),
                    subtitle: Text('等待 Relay 授权。'),
                  )
                : app.hasOwner
                ? const ListTile(
                    key: Key('readonly-auth-state'),
                    leading: Icon(Icons.lock_outline),
                    title: Text('当前登录没有 Android 写设备'),
                    subtitle: Text('使用恢复码恢复。'),
                  )
                : const ListTile(
                    key: Key('unprovisioned-auth-state'),
                    leading: Icon(Icons.info_outline),
                    title: Text('尚未建立 Android owner'),
                    subtitle: Text('创建首个 owner 或恢复既有 owner。'),
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
      child: Center(
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
                        padding: const EdgeInsets.all(16),
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        child: SelectableText(
                          code,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
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
          const SizedBox(height: 12),
          TextField(
            key: const Key('pairing-request-id'),
            controller: _requestIdController,
            decoration: const InputDecoration(labelText: '扫描结果或配对请求 ID'),
            onSubmitted: (_) => _load(app),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('pairing-load-button'),
            onPressed: app.isBusy ? null : () => _load(app),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('读取配对请求'),
          ),
          const SizedBox(height: 24),
          Text('待处理请求', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.qr_code_2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.displayName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${request.role.wireValue} · ${request.status.wireValue}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // QR 与可复制 payload 绑定同一请求 ID；手动输入是无相机设备的等价路径。
              QrImageView(
                data: payload,
                size: 104,
                key: Key('pairing-qr-image-${request.id}'),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '短码：${PairingPayload.shortCode(request.id)}',
                      key: Key('pairing-short-code-${request.id}'),
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 8),
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
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
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
              const SizedBox(width: 8),
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
      actions: actions,
    ),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            key: const Key('mobile-content-rail'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                if (errorMessage != null)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const Key('app-error-message'),
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(errorMessage!),
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
        const SizedBox(width: 8),
        Container(
          key: const Key('mobile-header-status'),
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: Color(0xff86e0bf),
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
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    ),
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
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.hub_outlined),
      ),
      const SizedBox(height: 18),
      Text('Agent Sessions', style: Theme.of(context).textTheme.titleLarge),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Center(child: Text(text)),
  );
}
