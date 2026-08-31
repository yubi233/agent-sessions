#!/usr/bin/env node
// v0.8 DSH 历史存储预检：只读取 session header 和文件校验摘要，不迁移、不删除、不输出路径或正文。
import { createHash } from 'node:crypto';
import { createReadStream, mkdirSync, promises as fs } from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import process from 'node:process';
import { createZstdDecompress } from 'node:zlib';

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), '..', '..');
const REPORT_SCHEMA_VERSION = 1;
const MAX_HEADER_BYTES = 64 * 1024;
// 当前 DSH session-persistence-jsonl 只读取格式版本 0；未知版本必须先升级适配器。
const SUPPORTED_SESSION_HEADER_VERSION = 0;

function digest(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function encodeSegment(raw) {
  if (raw === '.' || raw === '..') return [...raw].map(() => '~002E').join('');
  let encoded = '';
  for (let index = 0; index < raw.length; index += 1) {
    const code = raw.charCodeAt(index);
    const char = raw[index];
    if (char !== '~' && /[A-Za-z0-9._-]/.test(char)) encoded += char;
    else encoded += `~${code.toString(16).toUpperCase().padStart(4, '0')}`;
  }
  return encoded;
}

export function projectKey(cwd) {
  let readable = '';
  let separatorRun = false;
  for (let index = 0; index < cwd.length; index += 1) {
    const code = cwd.charCodeAt(index);
    const char = cwd[index];
    if (char === '/' || char === '\\' || char === ':') {
      if (!separatorRun) readable += '-';
      separatorRun = true;
    } else if (char !== '~' && /[A-Za-z0-9._-]/.test(char)) {
      readable += char;
      separatorRun = false;
    } else {
      readable += `~${code.toString(16).toUpperCase().padStart(4, '0')}`;
      separatorRun = false;
    }
  }
  return `--${(readable.replace(/^-+/, '') || 'root').slice(0, 251)}--`;
}

function usage() {
  return [
    'Usage: node e2e-verify/real/dsh-v08-preflight.mjs --workspace-root <absolute-path> [--workspace-root <absolute-path>]',
    '       [--legacy-root <absolute-path>] [--report-dir <absolute-path>] [--max-project-depth <n>] [--max-artifacts <n>]',
  ].join('\n');
}

function parseArgs(argv) {
  const roots = [];
  let reportDir = '';
  let maxProjectDepth = 4;
  let maxArtifacts = 10000;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === '--workspace-root' || arg === '--legacy-root') {
      if (!next || !isAbsolute(next)) throw new Error('invalid_root_argument');
      roots.push({ kind: arg === '--workspace-root' ? 'workspace' : 'legacy', value: next });
      index += 1;
      continue;
    }
    if (arg === '--report-dir') {
      if (!next || !isAbsolute(next)) throw new Error('invalid_report_dir');
      reportDir = next;
      index += 1;
      continue;
    }
    if (arg === '--max-project-depth' || arg === '--max-artifacts') {
      const number = Number.parseInt(next ?? '', 10);
      if (!Number.isSafeInteger(number) || number < 1 || number > 100000) throw new Error('invalid_limit');
      if (arg === '--max-project-depth') maxProjectDepth = number;
      else maxArtifacts = number;
      index += 1;
      continue;
    }
    throw new Error('unknown_argument');
  }
  if (roots.length === 0) throw new Error('missing_authorized_root');
  return { roots, reportDir, maxProjectDepth, maxArtifacts };
}

async function canonicalDirectory(value) {
  const canonical = await fs.realpath(value);
  const stat = await fs.lstat(canonical);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('root_not_directory');
  return canonical;
}

