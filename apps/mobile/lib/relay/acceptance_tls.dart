// 阿里云验收环境 TLS 降级通道（计划 §1 决策：裸 IP 自签证书 + 客户端按指纹放行）。
//
// 约束（计划 §4.4）：指纹仅在构建期经 `--dart-define=ACC_TLS_FINGERPRINT=<sha256>`
// 注入时生效；默认构建（未注入该 define）不做任何证书校验放宽，完全走系统信任链。
// 放行判据 = 对端证书 DER 的 SHA-256 与部署时登记的指纹严格一致
// （服务端指纹登记于 deploy/acceptance.env 的 AGENT_SESSIONS_ACC_TLS_FINGERPRINT，
// 与 `openssl x509 -outform der | sha256sum` 同口径）。
// 明文 HTTP 仍然被禁止：本通道只放宽「信任锚」，不放宽「传输安全」。
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

/// 编译期注入的验收自签证书 SHA-256 指纹（十六进制，允许带冒号/大小写，比对前统一归一）。
// ignore: do_not_use_environment
const acceptanceTlsFingerprint = String.fromEnvironment('ACC_TLS_FINGERPRINT');

/// 验收 TLS 通道是否启用：仅当构建期显式提供指纹时启用（fail-closed 默认）。
bool get acceptanceTlsEnabled => acceptanceTlsFingerprint.trim().isNotEmpty;

/// 统一指纹格式：去冒号 + 去空白 + 小写，避免大小写/分隔符差异导致比对失败。
String normalizeFingerprint(String hex) =>
    hex.replaceAll(':', '').trim().toLowerCase();

/// 对端证书 DER 的 SHA-256 十六进制指纹。
/// 与服务端 `openssl x509 -in relay.crt -outform der | sha256sum` 完全同口径。
String certificateFingerprintFromDer(List<int> der) =>
    crypto.sha256.convert(der).toString();

/// 纯函数判据（可单测）：对端证书 DER 是否为登记的验收自签证书。
/// 期望指纹为空时一律返回 false——未配置就拒绝，杜绝「信任所有证书」。
bool isAcceptedAcceptanceCertificate(List<int> der, String expectedFingerprint) {
  final expected = normalizeFingerprint(expectedFingerprint);
  if (expected.isEmpty) {
    return false;
  }
  return certificateFingerprintFromDer(der) == expected;
}

/// 给 Relay Dio 挂上验收指纹放行回调。
/// 未启用时是空操作（返回原 dio，默认构建的证书校验零影响）；
/// 启用时替换为 IOHttpClientAdapter，badCertificateCallback 只在系统校验失败
/// （自签/未知 CA）时进入：按指纹严格比对，命中才放行，其余一律拒绝。
/// 同时挂验收诊断日志：只记录方法/路径/状态码/耗时，绝不记录 token、
/// Authorization、请求体或响应正文（验收排障用，默认构建不挂）。
Dio applyAcceptanceTls(Dio dio) {
  if (!acceptanceTlsEnabled) {
    return dio;
  }
  dio.interceptors.add(
    LogInterceptor(
      request: true,
      requestHeader: false,
      requestBody: false,
      responseHeader: false,
      responseBody: false,
      error: true,
      logPrint: (message) => debugPrint('[acc-relay] $message'),
    ),
  );
  final expected = acceptanceTlsFingerprint;
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      client.badCertificateCallback = (cert, host, port) =>
          isAcceptedAcceptanceCertificate(cert.der, expected);
      return client;
    },
  );
  return dio;
}
