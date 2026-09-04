package relay

import (
	"encoding/json"
	"net/http"
	"testing"
)

// V085-03：Daemon 鉴权附件读取端点（v0.8.5 §3.3）。附件属于 bound session 的
// workspace（home Terminal）；home Terminal 经 GET 读取 metadata_ciphertext 与
// 全部密文块（只读搬运、不回显可识别元数据）；其它 Terminal/账号 fail-closed；
// 未完成附件拒绝读取。
func TestV085DaemonAttachmentReadEndpoint(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-att-read@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-att-read-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v085-att-read")
	epoch := p3AcquireLease(t, env, sessionID, owner.AccessToken)

	attachmentID := "att_v085_read"
	for i, chunk := range []string{"chunk-0", "chunk-1"} {
		resp := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
			attachmentID, sessionID, epoch, i, 2, chunk, "up-"+string(rune(97+i)),
		), owner.AccessToken)
		if resp.Code != http.StatusCreated {
			t.Fatalf("chunk %d status=%d body=%s", i, resp.Code, resp.Body.String())
		}
	}
	complete := env.do(t, http.MethodPost, "/v1/attachments/"+attachmentID+"/complete", map[string]any{
		"session_id": sessionID, "total_chunks": 2,
		"idempotency_key": "complete-v085", "lease_epoch": epoch,
	}, owner.AccessToken)
	if complete.Code != http.StatusOK {
		t.Fatalf("complete status=%d body=%s", complete.Code, complete.Body.String())
	}

	// home Terminal 读取：metadata + 全部块 + sha256，按存储顺序。
	read := env.do(t, http.MethodGet, "/v1/daemon/attachments/"+attachmentID, nil, terminal.AccessToken)
	if read.Code != http.StatusOK {
		t.Fatalf("daemon read status=%d body=%s", read.Code, read.Body.String())
	}
	var view struct {
		AttachmentID       string   `json:"attachment_id"`
		MimeType           string   `json:"mime_type"`
		TotalChunks        int      `json:"total_chunks"`
		MetadataCiphertext []byte   `json:"metadata_ciphertext"`
		Chunks             [][]byte `json:"chunks"`
		ChunkSHA256        []string `json:"chunk_sha256"`
	}
	if err := json.Unmarshal(read.Body.Bytes(), &view); err != nil {
		t.Fatalf("decode read: %v body=%s", err, read.Body.String())
	}
	if view.AttachmentID != attachmentID || view.TotalChunks != 2 || len(view.Chunks) != 2 {
		t.Fatalf("unexpected read view: %+v", view)
	}
	if string(view.MetadataCiphertext) != "fixture-metadata-ciphertext" {
		t.Fatalf("metadata ciphertext mismatch: %s", view.MetadataCiphertext)
	}
	if string(view.Chunks[0]) != "chunk-0" || string(view.Chunks[1]) != "chunk-1" {
		t.Fatalf("chunk order/content mismatch: %s", view.Chunks)
	}
	if len(view.ChunkSHA256) != 2 || view.ChunkSHA256[0] == "" {
		t.Fatalf("chunk sha256 missing: %+v", view.ChunkSHA256)
	}

	// 其它 Terminal 读取同一附件被拒（home 归属）。
	otherTerminal := env.pairTerminal(t, owner, "v085-att-read-other")
	daemonHello(t, env, otherTerminal.AccessToken)
	forbidden := env.do(t, http.MethodGet, "/v1/daemon/attachments/"+attachmentID, nil, otherTerminal.AccessToken)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("other terminal read status=%d body=%s", forbidden.Code, forbidden.Body.String())
	}

	// owner（非 terminal）不能走 daemon 端点。
	ownerDenied := env.do(t, http.MethodGet, "/v1/daemon/attachments/"+attachmentID, nil, owner.AccessToken)
	if ownerDenied.Code == http.StatusOK {
		t.Fatalf("owner read must be denied: %s", ownerDenied.Body.String())
	}
}

// V085-03b：未完成附件拒绝读取（fail-closed）。
func TestV085DaemonAttachmentReadRejectsIncomplete(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "v085-att-pending@test.dev")
	terminal := env.pairTerminal(t, owner, "v085-att-pending-terminal")
	terminalID := daemonHello(t, env, terminal.AccessToken)
	sessionID, _ := env.createBoundSession(t, owner, terminalID, "v085-att-pending")
	epoch := p3AcquireLease(t, env, sessionID, owner.AccessToken)

	attachmentID := "att_v085_pending"
	resp := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		attachmentID, sessionID, epoch, 0, 1, "chunk-only", "up-p",
	), owner.AccessToken)
	if resp.Code != http.StatusCreated {
		t.Fatalf("chunk status=%d body=%s", resp.Code, resp.Body.String())
	}
	read := env.do(t, http.MethodGet, "/v1/daemon/attachments/"+attachmentID, nil, terminal.AccessToken)
	if read.Code != http.StatusConflict && read.Code != http.StatusNotFound {
		t.Fatalf("pending read status=%d body=%s (want conflict/fail-closed)", read.Code, read.Body.String())
	}
}
