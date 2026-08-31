package dsh

// 本文件只处理 DSH JSONL artifact 的本机预检与非破坏性迁移。
// 它不解析/上传事件正文，也不触碰 session-query.db；查询索引由 DSH 在新根自行重建。

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf16"

	"github.com/klauspost/compress/zstd"
)

const (
	maxSessionHeaderBytes = 1 << 20
	maxMigrationBytes     = 512 << 20
	legacyRootsEnv        = "AGENT_SESSIONS_DSH_LEGACY_ROOTS"
	// DSH 当前 session-persistence-jsonl 的格式版本来自 core/session/types.ts。
	// 未来版本必须先升级适配器，不能把未知格式当作可恢复事实。
	supportedSessionHeaderVersion = 0
)

const (
	// PersistenceCompressionNone 表示未压缩的 JSONL artifact。
	PersistenceCompressionNone = "none"
	// PersistenceCompressionZstd 表示分帧 Zstandard artifact。
	PersistenceCompressionZstd = "zstd"
)

// SessionArtifact 是 DSH artifact 的脱敏投影。Path 仅供本机迁移使用，不能进入 Relay 或报告。
type SessionArtifact struct {
	ID          string
	CWD         string
	Path        string
	Compression string // none | zstd
	Size        int64
	ModTime     time.Time
	Digest      string
}

// MigrationReport 只含计数/稳定分类，不含正文和路径。
type MigrationReport struct {
	Scanned         int
	Matched         int
	Copied          int
	AlreadyPresent  int
	Skipped         int
	Conflicts       int
	SourceChanged   int
	Unsupported     int
	ConflictReasons map[string]int
}

type sessionHeader struct {
	Type            string `json:"type"`
	Version         int    `json:"version"`
	ID              string `json:"id"`
	CreatedAt       int64  `json:"createdAt"`
	CWD             string `json:"cwd"`
	DelegationDepth int    `json:"delegationDepth"`
}

type artifactRevision struct {
	Size    int64
	ModTime time.Time
	Digest  string
}

// ScanSessionArtifacts 递归扫描一个 DSH 持久化根目录。不会跟随符号链接，
// 只读取 session.jsonl 的首行和文件版本；压缩 artifact 只解压首行，不读取正文。
func ScanSessionArtifacts(root string) ([]SessionArtifact, error) {
	out, _, err := scanSessionArtifacts(root)
	return out, err
}

// scanSessionArtifacts 扫描并返回有效 artifact，同时统计无法解析的文件数量。
// 无效文件不会被当作事实，也不会阻断同一根目录中其他有效会话的清点。
func scanSessionArtifacts(root string) ([]SessionArtifact, int, error) {
	root = strings.TrimSpace(root)
	if root == "" {
		return nil, 0, errors.New("DSH persistence root 为空")
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, 0, err
	}
	info, err := os.Stat(root)
	if err != nil {
		return nil, 0, err
	}
	if !info.IsDir() {
		return nil, 0, errors.New("DSH persistence root 不是目录")
	}
	var out []SessionArtifact
	invalid := 0
	err = filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if path != root && entry.Type()&os.ModeSymlink != 0 {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 || !isSessionArtifactName(entry.Name()) {
			return nil
		}
		artifact, err := readArtifact(root, path)
		if err != nil {
			// 无效或写入中的 artifact 不能作为事实；继续扫描同级文件，迁移调用方
			// 可通过预检报告呈现跳过数量。
			invalid++
			return nil
		}
		out = append(out, artifact)
		return nil
	})
	if err != nil {
		return nil, invalid, err
	}
	return out, invalid, nil
}

func isSessionArtifactName(name string) bool {
	return name == "session.jsonl" || name == "session.jsonl.zstd"
}

