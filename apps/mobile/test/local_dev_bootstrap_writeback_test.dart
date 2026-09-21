import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:agent_sessions_mobile/app/local_dev_bootstrap_io.dart';
import 'package:agent_sessions_mobile/domain/models.dart';

// V094 收口（2026-09-21）：桌面调试壳刷新令牌后必须回写 restart.sh 的 owner
// bootstrap 缓存——refresh token 一次性轮换，不回写会让下次 `restart.sh start`
// 的缓存刷新失败并触发 Relay DB 自愈重置，手机令牌随之失效。
void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('localdev-bootstrap-test');
    path = '${tmp.path}/local-owner-bootstrap.json';
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  AuthTokens tokens({String refresh = 'refresh-v2'}) => AuthTokens(
        accessToken: 'access-v2',
        refreshToken: refresh,
        expiresAt: DateTime.utc(2026, 9, 21, 12, 0),
        deviceId: 'dev-local',
      );

  Map<String, dynamic> seedFile() {
    final body = {
      'device': {'id': 'dev-local', 'role': 'android_owner', 'platform': 'local'},
      'tokens': {
        'access_token': 'access-v1',
        'refresh_token': 'refresh-v1',
        'expires_at': DateTime.utc(2026, 9, 21, 11, 30).toIso8601String(),
        'device_id': 'dev-local',
      },
    };
    File(path).writeAsStringSync(jsonEncode(body), flush: true);
    return body;
  }

  test('回写只更新 tokens 字段并保留 device 等其余内容', () {
    seedFile();
    writeLocalDevOwnerBootstrapTokens(path, tokens());
    final body = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    expect(body['tokens']['refresh_token'], 'refresh-v2');
    expect(body['tokens']['access_token'], 'access-v2');
    expect((body['device'] as Map)['id'], 'dev-local');
    // 临时文件不残留（原子 rename）。
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('损坏的缓存文件静默跳过，不抛出、不新建', () {
    File(path).writeAsStringSync('{broken', flush: true);
    writeLocalDevOwnerBootstrapTokens(path, tokens());
    expect(File(path).readAsStringSync(), '{broken');
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('路径为 null 或文件不存在时为 no-op', () {
    writeLocalDevOwnerBootstrapTokens(null, tokens());
    writeLocalDevOwnerBootstrapTokens('${tmp.path}/missing.json', tokens());
    expect(File('${tmp.path}/missing.json').existsSync(), isFalse);
  });
}
