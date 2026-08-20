package relay

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"testing"

	"github.com/yubi233/agent-sessions/internal/domain"
)

// W1 合约测试只使用隔离 SQLite 和真实 HTTP router；不调用任何 Provider 或外部服务。
type w1Device struct {
	ID          string `json:"id"`
	Role        string `json:"role"`
	Status      string `json:"status"`
	DisplayName string `json:"display_name"`
}

type w1TokenPair struct {
	AccountID    string `json:"account_id"`
	DeviceID     string `json:"device_id"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
}

func decodeW1(t *testing.T, body []byte, out any) {
	t.Helper()
	if err := json.Unmarshal(body, out); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}

func bootstrapW1Owner(t *testing.T, env *testEnv, token string) w1Device {
	t.Helper()
	response := env.do(t, http.MethodPost, "/v1/pairing/bootstrap", map[string]any{
		"display_name":          "Android owner",
		"identity_public_key":   "owner-identity-public",
		"encryption_public_key": "owner-encryption-public",
		"platform":              "android",
	}, token)
	if response.Code != http.StatusCreated {
		t.Fatalf("bootstrap owner status=%d", response.Code)
	}
	var device w1Device
	decodeW1(t, response.Body.Bytes(), &device)
	if device.ID == "" || device.Role != domain.RoleAndroidOwner || device.Status != domain.DeviceActive {
		t.Fatalf("unexpected bootstrap device metadata")
	}
	return device
}

// AUTH-01：密码登录只能获得只读 token；Android 写身份不能由角色或 device_id 请求恢复。
func TestW1AUTH01PasswordLoginRejectsAndroidRoleInjection(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-auth@test.dev")
	owner := bootstrapW1Owner(t, env, pair.AccessToken)

	androidLogin := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "w1-auth@test.dev", "password": "test-pass-123", "device_id": owner.ID, "device_role": "android",
	}, "")
	if androidLogin.Code != http.StatusUnauthorized {
		t.Fatalf("android role login status=%d want 401", androidLogin.Code)
	}

	spoof := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "w1-auth@test.dev", "password": "test-pass-123",
		"device_id": "unregistered-device", "device_role": "android_owner",
	}, "")
	if spoof.Code != http.StatusUnauthorized {
		t.Fatalf("client-declared owner status=%d want 401", spoof.Code)
	}

	readOnly := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "w1-auth@test.dev", "password": "test-pass-123", "device_id": owner.ID, "device_role": "web",
	}, "")
	if readOnly.Code != http.StatusOK {
		t.Fatalf("read-only login status=%d", readOnly.Code)
	}
	var tokens w1TokenPair
	decodeW1(t, readOnly.Body.Bytes(), &tokens)
	if tokens.DeviceID != "" || tokens.ExpiresIn <= 0 || tokens.AccessToken == "" || tokens.RefreshToken == "" {
		t.Fatalf("password login must not return a bound write-capable device token")
	}
}

// AUTH-02：单租户实例只接受首个 Android owner bootstrap，后续账号必须经设备配对进入。
func TestW1AUTH02RegisterOnlyAllowsInitialOwner(t *testing.T) {
	env := newTestEnv(t)
	env.registerAs(t, "w1-initial-owner@test.dev")

	second := env.do(t, http.MethodPost, "/v1/auth/register", map[string]any{
		"email": "w1-second-account@test.dev", "password": "test-pass-123",
	}, "")
	if second.Code != http.StatusConflict {
		t.Fatalf("second initial-owner registration status=%d want 409", second.Code)
	}
	if containsStr(second.Body.String(), "access_token") || containsStr(second.Body.String(), "refresh_token") {
		t.Fatalf("closed registration response must not contain token fields")
	}
}

// AUTH-02：Android Happy 主路径用设备公钥直接初始化 owner，不要求账号、邮箱或密码。
func TestW1AUTH02DeviceBootstrapDoesNotRequireAccountLogin(t *testing.T) {
	env := newTestEnv(t)
	response := env.do(t, http.MethodPost, "/v1/auth/device-bootstrap", map[string]any{
		"display_name":          "Android phone",
		"platform":              "android",
		"identity_public_key":   "device-bootstrap-identity",
		"encryption_public_key": "device-bootstrap-encryption",
	}, "")
	if response.Code != http.StatusCreated {
		t.Fatalf("device bootstrap status=%d want 201", response.Code)
	}
	var result struct {
		Device w1Device    `json:"device"`
		Tokens w1TokenPair `json:"tokens"`
	}
	decodeW1(t, response.Body.Bytes(), &result)
	if result.Device.Role != domain.RoleAndroidOwner ||
		result.Tokens.DeviceID != result.Device.ID ||
		result.Tokens.AccessToken == "" ||
		result.Tokens.RefreshToken == "" {
		t.Fatalf("device bootstrap did not return owner device-bound tokens")
	}

	second := env.do(t, http.MethodPost, "/v1/auth/device-bootstrap", map[string]any{
		"display_name":          "Second phone",
		"platform":              "android",
		"identity_public_key":   "device-bootstrap-identity-2",
		"encryption_public_key": "device-bootstrap-encryption-2",
	}, "")
	if second.Code != http.StatusConflict {
		t.Fatalf("second device bootstrap status=%d want 409", second.Code)
	}
}

// PAIR-01/PAIR-02：初始 owner 完成公钥 bootstrap，待配对设备可由 owner 读取、批准且不会把公钥回显到设备列表。
func TestW1PAIR01AndPAIR02OwnerBootstrapReadApprove(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-pair@test.dev")
	owner := bootstrapW1Owner(t, env, pair.AccessToken)

	request := env.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": "PC one", "platform": "darwin",
		"identity_public_key":   "terminal-identity-public",
		"encryption_public_key": "terminal-encryption-public",
	}, pair.AccessToken)
	if request.Code != http.StatusCreated {
		t.Fatalf("create pairing status=%d", request.Code)
	}
	var pending struct {
		ID                  string `json:"id"`
		Status              string `json:"status"`
		IdentityPublicKey   string `json:"identity_public_key"`
		EncryptionPublicKey string `json:"encryption_public_key"`
	}
	decodeW1(t, request.Body.Bytes(), &pending)
	if pending.ID == "" || pending.Status != domain.PairingPending || pending.IdentityPublicKey == "" || pending.EncryptionPublicKey == "" {
		t.Fatalf("pairing request contract missing expected owner-only key metadata")
	}

	read := env.do(t, http.MethodGet, "/v1/pairing/requests/"+pending.ID, nil, pair.AccessToken)
	if read.Code != http.StatusOK {
		t.Fatalf("get pairing status=%d", read.Code)
	}
	// 密码登录只得到未绑定 Web token，不能读取包含待配对公钥的 owner 元数据。
	webLogin := env.do(t, http.MethodPost, "/v1/auth/login", map[string]any{
		"email": "w1-pair@test.dev", "password": "test-pass-123", "device_role": "web",
	}, "")
	if webLogin.Code != http.StatusOK {
		t.Fatalf("web login status=%d", webLogin.Code)
	}
	var webTokens w1TokenPair
	decodeW1(t, webLogin.Body.Bytes(), &webTokens)
	if denied := env.do(t, http.MethodGet, "/v1/pairing/requests/"+pending.ID, nil, webTokens.AccessToken); denied.Code != http.StatusForbidden {
		t.Fatalf("web get pairing status=%d want 403", denied.Code)
	}
	approve := env.do(t, http.MethodPost, "/v1/pairing/requests/"+pending.ID+"/approve", nil, pair.AccessToken)
	if approve.Code != http.StatusOK {
		t.Fatalf("approve pairing status=%d", approve.Code)
	}
	var terminal w1Device
	decodeW1(t, approve.Body.Bytes(), &terminal)
	if terminal.ID == "" || terminal.Role != domain.RoleTerminal || terminal.Status != domain.DeviceActive {
		t.Fatalf("approved terminal metadata is invalid")
	}
	var approvedWithToken struct {
		ID     string      `json:"id"`
		Tokens w1TokenPair `json:"tokens"`
	}
	decodeW1(t, approve.Body.Bytes(), &approvedWithToken)
	if approvedWithToken.ID != terminal.ID || approvedWithToken.Tokens.DeviceID != terminal.ID || approvedWithToken.Tokens.AccessToken == "" {
		t.Fatalf("approved terminal token contract invalid: %+v", approvedWithToken)
	}

	devices := env.do(t, http.MethodGet, "/v1/devices", nil, pair.AccessToken)
	if devices.Code != http.StatusOK {
		t.Fatalf("list devices status=%d", devices.Code)
	}
	var listed struct {
		Devices []w1Device `json:"devices"`
	}
	decodeW1(t, devices.Body.Bytes(), &listed)
	if len(listed.Devices) != 2 || listed.Devices[0].ID == "" || owner.ID == "" {
		t.Fatalf("device list did not return two metadata records")
	}
	if containsStr(devices.Body.String(), "identity_public_key") || containsStr(devices.Body.String(), "terminal-identity-public") {
		t.Fatalf("device list must not expose pairing public keys")
	}
}

// PAIR-03：撤销设备会阻止其 bearer/refresh 使用及之后的 DEK 包装，但不改写历史包装记录。
func TestW1PAIR03RevokeStopsAccessRefreshAndNewKeyWrap(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-revoke@test.dev")
	owner := bootstrapW1Owner(t, env, pair.AccessToken)

	request := env.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "web", "display_name": "read-only web",
		"identity_public_key": "web-identity-public", "encryption_public_key": "web-encryption-public",
	}, pair.AccessToken)
	if request.Code != http.StatusCreated {
		t.Fatalf("create web pairing status=%d", request.Code)
	}
	var pending struct {
		ID string `json:"id"`
	}
	decodeW1(t, request.Body.Bytes(), &pending)
	approve := env.do(t, http.MethodPost, "/v1/pairing/requests/"+pending.ID+"/approve", nil, pair.AccessToken)
	if approve.Code != http.StatusOK {
		t.Fatalf("approve web pairing status=%d", approve.Code)
	}
	var web w1Device
	decodeW1(t, approve.Body.Bytes(), &web)

	// 配对传输完成时由服务端为已经验证过设备私钥的一侧签发 token。
	// 密码登录不能模拟该动作，否则测试会重新固化 device_id/role 提权漏洞。
	webTokens, err := domain.NewAuthService(env.repo).IssueForDevice(t.Context(), pair.AccountID, web.ID)
	if err != nil || webTokens.DeviceID != web.ID {
		t.Fatalf("issue paired web token: %v", err)
	}

	pairing := domain.NewPairingService(env.repo)
	if err := pairing.WrapDEKForDevice(t.Context(), owner.ID, "dek-w1", web.ID, []byte("wrapped-ciphertext")); err != nil {
		t.Fatalf("pre-revoke key wrap: %v", err)
	}
	before, err := env.repo.ListKeyWraps(t.Context(), "dek-w1")
	if err != nil || len(before) != 1 {
		t.Fatalf("expected one historical key wrap")
	}

	revoke := env.do(t, http.MethodDelete, "/v1/devices/"+web.ID, nil, pair.AccessToken)
	if revoke.Code != http.StatusNoContent {
		t.Fatalf("revoke status=%d", revoke.Code)
	}
	if response := env.do(t, http.MethodGet, "/v1/devices", nil, webTokens.AccessToken); response.Code != http.StatusForbidden {
		t.Fatalf("revoked bearer status=%d want 403", response.Code)
	}
	if response := env.do(t, http.MethodPost, "/v1/auth/refresh", map[string]any{"refresh_token": webTokens.RefreshToken}, ""); response.Code != http.StatusForbidden {
		t.Fatalf("revoked refresh status=%d want 403", response.Code)
	}
	if err := pairing.WrapDEKForDevice(t.Context(), owner.ID, "dek-w1", web.ID, []byte("new-wrapped-ciphertext")); !errors.Is(err, domain.ErrDeviceRevoked) {
		t.Fatalf("post-revoke key wrap error=%v want device revoked", err)
	}
	after, err := env.repo.ListKeyWraps(t.Context(), "dek-w1")
	if err != nil || len(after) != 1 {
		t.Fatalf("historical key wrap must remain unchanged")
	}
}

// PAIR-02：同一个 pending 请求被并发批准时，只能创建一台设备，所有重试返回同一结果。
func TestW1PAIR02ConcurrentApproveCreatesOneDevice(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-concurrent-pair@test.dev")
	owner := bootstrapW1Owner(t, env, pair.AccessToken)

	request := env.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": "Concurrent terminal", "platform": "linux",
		"identity_public_key": "concurrent-terminal-identity", "encryption_public_key": "concurrent-terminal-encryption",
	}, pair.AccessToken)
	if request.Code != http.StatusCreated {
		t.Fatalf("create concurrent pairing status=%d", request.Code)
	}
	var pending struct {
		ID string `json:"id"`
	}
	decodeW1(t, request.Body.Bytes(), &pending)

	service := domain.NewPairingService(env.repo)
	subject := domain.AuthSubject{AccountID: pair.AccountID, DeviceID: owner.ID, Role: domain.RoleAndroidOwner, DeviceOK: true}
	type outcome struct {
		device domain.Device
		err    error
	}
	start := make(chan struct{})
	results := make(chan outcome, 2)
	var wait sync.WaitGroup
	for range 2 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			<-start
			device, err := service.ApprovePairing(context.Background(), subject, pending.ID)
			results <- outcome{device: device, err: err}
		}()
	}
	close(start)
	wait.Wait()
	close(results)

	var approvedID string
	for result := range results {
		if result.err != nil {
			t.Fatalf("concurrent approval error: %v", result.err)
		}
		if approvedID == "" {
			approvedID = result.device.ID
		} else if approvedID != result.device.ID {
			t.Fatalf("concurrent approval returned different device IDs: %s != %s", approvedID, result.device.ID)
		}
	}
	devices, err := env.repo.ListDevices(t.Context(), pair.AccountID)
	if err != nil {
		t.Fatalf("list devices after concurrent approval: %v", err)
	}
	if len(devices) != 2 {
		t.Fatalf("concurrent approval created %d devices, want owner + one paired device", len(devices))
	}
}

// PAIR-02 根因：approve 与 cancel 并发时只能完成一个 pending -> terminal 状态转移。
func TestW1PAIR02ApproveCancelRaceHasSingleWinner(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-pair-cancel-race@test.dev")
	owner := bootstrapW1Owner(t, env, pair.AccessToken)
	request := env.do(t, http.MethodPost, "/v1/pairing/requests", map[string]any{
		"role": "terminal", "display_name": "race terminal", "platform": "linux",
		"identity_public_key": "race-terminal-identity", "encryption_public_key": "race-terminal-encryption",
	}, pair.AccessToken)
	if request.Code != http.StatusCreated {
		t.Fatalf("create race pairing status=%d", request.Code)
	}
	var pending struct {
		ID string `json:"id"`
	}
	decodeW1(t, request.Body.Bytes(), &pending)

	service := domain.NewPairingService(env.repo)
	subject := domain.AuthSubject{AccountID: pair.AccountID, DeviceID: owner.ID, Role: domain.RoleAndroidOwner, DeviceOK: true}
	start := make(chan struct{})
	errs := make(chan error, 2)
	var wait sync.WaitGroup
	wait.Add(2)
	go func() {
		defer wait.Done()
		<-start
		_, err := service.ApprovePairing(context.Background(), subject, pending.ID)
		errs <- err
	}()
	go func() {
		defer wait.Done()
		<-start
		errs <- service.CancelPairing(context.Background(), subject, pending.ID)
	}()
	close(start)
	wait.Wait()
	close(errs)

	successes := 0
	handled := 0
	for err := range errs {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, domain.ErrPairingAlreadyHandled):
			handled++
		default:
			t.Fatalf("approve/cancel returned unexpected error: %v", err)
		}
	}
	if successes != 1 || handled != 1 {
		t.Fatalf("approve/cancel outcomes success=%d handled=%d, want 1/1", successes, handled)
	}
	latest, err := env.repo.PairingByID(t.Context(), pending.ID)
	if err != nil || (latest.Status != domain.PairingApproved && latest.Status != domain.PairingCancelled) {
		t.Fatalf("pairing terminal status=%q err=%v", latest.Status, err)
	}
}

// RECOVERY-01：恢复码只在生成时返回明文，恢复无 bearer、一次性消费并对失败次数限流。
func TestW1RecoveryCodeRestoreAndRateLimit(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-recovery@test.dev")
	bootstrapW1Owner(t, env, pair.AccessToken)

	generated := env.do(t, http.MethodPost, "/v1/recovery-codes", nil, pair.AccessToken)
	if generated.Code != http.StatusOK {
		t.Fatalf("generate recovery code status=%d", generated.Code)
	}
	var codeBody struct {
		RecoveryCode string `json:"recovery_code"`
	}
	decodeW1(t, generated.Body.Bytes(), &codeBody)
	if codeBody.RecoveryCode == "" {
		t.Fatalf("recovery code was not returned to owner")
	}

	restoreBody := map[string]any{
		"email": "w1-recovery@test.dev", "recovery_code": codeBody.RecoveryCode,
		"display_name": "recovered Android", "platform": "android",
		"identity_public_key":   "recovered-identity-public",
		"encryption_public_key": "recovered-encryption-public",
	}
	restored := env.do(t, http.MethodPost, "/v1/recovery-codes/restore", restoreBody, "")
	if restored.Code != http.StatusOK {
		t.Fatalf("restore recovery code status=%d", restored.Code)
	}
	var result struct {
		Device w1Device    `json:"device"`
		Tokens w1TokenPair `json:"tokens"`
	}
	decodeW1(t, restored.Body.Bytes(), &result)
	if result.Device.Role != domain.RoleAndroidOwner || result.Tokens.DeviceID != result.Device.ID || result.Tokens.AccessToken == "" {
		t.Fatalf("recovery did not issue an owner device-bound session")
	}
	if again := env.do(t, http.MethodPost, "/v1/recovery-codes/restore", restoreBody, ""); again.Code != http.StatusUnauthorized {
		t.Fatalf("consumed recovery code status=%d want 401", again.Code)
	}

	// 恢复码必须撤销旧 Android owner 的 bearer 与 refresh family，避免并行 key-admin。
	if response := env.do(t, http.MethodGet, "/v1/devices", nil, pair.AccessToken); response.Code != http.StatusForbidden {
		t.Fatalf("old owner bearer after recovery status=%d want 403", response.Code)
	}
	if response := env.do(t, http.MethodPost, "/v1/auth/refresh", map[string]any{"refresh_token": pair.RefreshToken}, ""); response.Code != http.StatusForbidden {
		t.Fatalf("old owner refresh after recovery status=%d want 403", response.Code)
	}

	second := env.do(t, http.MethodPost, "/v1/recovery-codes", nil, result.Tokens.AccessToken)
	if second.Code != http.StatusOK {
		t.Fatalf("generate second recovery code status=%d", second.Code)
	}
	for attempt := 1; attempt <= 5; attempt++ {
		response := env.do(t, http.MethodPost, "/v1/recovery-codes/restore", map[string]any{
			"email": "w1-recovery@test.dev", "recovery_code": "incorrect-recovery-code",
			"display_name": "new Android", "identity_public_key": "new-identity-public", "encryption_public_key": "new-encryption-public",
		}, "")
		want := http.StatusUnauthorized
		if attempt == 5 {
			want = http.StatusTooManyRequests
		}
		if response.Code != want {
			t.Fatalf("recovery failed attempt %d status=%d want %d", attempt, response.Code, want)
		}
	}
}

// RECOVERY-01 根因：恢复请求不得复用撤销设备的身份公钥；失败不能消费恢复码或撤销旧 owner。
func TestW1RecoveryRejectsExistingIdentityWithoutConsumingCode(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-recovery-identity@test.dev")
	bootstrapW1Owner(t, env, pair.AccessToken)

	generated := env.do(t, http.MethodPost, "/v1/recovery-codes", nil, pair.AccessToken)
	if generated.Code != http.StatusOK {
		t.Fatalf("generate recovery code status=%d", generated.Code)
	}
	var codeBody struct {
		RecoveryCode string `json:"recovery_code"`
	}
	decodeW1(t, generated.Body.Bytes(), &codeBody)
	duplicate := map[string]any{
		"email": "w1-recovery-identity@test.dev", "recovery_code": codeBody.RecoveryCode,
		"display_name": "duplicate Android", "platform": "android",
		"identity_public_key": "owner-identity-public", "encryption_public_key": "owner-encryption-public",
	}
	if response := env.do(t, http.MethodPost, "/v1/recovery-codes/restore", duplicate, ""); response.Code != http.StatusConflict {
		t.Fatalf("duplicate identity restore status=%d want 409 body=%s", response.Code, response.Body.String())
	}
	// 同一恢复码仍能用于新的候选身份，证明冲突请求没有破坏旧 owner 或消费凭据。
	valid := map[string]any{
		"email": "w1-recovery-identity@test.dev", "recovery_code": codeBody.RecoveryCode,
		"display_name": "new Android", "platform": "android",
		"identity_public_key": "new-owner-identity", "encryption_public_key": "new-owner-encryption",
	}
	if response := env.do(t, http.MethodPost, "/v1/recovery-codes/restore", valid, ""); response.Code != http.StatusOK {
		t.Fatalf("new identity restore status=%d want 200 body=%s", response.Code, response.Body.String())
	}
}

// HTTP-03：logout 的 refresh_token 是协议必填项，空请求不能静默标记为成功。
func TestW1LogoutRequiresRefreshToken(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-logout@test.dev")
	response := env.do(t, http.MethodPost, "/v1/auth/logout", map[string]any{}, pair.AccessToken)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("logout without refresh token status=%d want 400", response.Code)
	}
}

// HTTP-03 根因：携带有效 bearer 的账号也不能用其他账号 refresh family 触发跨账号注销。
func TestW1LogoutCannotRevokeOtherAccountFamily(t *testing.T) {
	env := newTestEnv(t)
	caller := env.registerAs(t, "w1-logout-caller@test.dev")
	victim := env.provisionAdditionalAccount(t, "w1-logout-victim@test.dev")

	response := env.do(t, http.MethodPost, "/v1/auth/logout", map[string]any{
		"refresh_token": victim.RefreshToken,
	}, caller.AccessToken)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("cross-account logout status=%d want 401", response.Code)
	}
	if refresh := env.do(t, http.MethodPost, "/v1/auth/refresh", map[string]any{
		"refresh_token": victim.RefreshToken,
	}, ""); refresh.Code != http.StatusOK {
		t.Fatalf("victim refresh after cross-account logout status=%d want 200", refresh.Code)
	}
}

// MODE-01：能力读取使用 providers 包装和 status 三态，避免客户端按旧 state 数组契约解析。
func TestW1CapabilitiesUseProviderEnvelope(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-capabilities@test.dev")
	response := env.do(t, http.MethodGet, "/v1/capabilities", nil, pair.AccessToken)
	if response.Code != http.StatusOK {
		t.Fatalf("capabilities status=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Providers []struct {
			Kind         string `json:"kind"`
			Capabilities []struct {
				Name   string `json:"name"`
				Status string `json:"status"`
			} `json:"capabilities"`
		} `json:"providers"`
	}
	decodeW1(t, response.Body.Bytes(), &body)
	if len(body.Providers) != 4 || body.Providers[0].Kind == "" || len(body.Providers[0].Capabilities) == 0 || body.Providers[0].Capabilities[0].Status == "" {
		t.Fatalf("capabilities provider envelope is incomplete")
	}
	if containsStr(response.Body.String(), `"state"`) {
		t.Fatalf("capabilities response must use status, not legacy state")
	}
}

// READ-01：Android 可读取账号范围内的元数据和密文快照，不能读取其他账号会话。
func TestW1ReadAPIsUseStableJSONAndAccountScope(t *testing.T) {
	env := newTestEnv(t)
	pair := env.registerAs(t, "w1-read@test.dev")
	bootstrapW1Owner(t, env, pair.AccessToken)
	sessionID, _ := env.createSession(t, pair.AccessToken, pair.AccountID)
	service := domain.NewSessionService(env.repo)
	if _, err := service.AppendEvent(t.Context(), sessionID, "assistant.delta", `{"ciphertext":"fixture"}`); err != nil {
		t.Fatalf("append fixture event: %v", err)
	}

	for _, path := range []string{"/v1/projects", "/v1/workspaces", "/v1/sessions", "/v1/terminals"} {
		response := env.do(t, http.MethodGet, path, nil, pair.AccessToken)
		if response.Code != http.StatusOK {
			t.Fatalf("read path %s status=%d", path, response.Code)
		}
		if containsStr(response.Body.String(), `"ID"`) || containsStr(response.Body.String(), `"AccountID"`) {
			t.Fatalf("read path %s did not use stable public JSON fields", path)
		}
	}

	snapshot := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/snapshot?after_seq=0", nil, pair.AccessToken)
	if snapshot.Code != http.StatusOK {
		t.Fatalf("snapshot status=%d", snapshot.Code)
	}
	var body struct {
		Session struct {
			ID      string `json:"id"`
			LastSeq int64  `json:"last_seq"`
		} `json:"session"`
		Events []struct {
			EventSeq int64 `json:"event_seq"`
		} `json:"events"`
	}
	decodeW1(t, snapshot.Body.Bytes(), &body)
	if body.Session.ID != sessionID || body.Session.LastSeq < 2 || len(body.Events) < 2 || body.Events[0].EventSeq <= 0 {
		t.Fatalf("snapshot did not return ordered session events")
	}

	other := env.provisionAdditionalAccount(t, "w1-read-other@test.dev")
	if response := env.do(t, http.MethodGet, "/v1/sessions/"+sessionID+"/snapshot", nil, other.AccessToken); response.Code != http.StatusForbidden {
		t.Fatalf("cross-account snapshot status=%d want 403", response.Code)
	}
}