func readArtifact(root, path string) (SessionArtifact, error) {
	info, err := os.Stat(path)
	if err != nil {
		return SessionArtifact{}, err
	}
	if info.Mode()&os.ModeType != 0 {
		return SessionArtifact{}, errors.New("artifact 不是普通文件")
	}
	compression := "none"
	file, err := os.Open(path)
	if err != nil {
		return SessionArtifact{}, err
	}
	defer file.Close()
	var input io.Reader = file
	if strings.HasSuffix(path, ".jsonl.zstd") {
		compression = "zstd"
		decoder, decodeErr := zstd.NewReader(file)
		if decodeErr != nil {
			return SessionArtifact{}, fmt.Errorf("zstd artifact 无法解压: %w", decodeErr)
		}
		defer decoder.Close()
		input = decoder
	}
	scanner := bufio.NewScanner(io.LimitReader(input, maxSessionHeaderBytes))
	scanner.Buffer(make([]byte, 4096), maxSessionHeaderBytes)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return SessionArtifact{}, err
		}
		return SessionArtifact{}, errors.New("artifact 缺少 header")
	}
	var header sessionHeader
	if err := json.Unmarshal(scanner.Bytes(), &header); err != nil {
		return SessionArtifact{}, fmt.Errorf("header JSON 无效: %w", err)
	}
	if header.Type != "session" || header.Version != supportedSessionHeaderVersion ||
		strings.TrimSpace(header.ID) == "" || strings.TrimSpace(header.CWD) == "" || !filepath.IsAbs(header.CWD) ||
		header.CreatedAt < 0 || header.DelegationDepth < 0 {
		return SessionArtifact{}, errors.New("header 缺少有效 type/id/cwd")
	}
	if err := validateArtifactPath(root, path, header, compression); err != nil {
		return SessionArtifact{}, err
	}
	revision, err := hashRevision(path, info)
	if err != nil {
		return SessionArtifact{}, err
	}
	return SessionArtifact{
		ID:          header.ID,
		CWD:         filepath.Clean(header.CWD),
		Path:        path,
		Compression: compression,
		Size:        revision.Size,
		ModTime:     revision.ModTime,
		Digest:      revision.Digest,
	}, nil
}

// validateArtifactPath 对齐 DSH 的 projectDir/sessionDir/logPath 布局，防止只改文件名
// 或目录名就伪造另一工作区/会话。调用方已经拒绝符号链接，因此这里只需比较规范段名。
func validateArtifactPath(root, path string, header sessionHeader, compression string) error {
	wantName := "session.jsonl"
	if compression == "zstd" {
		wantName = "session.jsonl.zstd"
	}
	if filepath.Base(path) != wantName {
		return errors.New("artifact 文件名与压缩格式不一致")
	}
	sessionDir := filepath.Dir(path)
	if filepath.Base(sessionDir) != dshEncodeSegment(header.ID) {
		return errors.New("artifact 路径与 header id 不一致")
	}
	projectDir := filepath.Dir(sessionDir)
	if filepath.Base(projectDir) != dshProjectKey(filepath.Clean(header.CWD)) {
		return errors.New("artifact 路径与 header cwd 不一致")
	}
	// DSH backend 的 artifact 必须正好位于 project/session 两级目录下；
	// 更深层的同名文件不属于该根，避免扫描器把嵌套源码目录误认成会话。
	if filepath.Clean(filepath.Dir(projectDir)) != filepath.Clean(root) {
		return errors.New("artifact 路径层级不符合 DSH 布局")
	}
	return nil
}

func hashRevision(path string, before os.FileInfo) (artifactRevision, error) {
	file, err := os.Open(path)
	if err != nil {
		return artifactRevision{}, err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		_ = file.Close()
		return artifactRevision{}, err
	}
	if err := file.Close(); err != nil {
		return artifactRevision{}, err
	}
	after, err := os.Stat(path)
	if err != nil {
		return artifactRevision{}, err
	}
	if before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return artifactRevision{}, errors.New("artifact 在读取期间发生变化")
	}
	return artifactRevision{Size: after.Size(), ModTime: after.ModTime(), Digest: hex.EncodeToString(hash.Sum(nil))}, nil
}

