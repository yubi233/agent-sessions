package domain

import (
	"context"
	"testing"
)

// V085-25 回归：lease 续期/接管不得影响在飞回合的事件投递。
//
// 事故（2026-09-04）：同设备重取 lease 使 epoch+1 并作废在飞 session.send，
// 回合尾部事件被 UploadEvent 的 epoch fence 以 409 永久拒收
// （RELAY_REJECTED_PERMANENT 死信），客户端永远停在 streaming。
// 修复后：同设备重取是幂等续期（epoch 不变、不作废命令）；跨设备接管作废旧
// epoch 命令（fail-closed），但事实性事件仍照常投递——客户端必须最终收到
// turn 终态。

// 同设备续期：epoch 不变，在飞命令保持 running，续期后的新命令以同一 epoch 正常准入。
func TestV085LeaseRenewalKeepsInFlightCommands(t *testing.T) {
	_, repo, sessionID, commandID := newDaemonEventStatusFixture(t)
	sessions := NewSessionService(repo)
	ctx := context.Background()

	renewed, err := sessions.AcquireLease(ctx, sessionID, "dev-daemon-status", "")
	if err != nil {
		t.Fatalf("renew lease: %v", err)
	}
	if renewed != 1 {
		t.Fatalf("renewed epoch=%d want unchanged 1", renewed)
	}
	cmd, err := repo.CommandByID(ctx, commandID)
	if err != nil || cmd.Status != CommandRunning {
		t.Fatalf("in-flight command after renewal=%+v err=%v want running", cmd, err)
	}
	if _, err := sessions.SubmitCommand(ctx, CommandInput{
		AccountID: "acct-daemon-status", DeviceID: "dev-daemon-status", Role: RoleAndroidOwner,
		SessionID: sessionID, Kind: "session.abort", IdempotencyKey: "v085-renew-admit",
		LeaseEpoch: renewed, TargetInstanceID: "inst-daemon-status",
	}); err != nil {
		t.Fatalf("command admission after renewal: %v", err)
	}
}

// 跨设备接管：旧 epoch 命令被作废（fail-closed），但其所属回合的事件仍照常投递；
// 事件幂等与 session last_seq 语义不变。
func TestV085TakeoverExpiresCommandButEventsStillDeliver(t *testing.T) {
	_, repo, sessionID, commandID := newDaemonEventStatusFixture(t)
	sessions := NewSessionService(repo)
	ctx := context.Background()

	if _, err := sessions.AcquireLease(ctx, sessionID, "dev-other-device", ""); err != nil {
		t.Fatalf("takeover lease: %v", err)
	}
	cmd, err := repo.CommandByID(ctx, commandID)
	if err != nil || cmd.Status != CommandExpired {
		t.Fatalf("in-flight command after takeover=%+v err=%v want expired", cmd, err)
	}

	daemons := NewDaemonService(repo)
	upload := daemonStatusEventInputForEvent(sessionID, commandID, "turn.completed", SessionIdle, "evt-v085-takeover")
	result, err := daemons.UploadEvent(ctx, upload)
	if err != nil {
		t.Fatalf("upload turn.completed after takeover: %v", err)
	}
	if result.EventSeq <= 0 {
		t.Fatalf("event seq=%d want positive", result.EventSeq)
	}
	replay, err := daemons.UploadEvent(ctx, upload)
	if err != nil || !replay.Idempotent || replay.EventSeq != result.EventSeq {
		t.Fatalf("event replay=%+v err=%v want idempotent same seq", replay, err)
	}

	// v0.8.4 流式事件类型（thought/phase）必须与 events.json 枚举一致——白名单
	// 缺口曾把真实流式回合的 reasoning/相位帧全部打成 400 死信。
	for _, eventType := range []string{"message.thought_delta", "turn.phase"} {
		input := daemonStatusEventInputForEvent(sessionID, commandID, eventType, "", "evt-v085-"+eventType)
		if _, err := daemons.UploadEvent(ctx, input); err != nil {
			t.Fatalf("upload %s: %v", eventType, err)
		}
	}
}
