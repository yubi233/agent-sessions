package dsh

import (
	"context"
	"errors"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/yubi233/agent-sessions/internal/adapter"
)

// 桥已 EOF 时响应永远不会到达，不能等到握手超时才向能力查询返回失败。
func TestV094BridgeEOFReleasesPendingRequests(t *testing.T) {
	bridge := newFakeBridge()
	h := newHandle(bridge)
	go h.readLoop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := h.request(ctx, "initialize", nil)
			result <- err
		}()
	}
	for range 2 {
		select {
		case <-bridge.outCh:
		case <-ctx.Done():
			t.Fatal("请求未发出")
		}
	}
	_ = bridge.Close()
	for range 2 {
		select {
		case err := <-result:
			if !errors.Is(err, adapter.ErrBridgeClosed) {
				t.Fatalf("预期桥关闭哨兵，不能等待 context 超时: %v", err)
			}
		case <-time.After(200 * time.Millisecond):
			t.Fatal("桥退出未立即释放 pending 请求")
		}
	}
	<-h.readDone
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.pending) != 0 {
		t.Fatalf("遗留 pending=%d", len(h.pending))
	}
}

type eofTrackedBridge struct {
	*fakeBridge
	closes atomic.Int32
}

func (b *eofTrackedBridge) Close() error {
	b.closes.Add(1)
	return b.fakeBridge.Close()
}

// 读循环的 closed 只代表协议不可用，不代表 OS 子进程已 Wait、临时目录已回收。
func TestV094DisposeAfterEOFStillReapsTransport(t *testing.T) {
	bridge := &eofTrackedBridge{fakeBridge: newFakeBridge()}
	h := newHandle(bridge)
	go h.readLoop()
	_ = bridge.fakeBridge.Close()
	<-h.readDone
	if err := h.Dispose(context.Background()); err != nil {
		t.Fatal(err)
	}
	if bridge.closes.Load() == 0 {
		t.Fatal("EOF 后 Dispose 跳过 transport.Close，进程资源未回收")
	}
}

func TestV094EOFDisposeReapsRealProcessAndTemporaryRoot(t *testing.T) {
	tr, pid := startShTransport(t, "read line; exit 1", nil, 100*time.Millisecond)
	h := newHandle(tr)
	go h.readLoop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := h.request(ctx, "initialize", nil)
	if !errors.Is(err, adapter.ErrBridgeClosed) {
		t.Fatalf("桥退出应释放请求: %v", err)
	}
	_ = h.Dispose(context.Background())
	awaitPidGone(t, pid, time.Second)
	if _, err := os.Stat(tr.persistRoot); !os.IsNotExist(err) {
		t.Fatalf("探测临时目录应回收: %v", err)
	}
}
