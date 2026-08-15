import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/attachments/attachment_picker.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/main.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/ui/pairing_scanner.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 所有 Flutter UI 回归使用同一组明确 fixture，避免测试依赖本机 Keystore 或真实 Relay。
class MobileAppHarness {
  MobileAppHarness({
    this.scannerBuilder,
    this.attachmentPicker,
  }) : relay = FixtureRelayRepository(),
       tokens = InMemorySecureTokenStore(),
       identities = InMemoryDeviceIdentityStore(),
       cache = InMemoryEncryptedCacheStore();

  final FixtureRelayRepository relay;
  final InMemorySecureTokenStore tokens;
  final InMemoryDeviceIdentityStore identities;
  final InMemoryEncryptedCacheStore cache;
  final PairingScannerBuilder? scannerBuilder;

  /// v0.2/P3：附件选择器注入。null 时使用真实 SystemAttachmentPicker（无平台通道时 fail-closed）。
  final AttachmentPicker? attachmentPicker;

  Widget build() => ProviderScope(
    overrides: [
      relayRepositoryProvider.overrideWithValue(relay),
      secureTokenStoreProvider.overrideWithValue(tokens),
      deviceIdentityStoreProvider.overrideWithValue(identities),
      encryptedCacheStoreProvider.overrideWithValue(cache),
      if (attachmentPicker != null)
        sessionControllerProvider.overrideWith(
          (_) => SessionController(
            relay: relay,
            picker: attachmentPicker,
          )..initialize(),
        ),
      if (scannerBuilder != null)
        pairingScannerBuilderProvider.overrideWithValue(scannerBuilder!),
    ],
    // harness 复用真实路由与业务状态，但关闭 macOS 预览缩放，保证 integration 点击命中原始测试 surface。
    child: const AgentSessionsApp(useMacBookPhoneCanvas: false),
  );
}
