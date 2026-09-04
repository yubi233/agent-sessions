package relay

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/yubi233/agent-sessions/packages/protocol"
)

// ATTACH-01：真实 HTTP router + 隔离 SQLite 覆盖附件的密文、顺序、lease 与幂等边界；不调用 Provider。
func TestP3ATTACH01EncryptedUploadAndCompletionAreIdempotent(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "p3-attachment@test.dev")
	sessionID, _ := env.createSession(t, pair.AccessToken, pair.AccountID)
	epoch := p3AcquireLease(t, env, sessionID, pair.AccessToken)

	attachmentID := "att_p3_complete"
	first := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		attachmentID, sessionID, epoch, 0, 2, "chunk-a", "upload-a",
	), pair.AccessToken)
	if first.Code != http.StatusCreated {
		t.Fatalf("first chunk status=%d body=%s", first.Code, first.Body.String())
	}
	var firstReceipt p3AttachmentReceipt
	decodeP3(t, first.Body.Bytes(), &firstReceipt)
	if firstReceipt.AttachmentID != attachmentID || firstReceipt.ChunkIndex != 0 || firstReceipt.Status != "pending" || firstReceipt.Idempotent {
		t.Fatalf("unexpected first receipt: %+v", firstReceipt)
	}
	// 相同 chunk 与幂等键重放不能新增一块，也不能暴露 ciphertext。
	retry := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		attachmentID, sessionID, epoch, 0, 2, "chunk-a", "upload-a",
	), pair.AccessToken)
	if retry.Code != http.StatusCreated {
		t.Fatalf("retry chunk status=%d body=%s", retry.Code, retry.Body.String())
	}
	var retryReceipt p3AttachmentReceipt
	decodeP3(t, retry.Body.Bytes(), &retryReceipt)
	if !retryReceipt.Idempotent || bytes.Contains(retry.Body.Bytes(), []byte("chunk-a")) {
		t.Fatalf("retry must be idempotent and must not echo ciphertext: %+v body=%s", retryReceipt, retry.Body.String())
	}

	second := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		attachmentID, sessionID, epoch, 1, 2, "chunk-b", "upload-b",
	), pair.AccessToken)
	if second.Code != http.StatusCreated {
		t.Fatalf("second chunk status=%d body=%s", second.Code, second.Body.String())
	}
	complete := env.do(t, http.MethodPost, "/v1/attachments/"+attachmentID+"/complete", map[string]any{
		"session_id": sessionID, "total_chunks": 2,
		"idempotency_key": "complete-a", "lease_epoch": epoch,
	}, pair.AccessToken)
	if complete.Code != http.StatusOK {
		t.Fatalf("complete status=%d body=%s", complete.Code, complete.Body.String())
	}
	var completed p3AttachmentReceipt
	decodeP3(t, complete.Body.Bytes(), &completed)
	if completed.Status != "completed" || completed.ChunkIndex != -1 || completed.Idempotent {
		t.Fatalf("unexpected complete receipt: %+v", completed)
	}

	completeRetry := env.do(t, http.MethodPost, "/v1/attachments/"+attachmentID+"/complete", map[string]any{
		"session_id": sessionID, "total_chunks": 2,
		"idempotency_key": "complete-a", "lease_epoch": epoch,
	}, pair.AccessToken)
	if completeRetry.Code != http.StatusOK {
		t.Fatalf("complete retry status=%d body=%s", completeRetry.Code, completeRetry.Body.String())
	}
	var completeRetryReceipt p3AttachmentReceipt
	decodeP3(t, completeRetry.Body.Bytes(), &completeRetryReceipt)
	if !completeRetryReceipt.Idempotent || completeRetryReceipt.Status != "completed" {
		t.Fatalf("completion retry must return the prior receipt: %+v", completeRetryReceipt)
	}

	stored, err := env.repo.AttachmentByID(t.Context(), attachmentID)
	if err != nil || stored.Status != "completed" || stored.CompleteIdempotencyKey != "complete-a" {
		t.Fatalf("stored attachment state err=%v attachment=%+v", err, stored)
	}
	if string(stored.MetadataCiphertext) != "fixture-metadata-ciphertext" {
		t.Fatalf("Relay must persist the opaque metadata bytes without parsing them")
	}
}