async function listSessionArtifacts(sessionRoot, maxArtifacts, sink) {
  const artifacts = [];
  const pending = [{ path: sessionRoot, depth: 0 }];
  while (pending.length > 0) {
    const current = pending.pop();
    let entries;
    try {
      entries = await fs.readdir(current.path, { withFileTypes: true });
    } catch {
      sink.errors.add('session_root_unreadable');
      continue;
    }
    for (const entry of entries) {
      const entryPath = join(current.path, entry.name);
      if (entry.isSymbolicLink()) {
        sink.skipped.symlink += 1;
        continue;
      }
      if (entry.isDirectory()) {
        if (current.depth >= 8) {
          sink.skipped.session_depth += 1;
          continue;
        }
        pending.push({ path: entryPath, depth: current.depth + 1 });
        continue;
      }
      if (!entry.isFile()) continue;
      if (entry.name !== 'session.jsonl' && entry.name !== 'session.jsonl.zstd') continue;
      if (artifacts.length >= maxArtifacts) {
        sink.errors.add('artifact_limit_reached');
        return artifacts;
      }
      artifacts.push(entryPath);
    }
  }
  return artifacts;
}

async function discoverArtifacts(root, maxProjectDepth, maxArtifacts, sink) {
  // 调用方可能直接传入 DSH 的 `.dsh-sessions` 持久化根；此时不能再拼接
  // 第二层 `.dsh-sessions`，否则旧会话会被误报为零个 artifact。
  if (basename(root) === '.dsh-sessions') return listSessionArtifacts(root, maxArtifacts, sink);
  // 显式 root 本身已有存储时，它就是一个 DSH project/legacy persistence root。只清点
  // 这一处，不能为了预检再遍历整个源码树并把无关子项目混进迁移清单。
  const directSessionRoot = join(root, '.dsh-sessions');
  try {
    const directInfo = await fs.lstat(directSessionRoot);
    if (directInfo.isSymbolicLink()) {
      sink.skipped.symlink += 1;
      return [];
    }
    if (directInfo.isDirectory()) return listSessionArtifacts(directSessionRoot, maxArtifacts, sink);
  } catch {
    // 授权根不是 DSH project root 时，继续以受限深度发现其子项目。
  }
  const artifacts = [];
  const pending = [{ path: root, depth: 0 }];
  while (pending.length > 0) {
    const current = pending.pop();
    let entries;
    try {
      entries = await fs.readdir(current.path, { withFileTypes: true });
    } catch {
      sink.errors.add('root_unreadable');
      continue;
    }
    for (const entry of entries) {
      const entryPath = join(current.path, entry.name);
      if (entry.isSymbolicLink()) {
        sink.skipped.symlink += 1;
        continue;
      }
      if (!entry.isDirectory()) continue;
      if (entry.name === '.dsh-sessions') {
        const found = await listSessionArtifacts(entryPath, maxArtifacts - artifacts.length, sink);
        artifacts.push(...found);
        if (artifacts.length >= maxArtifacts) return artifacts;
        continue;
      }
      if (entry.name === '.git' || entry.name === 'node_modules' || entry.name.startsWith('.')) {
        sink.skipped.ignored_directory += 1;
        continue;
      }
      if (current.depth >= maxProjectDepth) {
        sink.skipped.project_depth += 1;
        continue;
      }
      pending.push({ path: entryPath, depth: current.depth + 1 });
    }
  }
  return artifacts;
}

async function readFirstLine(path, compressed) {
  const source = createReadStream(path, { highWaterMark: 4096 });
  const stream = compressed ? source.pipe(createZstdDecompress()) : source;
  return new Promise((resolveLine, rejectLine) => {
    let bytes = 0;
    let value = '';
    let settled = false;
    const finish = (callback, result) => {
      if (settled) return;
      settled = true;
      source.destroy();
      callback(result);
    };
    stream.on('data', (chunk) => {
      if (settled) return;
      bytes += chunk.length;
      if (bytes > MAX_HEADER_BYTES) {
        finish(rejectLine, new Error('header_too_large'));
        return;
      }
      value += chunk.toString('utf8');
      const newline = value.indexOf('\n');
      if (newline >= 0) finish(resolveLine, value.slice(0, newline).replace(/\r$/, ''));
    });
    stream.on('end', () => finish(resolveLine, value.replace(/\r$/, '')));
    stream.on('error', () => finish(rejectLine, new Error(compressed ? 'zstd_read_failed' : 'header_read_failed')));
    source.on('error', () => finish(rejectLine, new Error('artifact_read_failed')));
  });
}

async function fileDigest(path) {
  return new Promise((resolveDigest, rejectDigest) => {
    const hash = createHash('sha256');
    const stream = createReadStream(path);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', () => rejectDigest(new Error('digest_read_failed')));
    stream.on('end', () => resolveDigest(hash.digest('hex')));
  });
}

