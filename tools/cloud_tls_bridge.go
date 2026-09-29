// cloud_tls_bridge：云端 relay 的本地 TLS 桥接（OWN-06 拓扑 A：daemon 连云端）。
//
// 为什么存在：云端 Caddy 直接以 CA:TRUE 自签根证书作叶子服务（SAN 为空），
// Dart/移动端宽容可用，Go x509 严格校验拒绝（"certificate is not standards
// compliant"）。且该证书的 SHA-256 指纹被交付 APK 钉死（deploy/acceptance.env
// AGENT_SESSIONS_ACC_TLS_FINGERPRINT），不能换证，只能在客户端侧桥接。
//
// 口径与 smoke.sh / 交付 APK 一致：指纹钉扎（InsecureSkipVerify +
// VerifyPeerCertificate 自行比对 DER SHA-256），绝不做 -k 裸放行——证书被
// 替换即指纹失配、桥接立即失败。
//
// 用法：
//
//	go build -o tls-bridge tools/cloud_tls_bridge.go
//	./tls-bridge --upstream https://39.106.135.11 --listen 127.0.0.1:18787 \
//	             --fingerprint <DER SHA-256 hex>
//
// daemon 以 --relay-base http://127.0.0.1:18787 接入；SSE 长流经
// FlushInterval=-1 立即冲刷透传。
package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"flag"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

// x509 仅用于 VerifyPeerCertificate 的签名形状（不做系统链校验）。

func main() {
	upstream := flag.String("upstream", "https://39.106.135.11", "云端 relay 基址")
	listen := flag.String("listen", "127.0.0.1:18787", "本地明文监听地址")
	fingerprint := flag.String("fingerprint", "", "服务端证书 DER SHA-256（hex，必填；防降级）")
	flag.Parse()
	fp := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(*fingerprint), ":", ""))
	if len(fp) != 64 {
		log.Fatal("需要 --fingerprint <64 位 hex>（取自 deploy/acceptance.env 或 smoke.sh 实测）")
	}
	want, err := hex.DecodeString(fp)
	if err != nil {
		log.Fatalf("指纹非法: %v", err)
	}
	target, err := url.Parse(*upstream)
	if err != nil {
		log.Fatalf("upstream 非法: %v", err)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = &http.Transport{
		TLSClientConfig: &tls.Config{
			// 校验完全由下方指纹钉扎接管（Go 文档认可的 pinning 组合）。
			InsecureSkipVerify: true,
			VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
				if len(rawCerts) == 0 {
					return errors.New("服务端未出示证书")
				}
				sum := sha256.Sum256(rawCerts[0])
				if !bytes.Equal(sum[:], want) {
					return errors.New("指纹不一致（疑似中间人/换证）：拒绝连接")
				}
				return nil
			},
			MinVersion: tls.VersionTLS12,
		},
	}
	// SSE / 事件长流：立即冲刷，不做缓冲聚合。
	proxy.FlushInterval = -1
	log.Printf("cloud tls bridge %s -> %s（指纹钉扎 %s…）", *listen, *upstream, fp[:16])
	log.Fatal(http.ListenAndServe(*listen, proxy))
}