// MigrateLegacySessions 把 roots 中属于 workspaceRoot 的 JSONL artifact 复制到 dstRoot。
// roots 只读；目标文件不覆盖，源文件从不删除；默认保留每个源 artifact 的压缩格式。
func MigrateLegacySessions(dstRoot, workspaceRoot string, roots []string) (MigrationReport, error) {
	return migrateLegacySessions(dstRoot, workspaceRoot, roots, "")
}

// MigrateLegacySessionsToCompression 把匹配 workspace 的旧 artifact 迁移为指定的
// DSH 目标压缩格式。DSH backend 会拒绝另一种后缀，因此工作区启动前必须使用该
// 入口让目标后缀与 cordis 配置保持一致；源文件始终保留不变。
func MigrateLegacySessionsToCompression(dstRoot, workspaceRoot string, roots []string, compression string) (MigrationReport, error) {
	compression = strings.TrimSpace(compression)
	if compression != PersistenceCompressionNone && compression != PersistenceCompressionZstd {
		return MigrationReport{ConflictReasons: map[string]int{}}, fmt.Errorf("不支持的目标压缩格式 %q", compression)
	}
	return migrateLegacySessions(dstRoot, workspaceRoot, roots, compression)
}

func migrateLegacySessions(dstRoot, workspaceRoot string, roots []string, targetCompression string) (MigrationReport, error) {
	var report MigrationReport
	report.ConflictReasons = map[string]int{}
	dstRoot = strings.TrimSpace(dstRoot)
	workspaceRoot = strings.TrimSpace(workspaceRoot)
	if dstRoot == "" || workspaceRoot == "" || !filepath.IsAbs(dstRoot) || !filepath.IsAbs(workspaceRoot) {
		return report, errors.New("迁移根必须是绝对路径")
	}
	canonicalWorkspace, err := canonicalWorkspacePath(workspaceRoot)
	if err != nil {
		return report, err
	}
	if err := os.MkdirAll(dstRoot, 0o700); err != nil {
		return report, err
	}
	// 先完整收集并按 session id 分组，确认没有双编码或摘要冲突后再写目标；
	// 这样冲突会话不会出现“先复制一份、后发现冲突”的部分迁移。
	grouped := map[string][]SessionArtifact{}
	for _, root := range roots {
		artifacts, invalid, scanErr := scanSessionArtifacts(root)
		if scanErr != nil {
			return report, scanErr
		}
		report.Unsupported += invalid
		for _, artifact := range artifacts {
			report.Scanned++
			cwd, err := filepath.EvalSymlinks(artifact.CWD)
			if err != nil {
				report.Skipped++
				continue
			}
			cwd, err = filepath.Abs(cwd)
			if err != nil || cwd != canonicalWorkspace {
				report.Skipped++
				continue
			}
			report.Matched++
			grouped[artifact.ID] = append(grouped[artifact.ID], artifact)
		}
	}
	for id, artifacts := range grouped {
		if len(artifacts) == 0 {
			continue
		}
		prior := artifacts[0]
		conflictReason := ""
		for _, artifact := range artifacts[1:] {
			switch {
			case prior.Compression != artifact.Compression:
				conflictReason = "duplicate_id_dual_compression"
			case prior.Digest != artifact.Digest && conflictReason == "":
				conflictReason = "duplicate_id_digest_mismatch"
			}
		}
		if conflictReason != "" {
			report.Conflicts++
			report.ConflictReasons[conflictReason]++
			continue
		}
		compression := prior.Compression
		if targetCompression != "" {
			compression = targetCompression
		}
		filename := "session.jsonl"
		if compression == PersistenceCompressionZstd {
			filename = "session.jsonl.zstd"
		}
		destination := filepath.Join(dstRoot, dshProjectKey(canonicalWorkspace), dshEncodeSegment(id), filename)
		status, reason, copyErr := copyArtifactIfStable(prior, destination, compression, canonicalWorkspace)
		if copyErr != nil {
			return report, copyErr
		}
		switch status {
		case "copied":
			report.Copied++
		case "present":
			report.AlreadyPresent++
		case "source_changed":
			report.SourceChanged++
			report.ConflictReasons[reason]++
		case "conflict":
			report.Conflicts++
			report.ConflictReasons[reason]++
		}
	}
	return report, nil
}

