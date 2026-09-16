package daemon

// V092-07 / V092-08 回归（v0.9.2 P2）：会话生命周期与错误可区分性。
//
// 本轮把"发送前自动恢复"的语义从 start 改为 resume（T3 裁决），因此这里钉扎
// 三类容易退化的行为：
//   1) 恢复必须续接**原 instance**（不新建、不覆盖映射）；
//   2) "结果自报成功但没有可用实例"必须与"映射不存在"归为同一类可重试错误
//      （LOCAL_STATE_MISSING），而真实执行失败保持自己的类别；
//   3) 并发/重复恢复必须串行化，且异常退出后状态不悬挂。
//
// 只使用 fixture adapter，不启动真实 Provider、不发送 prompt。

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

// (V092-06/07) resume 的三种失败形态必须可区分：
//   - 无映射           → ErrSessionInstanceMissing（客户端据此回退 start）；
//   - 自报成功无句柄   → ErrSessionInstanceMissing（同一类，可重试重建）；
//   - adapter 显式报错 → 原样透出（真实执行失败，不得被降级为重试）。
func TestV092ResumeFailureClassesAreDistinguishable(t *testing.T) {
	t.Run("无映射时返回本地实例缺失", func(t *testing.T) {
		_, runner, _ := newRunnerFixture(t, "dsh")
		err := runner.ConsumeCommand(context.Background(), Command{
			Kind:        "session.resume",
			PayloadJSON: `{"session_id":"ghost","workspace_root":"/tmp/v092-ws"}`,
		})
		if !errors.Is(err, ErrSessionInstanceMissing) {
			t.Fatalf("无映射必须返回 ErrSessionInstanceMissing: %v", err)
		}
	})

	t.Run("自报成功但无句柄归入同一类", func(t *testing.T) {
		s, runner, _ := newRunnerFixture(t, "dsh")
		if err := runner.ConsumeCommand(context.Background(), Command{
			Kind: "session.start",
			PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/v092-ws","provider":"dsh",` +
				`"ciphertext":{"fixture_payload":{"prompt":"hi"}}}`,
		}); err != nil {
			t.Fatalf("start: %v", err)
		}
		// 模拟进程重启：store 保留映射，内存句柄释放；非流式 adapter 无法交出句柄。
		if err := runner.Close(context.Background()); err != nil {
			t.Fatalf("close: %v", err)
		}
		restarted := v092RestartRunner(t, s, "dsh", newFakeAdapter("dsh"))
		err := restarted.ConsumeCommand(context.Background(), Command{
			Kind:        "session.resume",
			PayloadJSON: `{"session_id":"s1","workspace_root":"/tmp/v092-ws"}`,
		})
		if !errors.Is(err, ErrSessionInstanceMissing) {
			t.Fatalf("无句柄必须归入同一类可重试错误: %v", err)
		}
	})

	t.Run("adapter 显式失败保持真实失败类别", func(t *testing.T) {
		s, runner, _ := newRunnerFixture(t, "dsh")
		if err := runner.ConsumeCommand(context.Background(), Command{
			Kind: "session.start",
			PayloadJSON: `{"session_id":"s2","workspace_root":"/tmp/v092-ws","provider":"dsh",` +
				`"ciphertext":{"fixture_payload":{"prompt":"hi"}}}`,
		}); err != nil {
			t.Fatalf("start: %v", err)
		}
		if err := runner.Close(context.Background()); err != nil {
			t.Fatalf("close: %v", err)
		}
		failing := &failingStreamingAdapter{
			fakeAdapter: newFakeAdapter("dsh"),
			err:         errors.New("桥版本 9.9.9 不在已登记白名单内"),
		}
		restarted := v092RestartRunner(t, s, "dsh", failing)
		err := restarted.ConsumeCommand(context.Background(), Command{
			Kind:        "session.resume",
			PayloadJSON: `{"session_id":"s2","workspace_root":"/tmp/v092-ws"}`,
		})
		if err == nil {
			t.Fatal("adapter 显式失败必须返回错误")
		}
		if errors.Is(err, ErrSessionInstanceMissing) {
			t.Fatalf("真实执行失败不得被降级为可重试的实例缺失: %v", err)
		}
		if !strings.Contains(err.Error(), "9.9.9") {
			t.Fatalf("失败原因必须保留可诊断细节: %v", err)
		}
		if _, getErr := s.Get(resumeResultKey("s2")); getErr == nil {
			t.Fatal("失败恢复不得写入成功唤醒结果")
		}
	})
}

