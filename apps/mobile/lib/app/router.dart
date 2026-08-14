import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/app_controller.dart';
import '../ui/pairing_scanner.dart';
import '../ui/screens.dart';
import '../ui/session_screens.dart';
import 'providers.dart';

/// 路由守卫只依据本机认证状态决定入口；设备和写权限仍由 Relay 最终裁决。
final appRouterProvider = Provider<GoRouter>((ref) {
  final controller = ref.read(appControllerProvider);
  final router = GoRouter(
    initialLocation: '/login',
    refreshListenable: controller,
    redirect: (context, state) {
      final location = state.matchedLocation;
      final isPublicRoute =
          location == '/login' ||
          location == '/recovery' ||
          location == '/register';
      if (controller.phase == AppAuthPhase.booting) {
        return location == '/login' ? null : '/login';
      }
      if (!controller.isAuthenticated && !isPublicRoute) {
        return '/login';
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
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
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
        path: '/sessions/new',
        builder: (context, state) => const NewSessionScreen(),
      ),
      GoRoute(
        path: '/sessions/:id',
        builder: (context, state) =>
            SessionDetailScreen(sessionId: state.pathParameters['id']!),
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
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