func copyArtifactIfStable(source SessionArtifact, destination, targetCompression, canonicalCWD string) (status, reason string, err error) {
	if targetCompression != PersistenceCompressionNone && targetCompression != PersistenceCompressionZstd {
		return "", "", fmt.Errorf("不支持的目标压缩格式 %q", targetCompression)
	}
	before, err := os.Stat(source.Path)
	if err != nil {
		return "source_changed", "migration_source_changed", nil
	}
	if before.Size() != source.Size || !before.ModTime().Equal(source.ModTime) {
		return "source_changed", "migration_source_changed", nil
	}
	if before.Size() > maxMigrationBytes {
		return "source_changed", "migration_artifact_too_large", nil
	}
	raw, err := os.ReadFile(source.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return "source_changed", "migration_source_changed", nil
		}
		return "", "", err
	}
	after, err := os.Stat(source.Path)
	if err != nil || after.Size() != source.Size || !after.ModTime().Equal(source.ModTime) {
		return "source_changed", "migration_source_changed", nil
	}
	if got := digestBytes(raw); got != source.Digest {
		return "source_changed", "migration_source_changed", nil
	}
	payload, err := transcodeArtifactForWorkspace(raw, source.Compression, targetCompression, canonicalCWD)
	if err != nil {
		return "", "", err
	}
	if int64(len(payload)) > maxMigrationBytes {
		return "source_changed", "migration_artifact_too_large", nil
	}
	targetDigest := digestBytes(payload)
	// 目标目录中若已存在另一种后缀，DSH 会把整个根判定为编码冲突；
	// 不覆盖也不并存，等待人工清理或重新选择目标根。还要检查旧 cwd
	// 拼写形成的别名目录，避免 /var 与 /private/var 两套目录绕过这项守卫。
	if conflict, conflictReason, conflictErr := destinationEncodingConflict(destination, source, canonicalCWD); conflictErr != nil {
		return "", "", conflictErr
	} else if conflict {
		return "conflict", conflictReason, nil
	}
	if existing, statErr := os.Stat(destination); statErr == nil {
		if existing.Size() == int64(len(payload)) {
			digest, digestErr := fileDigest(destination)
			if digestErr == nil && digest == targetDigest {
				return "present", "", nil
			}
		}
		return "conflict", "digest_mismatch", nil
	} else if !os.IsNotExist(statErr) {
		return "", "", statErr
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return "", "", err
	}
	tmp, err := os.CreateTemp(filepath.Dir(destination), ".dsh-migrate-*")
	if err != nil {
		return "", "", err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	_, copyErr := tmp.Write(payload)
	if closeErr := tmp.Close(); copyErr == nil {
		copyErr = closeErr
	}
	if copyErr != nil {
		return "", "", copyErr
	}
	// 写入后重新采样 size、mtime 和摘要；只要检测到写入竞争，该 artifact
	// 就不能参与迁移，即使文件被替换后恰好保持相同大小也不能放行。
	after, err = os.Stat(source.Path)
	if err != nil || after.Size() != source.Size || !after.ModTime().Equal(source.ModTime) {
		return "source_changed", "migration_source_changed", nil
	}
	finalSourceDigest, digestErr := fileDigest(source.Path)
	if digestErr != nil || finalSourceDigest != source.Digest {
		return "source_changed", "migration_source_changed", nil
	}
	digest, err := fileDigest(tmpName)
	if err != nil {
		return "", "", err
	}
	if digest != targetDigest {
		return "source_changed", "migration_source_changed", nil
	}
	if err := os.Link(tmpName, destination); err != nil {
		if os.IsExist(err) {
			return copyArtifactIfStable(source, destination, targetCompression, canonicalCWD)
		}
		return "", "", err
	}
	return "copied", "", nil
}

