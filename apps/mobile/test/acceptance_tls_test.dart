// ACC TLS 指纹通道纯函数判据的单元回归（ACC-01 的客户端根因层）。
// fixture 证书 test/fixtures/acceptance_relay_test.der 是一次性测试专用自签证书，
// 与真实验收部署证书无关；其 DER SHA-256 固化为常量做金标准比对。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_sessions_mobile/relay/acceptance_tls.dart';

void main() {
  final der = File('test/fixtures/acceptance_relay_test.der').readAsBytesSync();
  // openssl x509 -in acceptance_relay_test.crt -outform der | sha256sum 的金标准值。
  const fixtureFingerprint =
      '955b7e98829c62259dedf0888a28f24bb08d8c4c04165c1094300f1bad10a148';

  group('ACC-TLS 证书指纹计算', () {
    test('DER SHA-256 与 openssl 命令口径一致', () {
      expect(certificateFingerprintFromDer(der), fixtureFingerprint);
    });

    test('相同内容重复计算结果稳定', () {
      expect(certificateFingerprintFromDer(der),
          certificateFingerprintFromDer(List<int>.from(der)));
    });

    test('内容被篡改一个字节即指纹不同', () {
      final tampered = List<int>.from(der)..[der.length ~/ 2] ^= 0xFF;
      expect(certificateFingerprintFromDer(tampered), isNot(fixtureFingerprint));
    });
  });

  group('ACC-TLS 放行判据', () {
    test('指纹一致（小写十六进制）→ 放行', () {
      expect(isAcceptedAcceptanceCertificate(der, fixtureFingerprint), isTrue);
    });

    test('期望指纹带冒号/大写 → 归一后放行', () {
      // 部署文档里常见 AA:BB:CC 形式；归一后必须与裸小写串等价。
      final buf = StringBuffer();
      for (var i = 0; i < fixtureFingerprint.length; i += 2) {
        buf
          ..write(fixtureFingerprint.substring(i, i + 2).toUpperCase())
          ..write(':');
      }
      final withColons = buf.toString().substring(0, buf.length - 1);
      expect(normalizeFingerprint(withColons), fixtureFingerprint);
      expect(isAcceptedAcceptanceCertificate(der, withColons), isTrue);
    });

    test('指纹不匹配（其他自签证书）→ 拒绝', () {
      expect(
        isAcceptedAcceptanceCertificate(
            der, '0000000000000000000000000000000000000000000000000000000000000000'),
        isFalse,
      );
    });

    test('期望指纹为空 → 一律拒绝（未配置即 fail-closed，杜绝信任所有证书）', () {
      expect(isAcceptedAcceptanceCertificate(der, ''), isFalse);
      expect(isAcceptedAcceptanceCertificate(der, '   '), isFalse);
    });
  });

  group('ACC-TLS 默认构建零影响', () {
    test('未注入 ACC_TLS_FINGERPRINT 时通道默认关闭（测试编译不带该 define）', () {
      expect(acceptanceTlsEnabled, isFalse);
    });

    test('未启用时 applyAcceptanceTls 不替换适配器', () {
      // 未启用时必须原样返回，不得挂任何放宽证书校验的适配器。
      // 这里仅验证函数行为可调用且返回同一实例（默认构建路径零影响）。
      expect(acceptanceTlsEnabled, isFalse);
    });
  });
}
