package dsh

// v0.9.5 P0（全局会话可续聊）先红回归。
//
// 背景：导入映射携带显式持久化根/编码后，resume 必须把桥绑定到 artifact 实际
// 所在的存储根（工作区 .dsh-sessions 或全局 ~/.dsh/sessions）与其物理编码。
// 此前 resume 一律使用 <workspace>/.dsh-sessions + 环境变量缺省编码：全局存储
// （zstd）来源的会话要么根错找不到会话，要么命中上游「根编码归属」校验被拒，
// 表现为「能看不能续」。

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 1. 环境注入：显式压缩编码必须覆盖环境变量缺省，且持久化根保持精确路径
// （不得追加 sessions 子目录，工作区回退根照常注入）。
func TestV095MinimalEnvWithCompressionOverridesEncoding(t *testing.T) {
	withEnvUnset(t, EnvPersistCompression)
	env := strings.Join(minimalEnvWithCompression("/global/.dsh/sessions", PersistenceCompressionZstd, "/tmp/dsh-ws"), "\n")
	if !strings.Contains(env, "DSH_SNAPSHOT_SESSIONS_ROOT=/global/.dsh/sessions") {
		t.Fatal("显式持久化根未精确注入（不得追加 sessions 子目录）")
	}
	if !strings.Contains(env, "DSH_SNAPSHOT_COMPRESSION=zstd") {
		t.Fatal("显式 zstd 编码未注入桥环境")
	}
	if !strings.Contains(env, "DSH_SESSION_CWD=/tmp/dsh-ws") {
		t.Fatal("工作区会话回退根未注入")
	}
	// 显式编码优先于环境变量：环境变量改回 none 也不得覆盖显式 zstd。
	t.Setenv(EnvPersistCompression, PersistenceCompressionNone)
	env = strings.Join(minimalEnvWithCompression("/global/.dsh/sessions", PersistenceCompressionZstd, "/tmp/dsh-ws"), "\n")
	if !strings.Contains(env, "DSH_SNAPSHOT_COMPRESSION=zstd") {
		t.Fatal("显式压缩编码必须优先于环境变量缺省")
	}
}

// 2. 路由：Resume 携带显式持久化根时必须走 sourceFactory（携带根/工作区/编码
// 三元组），不得回落工作区工厂；session/load 的 cwd 仍是工作区根。
func TestV095ResumeWithExplicitSourceRootRoutesToSourceFactory(t *testing.T) {
	fb := newFakeBridge()
	fb.script = respondByMethod(t, "sess-global-1")
	var gotRoot, gotWS, gotComp string
	var wsSpawned, srcSpawned int
	a := NewWithTransport(func() (BridgeTransport, error) {
		wsSpawned++
		return fb, nil
	})
	a.sourceFactory = func(persistenceRoot, workspaceRoot, compression string) (BridgeTransport, error) {
		srcSpawned++
		gotRoot, gotWS, gotComp = persistenceRoot, workspaceRoot, compression
		return fb, nil
	}
	globalRoot := t.TempDir()
	res, err := a.Resume(context.Background(), adapter.ResumeRequest{
		InstanceID:      "sess-global-1",
		WorkspaceRoot:   "/tmp/dsh-ws",
		PersistenceRoot: globalRoot,
		Compression:     PersistenceCompressionZstd,
		ReplayHistory:   true,
	})
	if err != nil {
		t.Fatalf("Resume: %v", err)
	}
	if res.Result != adapter.WakeResumed || res.InstanceID != "sess-global-1" {
		t.Fatalf("Resume 结果 = %+v", res)
	}
	if srcSpawned != 1 {
		t.Fatalf("显式持久化根必须且只能走 sourceFactory，实际 %d 次", srcSpawned)
	}
	if wsSpawned != 0 {
		t.Fatalf("显式持久化根不得回落工作区工厂，实际 %d 次", wsSpawned)
	}
	if gotRoot != globalRoot || gotWS != "/tmp/dsh-ws" || gotComp != PersistenceCompressionZstd {
		t.Fatalf("sourceFactory 参数 = (%q, %q, %q)", gotRoot, gotWS, gotComp)
	}
	var found bool
	for _, frame := range fb.written() {
		if methodOf(frame) == "session/load" {
			found = true
			params, _ := frame["params"].(map[string]any)
			if params["cwd"] != "/tmp/dsh-ws" {
				t.Fatalf("session/load cwd = %v, want 工作区根", params["cwd"])
			}
		}
	}
	if !found {
		t.Fatal("显式根 + ReplayHistory 必须发送 session/load")
	}
}

// 3. 根校验 fail-closed：显式持久化根不存在/非目录/相对路径/编码非法时，
// 必须在 spawn 之前报错（错误信息指向根问题），绝不留下半开进程。
func TestV095SourceTransportRejectsInvalidRootOrCompression(t *testing.T) {
	base := t.TempDir()
	cases := []struct {
		name    string
		root    string
		ws      string
		comp    string
		wantMsg string
	}{
		{"根不存在", base + "/missing", base, PersistenceCompressionZstd, "DSH 持久化根不可用"},
		{"根不是目录", base + "/file", base, PersistenceCompressionZstd, "DSH 持久化根不是目录"},
		{"相对路径", "relative/root", base, PersistenceCompressionZstd, "绝对路径"},
		{"编码非法", base, base, "gzip", "物理编码"},
		{"根为空", "   ", base, PersistenceCompressionNone, "持久化根"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name == "根不是目录" {
				if err := os.WriteFile(base+"/file", []byte("x"), 0o600); err != nil {
					t.Fatalf("写占位文件: %v", err)
				}
			}
			_, err := newBinTransportForSource(tc.root, tc.ws, tc.comp)
			if err == nil {
				t.Fatalf("%s 必须 fail-closed", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantMsg) {
				t.Fatalf("错误 = %v, want 含 %q", err, tc.wantMsg)
			}
		})
	}
}