// (V092-08) 并发恢复必须串行化：executionMu 保证同一 Daemon 的命令兑现不并发改写
// 同一会话的本地映射与句柄，最终只留下一个可用句柄且映射未被破坏。
func TestV092ResumeConcurrentIsSerialized(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"c1","workspace_root":"/tmp/v092-ws","provider":"dsh",` +
			`"ciphertext":{"fixture_payload":{"prompt":"hi"}}}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := runner.Close(context.Background()); err != nil {
		t.Fatalf("close: %v", err)
	}
	streamFake := newStreamingFakeAdapter("dsh")
	restarted := v092RestartRunner(t, s, "dsh", streamFake)

	const parallel = 4
	var wg sync.WaitGroup
	errs := make([]error, parallel)
	for i := 0; i < parallel; i++ {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			errs[index] = restarted.ConsumeCommand(context.Background(), Command{
				Kind:        "session.resume",
				PayloadJSON: `{"session_id":"c1","workspace_root":"/tmp/v092-ws"}`,
			})
		}(i)
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("并发恢复 #%d 失败: %v", i, err)
		}
	}
	// 映射仍指向原 instance（并发恢复不得重建实例）。
	mapping := v092ReadMapping(t, s, "c1")
	if mapping.InstanceID != "instance-1" {
		t.Fatalf("并发恢复后映射必须保持原 instance: %#v", mapping)
	}
	// 恢复完成后 send 立即可用（句柄确实登记过，不是"表面成功"）。
	if err := restarted.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"c1","ciphertext":{"fixture_payload":{"message":"恢复后"}}}`,
	}); err != nil {
		t.Fatalf("恢复后 send 必须成功: %v", err)
	}
	streamFake.mu.Lock()
	resumeCalls := len(streamFake.resumes)
	streamFake.mu.Unlock()
	if resumeCalls != parallel {
		t.Fatalf("每次 resume 命令都应到达 adapter（串行化而非合并语义）: %d", resumeCalls)
	}
	_ = fake
}

// (V092-08) 桥异常退出后：本地映射不被改写（恢复必须先 resume），
// 且失败以可见终态收口（不悬挂在"生成中"）。
func TestV092BridgeExitKeepsMappingAndClosesTurn(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind: "session.start",
		PayloadJSON: `{"session_id":"b1","workspace_root":"/tmp/v092-ws","provider":"dsh",` +
			`"ciphertext":{"fixture_payload":{"prompt":"hi"}}}`,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}
	before := v092ReadMapping(t, s, "b1")
	handle := v092LastHandle(t, fake)
	handle.injectSendError(errors.New("bridge exited"))

	if err := runner.ConsumeCommand(context.Background(), Command{
		Kind:        "session.send",
		PayloadJSON: `{"session_id":"b1","ciphertext":{"fixture_payload":{"message":"桥已退出"}}}`,
	}); err == nil {
		t.Fatal("桥退出后 send 必须失败")
	}
	// 映射保持不变：send 不会静默改走 resume 或重建实例。
	after := v092ReadMapping(t, s, "b1")
	if after != before {
		t.Fatalf("桥退出不得改写实例映射: %#v → %#v", before, after)
	}
	// 失败终态落库，客户端重连后仍能看到失败事实。
	waitEvent(t, s, "b1", "turn_completed")
}

// (对照) 重复 start 回收旧句柄：DCM-03 既有语义在 v0.9.2 不明显回退。
func TestV092RepeatedStartReclaimsHandle(t *testing.T) {
	s, runner, fake := newRunnerFixture(t, "dsh")
	start := func() {
		t.Helper()
		if err := runner.ConsumeCommand(context.Background(), Command{
			Kind: "session.start",
			PayloadJSON: `{"session_id":"r1","workspace_root":"/tmp/v092-ws","provider":"dsh",` +
				`"ciphertext":{"fixture_payload":{"prompt":"hi"}}}`,
		}); err != nil {
			t.Fatalf("start: %v", err)
		}
	}
	start()
	first := v092LastHandle(t, fake)
	start()
	second := v092LastHandle(t, fake)
	if first == second {
		t.Fatal("重复 start 必须新建句柄（不能被静默忽略）")
	}
	if !first.wasDisposedNow() {
		t.Fatal("重复 start 必须回收旧句柄")
	}
	// 映射指向新实例（覆盖语义保留）。
	if mapping := v092ReadMapping(t, s, "r1"); mapping.InstanceID == "instance-1" {
		t.Fatalf("重复 start 后映射应指向新实例: %#v", mapping)
	}
}
