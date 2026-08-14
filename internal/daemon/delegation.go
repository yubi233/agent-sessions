package daemon

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
	"github.com/yubi233/agent-sessions/internal/domain"
)

// DeterministicDelegationDispatcher 是本地 full gate 的 Provider 边界。
// 它只用 MockAdapter 模拟不同 provider kind，绝不把它当作 Claude/Codex 等真实 Provider 成功证据。
type DeterministicDelegationDispatcher struct {
	adapter adapter.Adapter

	mu      sync.Mutex
	handles map[string]adapter.Handle
}

// NewDeterministicDelegationDispatcher 构造可重复、无凭据的跨 Provider mock dispatcher。
func NewDeterministicDelegationDispatcher() *DeterministicDelegationDispatcher {
	return &DeterministicDelegationDispatcher{
		adapter: adapter.NewMockAdapter(),
		handles: map[string]adapter.Handle{},
	}
}

// ValidateTarget 只允许本轮 fixture 注册的目标。未知或真实未授权 Provider 明确拒绝，不能降级到 shell。
func (d *DeterministicDelegationDispatcher) ValidateTarget(ctx context.Context, parentProvider, targetProvider string) error {
	_ = ctx
	_ = parentProvider
	switch targetProvider {
	case "mock", "claude", "codex", "opencode", "openclaw":
		return nil
	default:
		return domain.ErrDelegationUnsupported
	}
}

// Start 创建独立 mock handle 并读取第一条 canonical turn_started 事件取得 child instance id。
// 任务书仍是密文 JSON，只在进程内传给 mock adapter，不能写入日志、Relay 事件或本地 outbox。
func (d *DeterministicDelegationDispatcher) Start(ctx context.Context, request domain.DelegationDispatchRequest) (domain.DelegationDispatchResult, error) {
	if err := d.ValidateTarget(ctx, "", request.TargetProvider); err != nil {
		return domain.DelegationDispatchResult{}, err
	}
	if request.DelegationID == "" || request.ChildSessionID == "" || len(request.TaskEnvelope) == 0 {
		return domain.DelegationDispatchResult{}, errors.New("delegation dispatch request is incomplete")
	}
	startupContext, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	handle, err := d.adapter.Start(startupContext, adapter.StartRequest{
		WorkspaceRoot: request.WorkspaceID,
		Provider:      request.TargetProvider,
		// StartRequest 明确允许密文；mock 不会记录或回显该字段。
		Prompt: string(request.TaskEnvelope),
	})
	if err != nil {
		return domain.DelegationDispatchResult{}, err
	}

	var instanceID string
	select {
	case event, ok := <-handle.Events():
		if !ok || event.Type != adapter.EventTurnStarted {
			_ = handle.Dispose(context.Background())
			return domain.DelegationDispatchResult{}, errors.New("mock child did not emit turn_started")
		}
		instanceID, _ = event.Payload["instance_id"].(string)
	case <-startupContext.Done():
		_ = handle.Dispose(context.Background())
		return domain.DelegationDispatchResult{}, startupContext.Err()
	}
	if instanceID == "" {
		_ = handle.Dispose(context.Background())
		return domain.DelegationDispatchResult{}, errors.New("mock child did not return an instance id")
	}

	// mock 仍会继续发送少量内部事件；只 drain，不保存或投影到 parent Session。
	go func() {
		for range handle.Events() {
		}
	}()
	d.mu.Lock()
	d.handles[request.DelegationID] = handle
	d.mu.Unlock()
	return domain.DelegationDispatchResult{InstanceID: instanceID}, nil
}

// Stop 是 terminal 状态后的受控清理。未知 delegation 视为已清理，保持取消/失败回收幂等。
func (d *DeterministicDelegationDispatcher) Stop(ctx context.Context, delegationID string) error {
	d.mu.Lock()
	handle := d.handles[delegationID]
	delete(d.handles, delegationID)
	d.mu.Unlock()
	if handle == nil {
		return nil
	}
	return handle.Dispose(ctx)
}