// destinationEncodingConflict 检查 canonical cwd 与源 header cwd 可能形成的
// 两个项目目录；任一目录存在另一种压缩后缀都必须阻断迁移。
func destinationEncodingConflict(destination string, source SessionArtifact, canonicalCWD string) (bool, string, error) {
	root := filepath.Dir(filepath.Dir(filepath.Dir(destination)))
	projectKeys := []string{dshProjectKey(canonicalCWD), dshProjectKey(source.CWD)}
	seen := map[string]bool{}
	oppositeName := oppositeArtifactName(filepath.Base(destination))
	for _, projectKey := range projectKeys {
		projectDir := filepath.Join(root, projectKey, dshEncodeSegment(source.ID))
		if seen[projectDir] {
			continue
		}
		seen[projectDir] = true
		opposite := filepath.Join(projectDir, oppositeName)
		if _, err := os.Stat(opposite); err == nil {
			return true, "destination_dual_compression", nil
		} else if !os.IsNotExist(err) {
			return false, "", err
		}
	}
	return false, "", nil
}

// canonicalWorkspacePath 将工作区路径规约为真实绝对目录；DSH 会把 cwd
// 作为字符串写入 header 并在恢复时精确比较，因此创建、迁移和恢复必须共用这一口径。
func canonicalWorkspacePath(root string) (string, error) {
	root = strings.TrimSpace(root)
	if root == "" || !filepath.IsAbs(root) {
		return "", errors.New("workspace root 必须是绝对路径")
	}
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	canonical, err = filepath.Abs(canonical)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(canonical)
	if err != nil || !info.IsDir() {
		if err != nil {
			return "", err
		}
		return "", errors.New("workspace root 不是目录")
	}
	return filepath.Clean(canonical), nil
}

func digestBytes(value []byte) string {
	hash := sha256.Sum256(value)
	return hex.EncodeToString(hash[:])
}

func oppositeArtifactName(name string) string {
	if name == "session.jsonl.zstd" {
		return "session.jsonl"
	}
	return "session.jsonl.zstd"
}

// transcodeArtifact 在 plain 与 DSH 分帧 zstd 之间转换。zstd 目标必须把 header
// 和事件正文写成独立 frame，否则 DSH 的首帧校验会拒绝整个 artifact。
func transcodeArtifact(raw []byte, sourceCompression, targetCompression string) ([]byte, error) {
	return transcodeArtifactForWorkspace(raw, sourceCompression, targetCompression, "")
}

// transcodeArtifactForWorkspace 在转码时把 header.cwd 统一为实际工作区路径，
// 避免 macOS /var 与 /private/var 等符号链接拼写差异让 DSH resume 误报 cwd mismatch。
func transcodeArtifactForWorkspace(raw []byte, sourceCompression, targetCompression, canonicalCWD string) ([]byte, error) {
	if sourceCompression == targetCompression {
		if strings.TrimSpace(canonicalCWD) == "" {
			return append([]byte(nil), raw...), nil
		}
	}
	plain := raw
	if sourceCompression == PersistenceCompressionZstd {
		var err error
		plain, err = decodeZstdMigration(raw)
		if err != nil {
			return nil, err
		}
	}
	if strings.TrimSpace(canonicalCWD) != "" {
		var normalizeErr error
		plain, normalizeErr = normalizeArtifactCWD(plain, canonicalCWD)
		if normalizeErr != nil {
			return nil, normalizeErr
		}
	}
	if targetCompression == PersistenceCompressionNone {
		return plain, nil
	}
	newline := bytes.IndexByte(plain, '\n')
	if newline < 0 {
		return nil, errors.New("artifact header 缺少换行")
	}
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderCRC(true))
	if err != nil {
		return nil, fmt.Errorf("创建 zstd 编码器: %w", err)
	}
	headerFrame := encoder.EncodeAll(plain[:newline+1], nil)
	body := plain[newline+1:]
	if len(body) == 0 {
		encoder.Close()
		return headerFrame, nil
	}
	bodyFrame := encoder.EncodeAll(body, nil)
	encoder.Close()
	return append(headerFrame, bodyFrame...), nil
}