function parseHeader(line) {
  let value;
  try {
    value = JSON.parse(line);
  } catch {
    return { error: 'header_invalid_json' };
  }
  if (value?.type !== 'session' || value.version !== SUPPORTED_SESSION_HEADER_VERSION || typeof value.id !== 'string' || value.id.length === 0) {
    return { error: 'header_invalid_shape' };
  }
  if (typeof value.createdAt !== 'number' || !Number.isSafeInteger(value.createdAt) || value.createdAt < 0) return { error: 'header_invalid_created_at' };
  if (typeof value.delegationDepth !== 'number' || !Number.isSafeInteger(value.delegationDepth) || value.delegationDepth < 0) return { error: 'header_invalid_delegation_depth' };
  if (value.cwd !== undefined && (typeof value.cwd !== 'string' || !isAbsolute(value.cwd))) return { error: 'header_invalid_cwd' };
  return { id: value.id, cwd: value.cwd ?? '' };
}

async function inspectArtifact(path, root, rootLabel) {
  const compressed = path.endsWith('.zstd');
  let before;
  try {
    before = await fs.stat(path);
    const [line, artifactDigest] = await Promise.all([readFirstLine(path, compressed), fileDigest(path)]);
    const after = await fs.stat(path);
    const parsed = parseHeader(line);
    const pathHash = digest(relative(root, path));
    const base = {
      root_label: rootLabel,
      artifact_path_hash: pathHash,
      artifact_sha256: artifactDigest,
      bytes: before.size,
      compression: compressed ? 'zstd' : 'none',
      source_changed: before.size !== after.size || before.mtimeMs !== after.mtimeMs,
    };
    if (base.source_changed) return { ...base, error: 'migration_source_changed' };
    if (parsed.error) return { ...base, error: parsed.error };
    const sessionDir = dirname(path);
    const projectDir = dirname(sessionDir);
    const expectedProject = projectKey(parsed.cwd);
    const expectedSession = encodeSegment(parsed.id);
    if (basename(sessionDir) !== expectedSession || basename(projectDir) !== expectedProject) {
      return { ...base, session_id_hash: digest(parsed.id), cwd_hash: parsed.cwd ? digest(parsed.cwd) : null, error: 'header_path_mismatch' };
    }
    return {
      ...base,
      session_id_hash: digest(parsed.id),
      cwd_hash: parsed.cwd ? digest(parsed.cwd) : null,
      error: parsed.cwd ? null : 'header_missing_cwd',
    };
  } catch (error) {
    const code = error instanceof Error && /^(header_|zstd_|artifact_|digest_)/.test(error.message)
      ? error.message
      : 'artifact_unreadable';
    return {
      root_label: rootLabel,
      artifact_path_hash: digest(relative(root, path)),
      artifact_sha256: null,
      bytes: before?.size ?? null,
      compression: compressed ? 'zstd' : 'none',
      source_changed: false,
      error: code,
    };
  }
}

function collisionSummary(artifacts) {
  const byID = new Map();
  for (const artifact of artifacts) {
    if (!artifact.session_id_hash) continue;
    const group = byID.get(artifact.session_id_hash) ?? [];
    group.push(artifact);
    byID.set(artifact.session_id_hash, group);
  }
  const conflicts = [];
  for (const [sessionIDHash, group] of byID) {
    if (group.length < 2) continue;
    const digests = new Set(group.map((artifact) => artifact.artifact_sha256));
    const encodings = new Set(group.map((artifact) => artifact.compression));
    if (digests.size > 1 || encodings.size > 1) {
      conflicts.push({
        session_id_hash: sessionIDHash,
        artifact_count: group.length,
        reason: encodings.size > 1 ? 'duplicate_id_dual_compression' : 'duplicate_id_different_digest',
      });
    }
  }
  return conflicts;
}

function defaultReportDir() {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return join(ROOT, 'e2e-verify', 'reports', stamp, 'V08-PREFLIGHT');
}