// ATTACH-01 根因回归：顺序、大小/MIME、未完成、过期 fencing、只读和明文 filename 注入必须被拒绝。
func TestP3ATTACH01RejectsUnsafeUploadPaths(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "p3-attachment-reject@test.dev")
	sessionID, _ := env.createSession(t, pair.AccessToken, pair.AccountID)
	epoch := p3AcquireLease(t, env, sessionID, pair.AccessToken)

	outOfOrder := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		"att_p3_order", sessionID, epoch, 1, 2, "second-before-first", "order-b",
	), pair.AccessToken)
	if outOfOrder.Code != http.StatusBadRequest {
		t.Fatalf("out-of-order chunk status=%d want 400 body=%s", outOfOrder.Code, outOfOrder.Body.String())
	}
	if _, err := env.repo.AttachmentByID(t.Context(), "att_p3_order"); !errorsIsNoRows(err) {
		t.Fatalf("failed ordered upload must roll back metadata, err=%v", err)
	}

	badMime := p3ChunkRequest("att_p3_mime", sessionID, epoch, 0, 1, "opaque", "mime-a")
	badMime["mime_type"] = "application/pdf"
	if response := env.do(t, http.MethodPost, "/v1/attachments/chunks", badMime, pair.AccessToken); response.Code != http.StatusBadRequest {
		t.Fatalf("invalid MIME status=%d want 400 body=%s", response.Code, response.Body.String())
	}
	tooLarge := p3ChunkRequest("att_p3_size", sessionID, epoch, 0, 1, "opaque", "size-a")
	tooLarge["mime_type"] = "image/png"
	tooLarge["byte_size"] = 10*1024*1024 + 1
	if response := env.do(t, http.MethodPost, "/v1/attachments/chunks", tooLarge, pair.AccessToken); response.Code != http.StatusBadRequest {
		t.Fatalf("oversized image status=%d want 400 body=%s", response.Code, response.Body.String())
	}

	partialID := "att_p3_incomplete"
	partial := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		partialID, sessionID, epoch, 0, 2, "only-first", "partial-a",
	), pair.AccessToken)
	if partial.Code != http.StatusCreated {
		t.Fatalf("partial upload status=%d body=%s", partial.Code, partial.Body.String())
	}
	incomplete := env.do(t, http.MethodPost, "/v1/attachments/"+partialID+"/complete", map[string]any{
		"session_id": sessionID, "total_chunks": 2,
		"idempotency_key": "partial-complete", "lease_epoch": epoch,
	}, pair.AccessToken)
	if incomplete.Code != http.StatusConflict {
		t.Fatalf("incomplete complete status=%d want 409 body=%s", incomplete.Code, incomplete.Body.String())
	}

	staleEpoch := epoch
	// 另一 Android 设备接管使 epoch 递增：原设备携旧 epoch 的分块上传必须被拒。
	secondDevice := env.pairAndroidOwner(t, pair, "p3-second-android")
	_ = p3AcquireLease(t, env, sessionID, secondDevice.AccessToken)
	if response := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		"att_p3_stale", sessionID, staleEpoch, 0, 1, "stale", "stale-a",
	), pair.AccessToken); response.Code != http.StatusConflict {
		t.Fatalf("stale lease upload status=%d want 409 body=%s", response.Code, response.Body.String())
	}

	// 传输 DTO 严格拒绝 filename，避免 Relay 甚至短暂接收可识别明文元数据。
	strictFilename := p3ChunkRequest("att_p3_filename", sessionID, staleEpoch+1, 0, 1, "opaque", "filename-a")
	strictFilename["filename"] = "private-notes.txt"
	if response := env.do(t, http.MethodPost, "/v1/attachments/chunks", strictFilename, pair.AccessToken); response.Code != http.StatusBadRequest {
		t.Fatalf("filename injection status=%d want 400 body=%s", response.Code, response.Body.String())
	}

	adminLogin := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "p3-attachment-reject@test.dev", "password": "test-pass-123", "device_role": "admin",
	}, "")
	if adminLogin.Code != http.StatusOK {
		t.Fatalf("admin login status=%d body=%s", adminLogin.Code, adminLogin.Body.String())
	}
	var admin struct {
		AccessToken string `json:"access_token"`
	}
	decodeP3(t, adminLogin.Body.Bytes(), &admin)
	if response := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		"att_p3_readonly", sessionID, staleEpoch+1, 0, 1, "readonly", "readonly-a",
	), admin.AccessToken); response.Code != http.StatusForbidden {
		t.Fatalf("readonly upload status=%d want 403 body=%s", response.Code, response.Body.String())
	}
}

