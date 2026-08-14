import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

import 'encrypted_cache.dart';

/// Android 使用 Drift SQLite 持久化密文；Chrome fixture 模式只使用内存，避免缺失 WASM 资产阻断 UI 验收。
EncryptedCacheStore createRuntimeEncryptedCacheStore() {
  if (kIsWeb) {
    return InMemoryEncryptedCacheStore();
  }
  return DriftEncryptedCacheStore(
    driftDatabase(name: 'agent_sessions_envelope_cache'),
  );
}