// normalizeArtifactCWD 只改写复制目标的首行 header，源文件保持原样；其余事件
// 字节（包括正文和换行）原封不动保留，避免迁移意外改变会话事件。
func normalizeArtifactCWD(plain []byte, canonicalCWD string) ([]byte, error) {
	newline := bytes.IndexByte(plain, '\n')
	if newline < 0 {
		return nil, errors.New("artifact header 缺少换行")
	}
	var header map[string]json.RawMessage
	if err := json.Unmarshal(plain[:newline], &header); err != nil {
		return nil, fmt.Errorf("artifact header JSON 无效: %w", err)
	}
	if header == nil {
		return nil, errors.New("artifact header 必须是 JSON 对象")
	}
	cwdJSON, err := json.Marshal(canonicalCWD)
	if err != nil {
		return nil, err
	}
	header["cwd"] = cwdJSON
	normalized, err := json.Marshal(header)
	if err != nil {
		return nil, fmt.Errorf("规范化 artifact header: %w", err)
	}
	out := make([]byte, 0, len(normalized)+1+len(plain)-newline-1)
	out = append(out, normalized...)
	out = append(out, '\n')
	out = append(out, plain[newline+1:]...)
	return out, nil
}

// decodeZstdMigration 使用流式读取并设置大小上限，避免恶意压缩比在迁移时
// 触发不受控的内存分配；超过上限的 artifact 会被视为不可迁移。
func decodeZstdMigration(raw []byte) ([]byte, error) {
	decoder, err := zstd.NewReader(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("解压 zstd artifact: %w", err)
	}
	defer decoder.Close()
	limited := io.LimitReader(decoder, maxMigrationBytes+1)
	plain, err := io.ReadAll(limited)
	if err != nil {
		return nil, fmt.Errorf("解压 zstd artifact: %w", err)
	}
	if int64(len(plain)) > maxMigrationBytes {
		return nil, errors.New("zstd artifact 解压后超过迁移大小上限")
	}
	return plain, nil
}

func fileDigest(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	_, copyErr := io.Copy(hash, file)
	_ = file.Close()
	if copyErr != nil {
		return "", copyErr
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// dshProjectKey 复刻上游 JSONL backend 使用的可读项目目录键。
func dshProjectKey(cwd string) string {
	if cwd == "" {
		return "--root--"
	}
	var b strings.Builder
	separatorRun := false
	for _, code := range utf16.Encode([]rune(cwd)) {
		r := rune(code)
		if r == '/' || r == '\\' || r == ':' {
			if !separatorRun {
				b.WriteByte('-')
			}
			separatorRun = true
			continue
		}
		if r == '~' || !(r == '.' || r == '_' || r == '-' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			fmt.Fprintf(&b, "~%04X", code)
		} else {
			b.WriteRune(r)
		}
		separatorRun = false
	}
	slug := strings.TrimLeft(b.String(), "-")
	if slug == "" {
		slug = "root"
	}
	if len(slug) > 251 {
		slug = slug[:251]
	}
	return "--" + slug + "--"
}

func dshEncodeSegment(raw string) string {
	if raw == "" {
		return ""
	}
	if raw == "." || raw == ".." {
		raw = strings.ReplaceAll(raw, ".", "~002E")
		return raw
	}
	var b strings.Builder
	for _, code := range utf16.Encode([]rune(raw)) {
		r := rune(code)
		if r == '~' || !(r == '.' || r == '_' || r == '-' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			fmt.Fprintf(&b, "~%04X", code)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// LegacyRootsFromEnv 返回显式配置的旧根目录，空项会被忽略。
func LegacyRootsFromEnv() []string {
	raw := strings.TrimSpace(os.Getenv(legacyRootsEnv))
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, string(os.PathListSeparator))
	var roots []string
	for _, part := range parts {
		if value := strings.TrimSpace(part); value != "" {
			if abs, err := filepath.Abs(value); err == nil {
				roots = append(roots, abs)
			}
		}
	}
	return roots
}
