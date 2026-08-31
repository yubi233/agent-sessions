#!/usr/bin/env node
// 完整真实 DSH 验证：保留 DSH 本地 session cache，并把 cache、Relay 事件、Flutter 窗口证据绑定。
// 本脚本不读取 ~/.dsh/.credentials.yaml 或任何 key；凭据只由 DSH 自身配置/环境加载。
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';


const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const reportDir = join(ROOT, 'e2e-verify', 'reports', 'ADAPTER-DSH');
const screenshotDir = join(ROOT, 'e2e-verify', 'screencasts', stamp, 'ADAPTER-DSH');
const cacheRoot = join(reportDir, `cache-${stamp}`);
const flutterFrameDirectoryName = `real-dsh-${stamp}`;
const flutterFrameTmpDir = join(tmpdir(), flutterFrameDirectoryName);
mkdirSync(reportDir, { recursive: true });
mkdirSync(screenshotDir, { recursive: true });
mkdirSync(cacheRoot, { recursive: true });

const relayBase = process.env.AGENT_SESSIONS_RELAY_BASE_URL ?? 'http://127.0.0.1:8787';
const dshBin = process.env.AGENT_SESSIONS_DSH_BIN ?? '/Users/yubi/code/deepseek-harness/packages/examples/acp-demo/lib/bin.js';
// 默认使用仓库根的本地配置，避免继续调用已经下线的旧模型。
const dshConfig = process.env.AGENT_SESSIONS_DSH_CONFIG ?? join(ROOT, 'cordis.yml');
const model = process.env.AGENT_SESSIONS_DSH_MODEL ?? 'deepseek-v4-flash-free';
const dshRouteProvider = process.env.AGENT_SESSIONS_DSH_PROVIDER ?? 'opencode-zen';
const report = {
  suite: 'v0.5.next-dsh-cache-relay-flutter-live',
  report_kind: 'real_cache_relay_flutter_correlation',
  status: 'failed',
  failure_class: null,
  executed_at: new Date().toISOString(),
  real_browser: false,
  real_model: true,
  real_upstream: true,
  fixture_data: false,
  local_test: true,
  headless: false,
  provider: 'dsh',
  dsh_route_provider: dshRouteProvider,
  model,
  relay_base: relayBase,
  command: 'node e2e-verify/real/dsh-cache-flutter-live.mjs',
  credential_source: 'dsh-local-config-or-env-redacted',
  usage: { input_tokens: 0, output_tokens: 0 },
  artifacts: [],
  cache: { root: evidence(cacheRoot), sessions: [] },
  relay: {},
  flutter: {},
  verification: [],
  remaining_risk: '',
};