// ATTACH-01 根因回归：请求体必须在 base64 解码前受限，跨账号已存在 ID 不能泄露为冲突。
func TestP3ATTACH01BoundsRequestBodiesAndHidesCrossAccountAttachmentIDs(t *testing.T) {
	env := newTestEnv(t)
	owner := env.registerAs(t, "p3-attachment-boundary-owner@test.dev")
	ownerSessionID, _ := env.createSession(t, owner.AccessToken, owner.AccountID)
	ownerEpoch := p3AcquireLease(t, env, ownerSessionID, owner.AccessToken)

	// JSON 字符串在超过上限前没有闭合，证明 handler 在完整 base64 解码和领域校验前终止读取。
	overstatedChunkBody := append([]byte(`{"ciphertext":"`), bytes.Repeat([]byte("A"), 800*1024)...)
	overstatedChunkBody = append(overstatedChunkBody, []byte(`"}`)...)
	if response := p3RawJSON(t, env, http.MethodPost, "/v1/attachments/chunks", overstatedChunkBody, owner.AccessToken); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized chunk body status=%d want 413 body=%s", response.Code, response.Body.String())
	} else if code := p3ErrorCode(t, response.Body.Bytes()); code != protocol.ErrPayloadTooLarge {
		t.Fatalf("oversized chunk body code=%q want %q", code, protocol.ErrPayloadTooLarge)
	}
	if _, err := env.repo.AttachmentByID(t.Context(), "att_p3_body_too_large"); !errorsIsNoRows(err) {
		t.Fatalf("oversized request must not persist attachment state, err=%v", err)
	}

	overstatedCompleteBody := append([]byte(`{"idempotency_key":"`), bytes.Repeat([]byte("A"), 40*1024)...)
	overstatedCompleteBody = append(overstatedCompleteBody, []byte(`"}`)...)
	if response := p3RawJSON(t, env, http.MethodPost, "/v1/attachments/att_p3_body_too_large/complete", overstatedCompleteBody, owner.AccessToken); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversized complete body status=%d want 413 body=%s", response.Code, response.Body.String())
	} else if code := p3ErrorCode(t, response.Body.Bytes()); code != protocol.ErrPayloadTooLarge {
		t.Fatalf("oversized complete body code=%q want %q", code, protocol.ErrPayloadTooLarge)
	}

	attachmentID := "att_p3_cross_account"
	if response := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		attachmentID, ownerSessionID, ownerEpoch, 0, 1, "owner-chunk", "owner-upload",
	), owner.AccessToken); response.Code != http.StatusCreated {
		t.Fatalf("owner upload status=%d body=%s", response.Code, response.Body.String())
	}

	other := env.provisionAdditionalAccount(t, "p3-attachment-boundary-other@test.dev")
	otherSessionID, _ := env.createSessionForProject(t, other.AccessToken, other.AccountID, "proj_p3_attachment_boundary_other")
	otherEpoch := p3AcquireLease(t, env, otherSessionID, other.AccessToken)
	if response := env.do(t, http.MethodPost, "/v1/attachments/chunks", p3ChunkRequest(
		attachmentID, otherSessionID, otherEpoch, 0, 1, "other-chunk", "other-upload",
	), other.AccessToken); response.Code != http.StatusForbidden {
		t.Fatalf("cross-account attachment probe status=%d want 403 body=%s", response.Code, response.Body.String())
	} else if code := p3ErrorCode(t, response.Body.Bytes()); code != protocol.ErrScopeDenied {
		t.Fatalf("cross-account attachment probe code=%q want %q", code, protocol.ErrScopeDenied)
	}

	tooLongID := strings.Repeat("a", 129)
	if response := env.do(t, http.MethodPost, "/v1/attachments/"+tooLongID+"/complete", map[string]any{
		"session_id": otherSessionID, "total_chunks": 1,
		"idempotency_key": "long-id-complete", "lease_epoch": otherEpoch,
	}, other.AccessToken); response.Code != http.StatusBadRequest {
		t.Fatalf("overlong complete attachment id status=%d want 400 body=%s", response.Code, response.Body.String())
	} else if code := p3ErrorCode(t, response.Body.Bytes()); code != protocol.ErrInvalidRequest {
		t.Fatalf("overlong complete attachment id code=%q want %q", code, protocol.ErrInvalidRequest)
	}
}