export async function runPreflight(options) {
  const skipped = { symlink: 0, ignored_directory: 0, project_depth: 0, session_depth: 0 };
  const errors = new Set();
  const roots = [];
  const artifacts = [];
  for (const [index, configured] of options.roots.entries()) {
    const label = `${configured.kind}-${index + 1}`;
    let canonical;
    try {
      canonical = await canonicalDirectory(configured.value);
    } catch {
      errors.add('authorized_root_unavailable');
      roots.push({ label, kind: configured.kind, root_hash: digest(configured.value), artifact_count: 0, error: 'authorized_root_unavailable' });
      continue;
    }
    const sink = { skipped, errors };
    const found = await discoverArtifacts(canonical, options.maxProjectDepth, options.maxArtifacts - artifacts.length, sink);
    const inspected = await Promise.all(found.map((path) => inspectArtifact(path, canonical, label)));
    artifacts.push(...inspected);
    roots.push({ label, kind: configured.kind, root_hash: digest(canonical), artifact_count: inspected.length, error: null });
    if (artifacts.length >= options.maxArtifacts) {
      errors.add('artifact_limit_reached');
      break;
    }
  }
  const artifactErrors = artifacts.filter((artifact) => artifact.error !== null).map((artifact) => artifact.error);
  const collisions = collisionSummary(artifacts);
  // 深度/数量边界意味着清单可能不完整；即使当前发现的 artifact 都可读，也不能放行迁移。
  if (skipped.project_depth > 0 || skipped.session_depth > 0) errors.add('scan_limit_reached');
  const hardErrors = [...errors, ...artifactErrors];
  const migrationReady = hardErrors.length === 0 && collisions.length === 0;
  return {
    report_schema_version: REPORT_SCHEMA_VERSION,
    suite: 'V08-PREFLIGHT',
    report_kind: 'local_dsh_storage_inventory',
    // 只要清单不能证明可安全迁移，就把进程结果标为 blocked；调用方不能只看
    // artifact_count 而忽略 migration_ready=false。
    status: migrationReady ? 'passed' : 'blocked',
    real_browser: false,
    real_model: false,
    real_upstream: false,
    fixture_data: false,
    local_test: true,
    headless: false,
    command: 'node e2e-verify/real/dsh-v08-preflight.mjs --workspace-root [REDACTED]',
    executed_at: new Date().toISOString(),
    roots,
    summary: {
      artifact_count: artifacts.length,
      valid_header_count: artifacts.filter((artifact) => artifact.session_id_hash && !artifact.error).length,
      plain_count: artifacts.filter((artifact) => artifact.compression === 'none').length,
      zstd_count: artifacts.filter((artifact) => artifact.compression === 'zstd').length,
      error_counts: Object.fromEntries([...new Set(hardErrors)].sort().map((code) => [code, hardErrors.filter((value) => value === code).length])),
      skipped,
      collision_count: collisions.length,
      migration_ready: migrationReady,
    },
    artifacts,
    collisions,
    failure_class: migrationReady ? null : 'checkpoint_mismatch',
    remaining_risk: migrationReady
      ? '预检只证明已授权根的 header 与 artifact 摘要可读；P0 仍需在 DSH 空闲时执行非破坏性迁移。'
      : '发现格式、冲突、源文件变化或扫描限制；不得迁移、导入或宣称 G3/G4 可用。',
  };
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch {
    process.stderr.write(`${usage()}\n`);
    process.exitCode = 2;
    return;
  }
  const report = await runPreflight(options);
  const reportDir = options.reportDir || defaultReportDir();
  await fs.mkdir(reportDir, { recursive: true });
  const reportPath = join(reportDir, 'dsh-v08-preflight.json');
  await fs.writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  const safePath = relative(ROOT, reportPath);
  process.stdout.write(`[dsh-v08-preflight] status=${report.status} artifacts=${report.summary.artifact_count} migration_ready=${report.summary.migration_ready} report=${safePath.startsWith('..') ? '[REDACTED]' : safePath}\n`);
  if (report.status !== 'passed') process.exitCode = 2;
}

if (process.argv[1] && resolve(process.argv[1]) === new URL(import.meta.url).pathname) {
  main().catch(() => {
    process.stderr.write('[dsh-v08-preflight] status=blocked failure_class=environment_or_startup_failure\n');
    process.exitCode = 2;
  });
}