function evidence(path) {
  const rel = relative(ROOT, path);
  return rel && !rel.startsWith('..') ? rel : '[PATH REDACTED]';
}
function sha256(text) {
  return createHash('sha256').update(String(text)).digest('hex');
}
function sanitizeError(value) {
  return String(value?.message ?? value)
    .replace(/(bearer\s+)[^\s"']+/gi, '$1[REDACTED]')
    .replace(/([?&](?:token|password|secret)=)[^&#\s"']+/gi, '$1[REDACTED]')
    .replace(/(access_token|refresh_token|api[_-]?key|authorization)(["'=: ]+)[^\s"'}]+/gi, '$1$2[REDACTED]')
    .replace(/\/(?:Users|private|var|tmp)\/[^\s"']+/g, '[PATH REDACTED]')
    .slice(0, 800);
}
function run(cmd, args, { timeout = 300000, env = process.env } = {}) {
  const res = spawnSync(cmd, args, { cwd: ROOT, env, encoding: 'utf8', timeout });
  if (res.status !== 0) {
    throw new Error(`${cmd} ${args.join(' ')} failed exit=${res.status}: ${sanitizeError(`${res.stdout}\n${res.stderr}`).slice(-800)}`);
  }
  return res;
}
function http(method, path, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const args = ['-fsS', '-X', method, `${relayBase}${path}`, '-H', 'Content-Type: application/json'];
  if (token) args.push('-H', `Authorization: Bearer ${token}`);
  if (body != null) args.push('--data-binary', JSON.stringify(body));
  const out = execFileSync('curl', args, { cwd: ROOT, encoding: 'utf8', timeout: 60000, maxBuffer: 8 * 1024 * 1024 });
  return out.trim() ? JSON.parse(out) : {};
}
function unwrap(value) {
  return value && typeof value === 'object' && value.data && typeof value.data === 'object' ? value.data : value;
}
function allFiles(dir, suffix) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const name of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, name.name);
    if (name.isDirectory()) out.push(...allFiles(path, suffix));
    else if (path.endsWith(suffix)) out.push(path);
  }
  return out;
}
function textFromContent(content) {
  if (!Array.isArray(content)) return '';
  return content.map((part) => {
    if (part?.type === 'text') return part.text ?? '';
    return '';
  }).join('');
}
function parseDshCache() {
  const sessions = [];
  for (const file of allFiles(cacheRoot, 'session.jsonl')) {
    let session = null;
    let request = null;
    let assistant = null;
    let usage = null;
    let response = null;
    const lines = readFileSync(file, 'utf8').split(/\r?\n/).filter(Boolean);
    for (const line of lines) {
      let event;
      try { event = JSON.parse(line); } catch { continue; }
      if (event.type === 'session') session = event;
      if (event.type === 'request/context') request = event.data;
      if (event.type === 'request/header') request = event.data?.header?.config ?? request;
      if (event.type === 'assistant/message') {
        const text = textFromContent(event.data?.message?.content);
        if (text.trim()) {
          assistant = { text, seq: event.seq, role: event.data?.message?.role };
          usage = event.data?.usage ?? usage;
          response = event.data?.message?.source?.replayState?.response ?? response;
        }
      }
    }
    if (!assistant?.text) continue;
    const normalized = assistant.text.trim();
    sessions.push({
      dsh_session_id: session?.id ?? null,
      path: evidence(file),
      provider: request?.provider ?? response?.provider ?? null,
      model: request?.model ?? response?.model ?? null,
      response_id: response?.responseId ?? null,
      stop_reason: response?.stopReason ?? null,
      assistant_text: normalized,
      assistant_text_length: normalized.length,
      assistant_text_sha256: sha256(normalized),
      usage: usage == null ? null : {
        input_tokens: usage.inputTokens ?? 0,
        output_tokens: usage.outputTokens ?? 0,
      },
    });
  }
  return sessions.sort((a, b) => a.path.localeCompare(b.path));
}
function parsePngDimensions(path) {
  const buf = readFileSync(path);
  if (buf.length < 24 || buf.toString('ascii', 12, 16) !== 'IHDR') return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20), size_bytes: statSync(path).size };
}
function flutterFrameCandidateDirs() {
  return [
    flutterFrameTmpDir,
    join(homedir(), 'Library', 'Containers', 'com.agentsessions.agentSessionsMobile', 'Data', 'tmp', flutterFrameDirectoryName),
  ];
}

async function waitForFlutterFrame(sessionId) {
  for (let i = 0; i < 180; i += 1) {
    for (const candidateDir of flutterFrameCandidateDirs()) {
      const framePath = join(candidateDir, 'frame-0001.png');
      const timingPath = join(candidateDir, 'frame-timing.json');
      if (existsSync(framePath) && existsSync(timingPath)) {
        const copiedFrame = join(screenshotDir, `real-dsh-${sessionId}-frame-0001.png`);
        const copiedTiming = join(screenshotDir, `real-dsh-${sessionId}-frame-timing.json`);
        copyFileSync(framePath, copiedFrame);
        copyFileSync(timingPath, copiedTiming);
        const dimensions = parsePngDimensions(copiedFrame);
        const timing = JSON.parse(readFileSync(copiedTiming, 'utf8'));
        return {
          evidence_type: 'flutter_render_tree_frame',
          first_frame: evidence(copiedFrame),
          timing_file: evidence(copiedTiming),
          frame_directory: evidence(screenshotDir),
          source_frame_directory: evidence(candidateDir),
          dimensions,
          frame_count: timing.frame_count ?? null,
          frame_rate_fps: timing.frame_rate_fps ?? null,
          frame_interval_ms: timing.frame_interval_ms ?? null,
        };
      }
    }
    await delay(500);
  }
  throw new Error(`Flutter render-tree frame not produced for ${sessionId}`);
}

try {
  if (!existsSync(dshBin)) throw new Error(`DSH bin not found: ${dshBin}`);
  if (!existsSync(dshConfig)) throw new Error(`DSH config not found: ${dshConfig}`);

  const baseEnv = {
    ...process.env,
    AGENT_SESSIONS_RELAY_ADDR: relayBase.replace(/^https?:\/\//, ''),
    AGENT_SESSIONS_DSH_BIN: dshBin,
    AGENT_SESSIONS_DSH_CONFIG: dshConfig,
    AGENT_SESSIONS_DSH_REAL_MODEL: '1',
    AGENT_SESSIONS_DSH_PERSIST_ROOT: cacheRoot,
    AGENT_SESSIONS_FLUTTER_TIMEOUT_MS: '120000',
    LOCAL_VISUAL_FRAME_DIRECTORY: flutterFrameDirectoryName,
    LOCAL_VISUAL_FRAME_COUNT: '5',
    LOCAL_VISUAL_FRAME_INTERVAL_MS: '200',
  };

  run('./restart.sh', ['restart', '--no-opencode', '--no-web', '--no-admin', '--no-flutter'], { env: baseEnv, timeout: 300000 });
  const tokenPath = join(ROOT, '.task', 'restart', 'local-owner-token');
  const token = readFileSync(tokenPath, 'utf8').trim();
  const workspaces = unwrap(http('GET', '/v1/workspaces', null, token)).workspaces ?? [];
  const workspace = workspaces.find((item) => item.id === 'ws_local-dev') ?? workspaces[0];
  if (!workspace?.id) throw new Error('No local workspace available');

  const created = unwrap(http('POST', '/v1/sessions', { workspace_id: workspace.id, provider: 'dsh' }, token));
  const relaySessionId = created.id;
  if (!relaySessionId) throw new Error('Relay session creation returned no id');
  const lease = unwrap(http('POST', `/v1/sessions/${relaySessionId}/lease`, {}, token));
  const leaseEpoch = lease.lease_epoch ?? lease.epoch;
  if (!Number.isInteger(leaseEpoch) || leaseEpoch <= 0) throw new Error(`Invalid lease_epoch: ${JSON.stringify(lease)}`);

  const start = http('POST', `/v1/sessions/${relaySessionId}/commands`, {
    kind: 'session.start',
    idempotency_key: `real-dsh-cache-start-${stamp}`,
    lease_epoch: leaseEpoch,
    ciphertext: {
      session_id: relaySessionId,
      ciphertext: { fixture_payload: { session_id: relaySessionId, provider: 'dsh', model } },
    },
  }, token);
  const send = http('POST', `/v1/sessions/${relaySessionId}/commands`, {
    kind: 'session.send',
    idempotency_key: `real-dsh-cache-send-${stamp}`,
    lease_epoch: leaseEpoch,
    ciphertext: {
      session_id: relaySessionId,
      ciphertext: { fixture_payload: { session_id: relaySessionId, message: '请只回复两个字符：OK' } },
    },
  }, token);

  let relayAssistant = null;
  let lastEventCount = 0;
  const deadline = Date.now() + 180000;
  while (Date.now() < deadline) {
    const snap = unwrap(http('GET', `/v1/sessions/${relaySessionId}/snapshot?after_seq=0`, null, token));
    const events = Array.isArray(snap.events) ? snap.events : [];
    lastEventCount = events.length;
    for (const event of events) {
      const envelope = event.envelope ?? event.ciphertext ?? event.payload ?? {};
      const payload = envelope.fixture_payload ?? event.ciphertext?.fixture_payload ?? event.payload?.fixture_payload ?? {};
      const text = typeof payload.text === 'string' ? payload.text : '';
      if (event.event_type === 'message.completed' && payload.kind === 'assistant_message' && text.trim()) {
        relayAssistant = {
          event_type: event.event_type,
          timeline_kind: payload.kind,
          text: text.trim(),
          text_sha256: sha256(text.trim()),
          seq: event.seq ?? null,
        };
      }
    }
    if (relayAssistant?.text) break;
    await delay(1000);
  }
  if (!relayAssistant) throw new Error(`Timed out waiting for Relay assistant message, events=${lastEventCount}`);

  let cacheSessions = [];
  for (let i = 0; i < 20; i += 1) {
    cacheSessions = parseDshCache();
    if (cacheSessions.some((item) => item.assistant_text_sha256 === relayAssistant.text_sha256)) break;
    await delay(500);
  }
  const matchedCache = cacheSessions.find((item) => item.assistant_text_sha256 === relayAssistant.text_sha256);
  if (!matchedCache) {
    throw new Error(`No DSH cache assistant text matched Relay hash ${relayAssistant.text_sha256}; cache_sessions=${cacheSessions.length}`);
  }
  report.cache.sessions = cacheSessions;
  report.usage = matchedCache.usage == null ? report.usage : {
    input_tokens: matchedCache.usage.input_tokens,
    output_tokens: matchedCache.usage.output_tokens,
  };
  report.relay = {
    session_id: relaySessionId,
    lease_epoch: leaseEpoch,
    start_status: unwrap(start).status ?? start.status ?? null,
    send_status: unwrap(send).status ?? send.status ?? null,
    assistant_event: relayAssistant,
  };

  const cacheIndexPath = join(reportDir, `real-dsh-cache-index-${stamp}.json`);
  writeFileSync(cacheIndexPath, `${JSON.stringify({
    generated_at: new Date().toISOString(),
    cache_root: evidence(cacheRoot),
    matched: matchedCache,
    sessions: cacheSessions,
  }, null, 2)}\n`);
  report.artifacts.push(evidence(cacheIndexPath));

  run('./restart.sh', ['restart', '--no-opencode', '--no-web', '--no-admin', '--flutter-target-session', relaySessionId], { env: baseEnv, timeout: 420000 });
  const flutterEvidence = await waitForFlutterFrame(relaySessionId);
  report.flutter = {
    target_session_id: relaySessionId,
    vm_route_source: 'LOCAL_DEV_TARGET_SESSION_ID',
    render_tree_frame_source: 'LOCAL_VISUAL_FRAME_DIRECTORY',
    ...flutterEvidence,
  };
  report.artifacts.push(flutterEvidence.first_frame, flutterEvidence.timing_file);

  report.verification.push('DSH cache retained and parsed from opt-in AGENT_SESSIONS_DSH_PERSIST_ROOT.');
  report.verification.push('Relay message.completed assistant text hash matches DSH cache assistant text hash.');
  report.verification.push('Flutter macOS client relaunched with LOCAL_DEV_TARGET_SESSION_ID for the same Relay session and exported a render-tree PNG frame.');
  report.status = 'passed';
  report.failure_class = null;
  report.remaining_risk = 'Flutter UI evidence is a render-tree PNG exported by the targeted macOS client, avoiding system Screen Recording permission while still being driven by the real Relay session.';
} catch (error) {
  report.failure_class = /credential|api key|quota|unauthorized/i.test(String(error?.message ?? error))
    ? 'credential_or_quota_blocker'
    : 'verification_failure';
  report.status = report.failure_class === 'credential_or_quota_blocker' ? 'blocked' : 'failed';
  report.remaining_risk = sanitizeError(error);
  console.error('[dsh-cache-flutter-live] failed:', report.remaining_risk);
} finally {
  const reportPath = join(reportDir, `p6-dsh-cache-relay-flutter-${stamp}.json`);
  report.artifacts.unshift(evidence(reportPath));
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`[dsh-cache-flutter-live] status=${report.status} -> ${reportPath}`);
  process.exitCode = report.status === 'passed' ? 0 : 1;
}