type p3AttachmentReceipt struct {
	AttachmentID string `json:"attachment_id"`
	ChunkIndex   int    `json:"chunk_index"`
	Status       string `json:"status"`
	Idempotent   bool   `json:"idempotent"`
}

func p3AcquireLease(t *testing.T, env *testEnv, sessionID, token string) int64 {
	t.Helper()
	response := env.do(t, http.MethodPost, "/v1/sessions/"+sessionID+"/lease", nil, token)
	if response.Code != http.StatusOK {
		t.Fatalf("acquire lease status=%d body=%s", response.Code, response.Body.String())
	}
	var lease struct {
		Epoch int64 `json:"lease_epoch"`
	}
	decodeP3(t, response.Body.Bytes(), &lease)
	if lease.Epoch <= 0 {
		t.Fatalf("invalid lease epoch=%d", lease.Epoch)
	}
	return lease.Epoch
}

func p3ChunkRequest(attachmentID, sessionID string, epoch int64, index, total int, ciphertext, idempotencyKey string) map[string]any {
	return map[string]any{
		"attachment_id": attachmentID,
		"session_id":    sessionID,
		"mime_type":     "text/plain",
		"byte_size":     24,
		"compression":   "none",
		// []byte 由 encoding/json 转为 base64；服务端只将它当作 opaque bytes 保存。
		"metadata_ciphertext": []byte("fixture-metadata-ciphertext"),
		"chunk_index":         index,
		"total_chunks":        total,
		"ciphertext":          []byte(ciphertext),
		"idempotency_key":     idempotencyKey,
		"lease_epoch":         epoch,
	}
}

// p3RawJSON 只用于验证传输层在 JSON 解码前的资源限制，避免测试 helper 先序列化大 body。
func p3RawJSON(t *testing.T, env *testEnv, method, path string, body []byte, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	env.router.ServeHTTP(response, req)
	return response
}

func p3ErrorCode(t *testing.T, body []byte) string {
	t.Helper()
	var response struct {
		Code string `json:"code"`
	}
	decodeP3(t, body, &response)
	return response.Code
}

func decodeP3(t *testing.T, body []byte, output any) {
	t.Helper()
	if err := json.Unmarshal(body, output); err != nil {
		t.Fatalf("decode response: %v body=%s", err, body)
	}
}

func errorsIsNoRows(err error) bool { return err != nil && err == sql.ErrNoRows }
