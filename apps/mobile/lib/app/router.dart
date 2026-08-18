import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/app_controller.dart';
import '../ui/command_palette_screens.dart';
import '../ui/daemon_observation_screens.dart';
import '../ui/git_diff_screens.dart';
import '../ui/message_deep_link_screens.dart';
import '../ui/pairing_scanner.dart';
import '../ui/recent_sessions_screens.dart';
import '../ui/screens.dart';
import '../ui/session_info_screens.dart';
import '../ui/session_screens.dart';
import '../ui/settings_screens.dart';
import '../ui/terminal_status_screens.dart';
import '../ui/usage_screens.dart';
import '../ui/workspace_files_screens.dart';
import 'providers.dart';

/// 路由守卫只依据本机认证状态决定入口；设备和写权限仍由 Relay 最终裁决。
final appRouterProvider = Provider<GoRouter>((ref) {
  final controller = ref.read(appControllerProvider);
  final router = GoRouter(
    initialLocation: '/connect',
    refreshListenable: controller,
    redirect: (context, state) {
      final location = state.matchedLocation;
      final isPublicRoute = location == '/connect' || location == '/recovery';
      if (controller.phase == AppAuthPhase.booting) {
        return location == '/connect' ? null : '/connect';
      }
      if (!controller.isAuthenticated && !isPublicRoute) {
        return '/connect';
      }
      // 已认证但本机身份损坏时仍需允许进入恢复码页，其他公开入口照常回到控制端。
      final authenticatedRecovery =
          controller.isAuthenticated &&
          location == '/recovery' &&
          controller.requiresRecovery;
      if (controller.isAuthenticated &&
          isPublicRoute &&
          !authenticatedRecovery) {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/connect',
        builder: (context, state) => const ConnectDeviceScreen(),
      ),
      GoRoute(
        path: '/recovery',
        builder: (context, state) => const RecoveryScreen(),
      ),
      GoRoute(
        path: '/recovery-code',
        builder: (context, state) => const RecoveryCodeScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => const SessionHomeScreen(),
      ),
      GoRoute(
        path: '/sessions/recent',
        builder: (context, state) => const RecentSessionsScreen(),
      ),
      GoRoute(
        path: '/sessions/new',
        builder: (context, state) => const NewSessionScreen(),
      ),
      GoRoute(
        path: '/sessions/:id/git',
        builder: (context, state) =>
            GitDiffScreen(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/sessions/:id/files',
        builder: (context, state) =>
            WorkspaceFilesScreen(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/sessions/:id/observation',
        builder: (context, state) =>
            DaemonObservationScreen(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/sessions/:id',
        builder: (context, state) =>
            SessionDetailScreen(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/sessions/:id/info',
        builder: (context, state) =>
            SessionInfoScreen(sessionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/sessions/:id/messages/:seq',
        builder: (context, state) => MessageDeepLinkScreen(
          sessionId: state.pathParameters['id']!,
          messageSequence: int.tryParse(state.pathParameters['seq'] ?? '') ?? 0,
        ),
      ),
      GoRoute(
        path: '/command-palette',
        builder: (context, state) => const CommandPaletteScreen(),
      ),
      GoRoute(path: '/usage', builder: (context, state) => const UsageScreen()),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/settings/account',
        builder: (context, state) => const SettingsAccountScreen(),
      ),
      GoRoute(
        path: '/settings/appearance',
        builder: (context, state) => const SettingsAppearanceScreen(),
      ),
      GoRoute(
        path: '/settings/agents',
        builder: (context, state) => const SettingsAgentsScreen(),
      ),
      GoRoute(
        path: '/settings/usage',
        builder: (context, state) => const SettingsUsageScreen(),
      ),
      GoRoute(
        path: '/settings/connect',
        builder: (context, state) => const SettingsConnectScreen(),
      ),
      GoRoute(
        path: '/pairing',
        builder: (context, state) => const PairingScreen(),
      ),
      GoRoute(
        path: '/pairing/scan',
        builder: (context, state) => const PairingScannerScreen(),
      ),
      GoRoute(
        path: '/devices',
        builder: (context, state) => const DevicesScreen(),
      ),
      GoRoute(
        path: '/terminals',
        builder: (context, state) => const TerminalStatusScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
