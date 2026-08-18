import 'package:agent_sessions_mobile/app/providers.dart';
import 'package:agent_sessions_mobile/attachments/attachment_picker.dart';
import 'package:agent_sessions_mobile/relay/fixture_relay_repository.dart';
import 'package:agent_sessions_mobile/main.dart';
import 'package:agent_sessions_mobile/state/session_controller.dart';
import 'package:agent_sessions_mobile/storage/encrypted_cache.dart';
import 'package:agent_sessions_mobile/storage/secure_token_store.dart';
import 'package:agent_sessions_mobile/storage/theme_preference_store.dart';
import 'package:agent_sessions_mobile/ui/pairing_scanner.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'fixture_owner.dart';

/// 所有 Flutter UI 回归使用同一组明确 fixture，避免测试依赖本机 Keystore 或真实 Relay。
class MobileAppHarness {
  MobileAppHarness({this.scannerBuilder, this.attachmentPicker})
    : relay = FixtureRelayRepository(),
      tokens = InMemorySecureTokenStore(),
      identities = InMemoryDeviceIdentityStore(),
      cache = InMemoryEncryptedCacheStore(),
      appearance = InMemoryThemePreferenceStore();

  final FixtureRelayRepository relay;
  final InMemorySecureTokenStore tokens;
  final InMemoryDeviceIdentityStore identities;
  final InMemoryEncryptedCacheStore cache;
  final InMemoryThemePreferenceStore appearance;
  final PairingScannerBuilder? scannerBuilder;

  /// v0.2/P3：附件选择器注入。null 时使用真实 SystemAttachmentPicker（无平台通道时 fail-closed）。
  final AttachmentPicker? attachmentPicker;

  /// 本地 UI 测试的统一 Happy-style 设备入口。
  ///
  /// 该 helper 只初始化 fixture Relay 的本机 owner，不经过账号注册/登录；
  /// 需要先把应用推进到 owner 状态的测试可复用同一套 token 与 identity。
  Future<FixtureOwner> bootstrapLocalOwner({
    String displayName = '本地 Android 控制端',
  }) => bootstrapFixtureOwner(
    relay,
    tokens: tokens,
    identities: identities,
    displayName: displayName,
  );

  Widget build() => ProviderScope(
    overrides: [
      relayRepositoryProvider.overrideWithValue(relay),
      secureTokenStoreProvider.overrideWithValue(tokens),
      deviceIdentityStoreProvider.overrideWithValue(identities),
      encryptedCacheStoreProvider.overrideWithValue(cache),
      themePreferenceStoreProvider.overrideWithValue(appearance),
      if (attachmentPicker != null)
        sessionControllerProvider.overrideWith(
          (_) =>
              SessionController(relay: relay, picker: attachmentPicker)
                ..initialize(),
        ),
      if (scannerBuilder != null)
        pairingScannerBuilderProvider.overrideWithValue(scannerBuilder!),
    ],
    // harness 复用真实路由与业务状态，但关闭 macOS 预览缩放，保证 integration 点击命中原始测试 surface。
    child: const AgentSessionsApp(useMacBookPhoneCanvas: false),
  );
}
