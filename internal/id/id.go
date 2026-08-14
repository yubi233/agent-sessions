package id

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"
)

// New 生成带前缀的不透明 ID。排序以数据库序号为准。
func New(prefix string) string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("%s_%d_%s", prefix, time.Now().UnixMilli(), hex.EncodeToString(b[:]))
}
