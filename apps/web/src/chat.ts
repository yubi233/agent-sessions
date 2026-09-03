// Web 主动发起 LLM 会话的写链路（本地单租户场景）。
// 依赖 Relay 写权限已对 web 角色开放；事件正文只在
// AGENT_SESSIONS_EVENT_LOCAL_DEV_PLAINTEXT=1 的本地开发明文信封中解析，
// 生产 E2EE 信封不会进入页面内存/渲染。
import { relayURL, sessionState } from "./session";

export interface WorkspaceInfo {
  id: string;
  project_id: string;
  terminal_id?: string;
  status?: string;
}

export interface ChatMessage {
  seq: number;
  role: "user" | "assistant" | "system" | "tool";
  text: string;
  streaming?: boolean;
}

interface SnapshotResponse {
  session: { id: string; status: string; last_seq: number };
  events: Array<{
    event_seq: number;
    event_type: string;
    envelope?: Record<string, unknown> | string;
  }>;
}

let commandCounter = 0;

function idempotencyKey(prefix: string): string {
  commandCounter += 1;
  return `${prefix}-${Date.now()}-${commandCounter}-${Math.random().toString(16).slice(2, 8)}`;
}

async function requestJSON<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${sessionState.token}`);
  if (init.body !== undefined) headers.set("Content-Type", "application/json");
  const response = await fetch(`${relayURL}${path}`, { ...init, headers });
  if (!response.ok) {
    throw new Error(`${init.method ?? "GET"} ${path} failed: ${response.status}`);
  }
  return (await response.json()) as T;
}

export async function listWorkspaces(): Promise<WorkspaceInfo[]> {
  const data = await requestJSON<{ workspaces: WorkspaceInfo[] }>("/v1/workspaces");
  return data.workspaces ?? [];
}

export async function createSession(workspaceId: string, provider = "dsh"): Promise<{ id: string }> {
  return requestJSON<{ id: string }>("/v1/sessions", {
    method: "POST",
    body: JSON.stringify({ workspace_id: workspaceId, provider }),
  });
}

export async function acquireLease(sessionId: string): Promise<number> {
  const data = await requestJSON<{ lease_epoch: number }>(
    `/v1/sessions/${encodeURIComponent(sessionId)}/lease`,
    { method: "POST" },
  );
  return data.lease_epoch;
}

function daemonCommandPayload(sessionId: string, fixture: Record<string, unknown>) {
  return {
    session_id: sessionId,
    ciphertext: { fixture_payload: fixture },
  };
}

export interface CommandReceipt {
  id: string;
  kind: string;
  status: string;
}

export async function submitCommand(
  sessionId: string,
  kind: "session.start" | "session.send" | "session.abort",
  leaseEpoch: number,
  fixture?: Record<string, unknown>,
): Promise<CommandReceipt> {
  return requestJSON<CommandReceipt>(
    `/v1/sessions/${encodeURIComponent(sessionId)}/commands`,
    {
      method: "POST",
      body: JSON.stringify({
        kind,
        idempotency_key: idempotencyKey(kind),
        lease_epoch: leaseEpoch,
        ciphertext: daemonCommandPayload(sessionId, fixture ?? {}),
      }),
    },
  );
}

export async function startSession(
  sessionId: string,
  leaseEpoch: number,
  provider = "dsh",
): Promise<CommandReceipt> {
  return submitCommand(sessionId, "session.start", leaseEpoch, {
    session_id: sessionId,
    provider,
  });
}

export async function sendMessage(
  sessionId: string,
  leaseEpoch: number,
  text: string,
): Promise<CommandReceipt> {
  return submitCommand(sessionId, "session.send", leaseEpoch, {
    message: text,
  });
}

function parseEnvelope(envelope: unknown): Record<string, unknown> | null {
  if (envelope == null) return null;
  if (typeof envelope === "string") {
    try {
      return JSON.parse(envelope) as Record<string, unknown>;
    } catch {
      return null;
    }
  }
  if (typeof envelope === "object") return envelope as Record<string, unknown>;
  return null;
}

function messageFromEvent(
  event: SnapshotResponse["events"][number],
): ChatMessage | null {
  const envelope = parseEnvelope(event.envelope);
  if (!envelope) return null;
  const payload = envelope.fixture_payload;
  if (payload == null || typeof payload !== "object") return null;
  const p = payload as Record<string, unknown>;
  const kind = typeof p.kind === "string" ? p.kind : "";
  const text = typeof p.text === "string" ? p.text : "";
  const streaming = p.streaming === true;
  switch (kind) {
    case "user_message":
      return { seq: event.event_seq, role: "user", text, streaming: false };
    case "assistant_message":
      return { seq: event.event_seq, role: "assistant", text, streaming };
    case "system_notice":
      return { seq: event.event_seq, role: "system", text, streaming: false };
    case "tool_activity":
      return { seq: event.event_seq, role: "tool", text, streaming: false };
    default:
      return null;
  }
}

export async function fetchChatSnapshot(sessionId: string): Promise<{
  sessionId: string;
  status: string;
  lastSeq: number;
  messages: ChatMessage[];
  /** v0.8.4（ADR-015 §3）：最近一条 turn_phase 投影的只读相位；无投影为 null。 */
  turnPhase: string | null;
}> {
  const data = await requestJSON<SnapshotResponse>(
    `/v1/sessions/${encodeURIComponent(sessionId)}/snapshot?after_seq=0`,
  );
  const messages: ChatMessage[] = [];
  let turnPhase: string | null = null;
  let phaseRevision = 0;
  for (const event of data.events) {
    const message = messageFromEvent(event);
    if (message) messages.push(message);
    // v0.8.4：phase 是只读安全事实（phase/revision 白名单），按 revision 单调折叠。
    const envelope = parseEnvelope(event.envelope);
    const fixture = envelope?.fixture_payload;
    if (fixture != null && typeof fixture === "object") {
      const fp = fixture as Record<string, unknown>;
      if (fp.kind === "turn_phase" && typeof fp.phase === "string") {
        const revision = typeof fp.revision === "number" ? fp.revision : 0;
        if (revision >= phaseRevision) {
          turnPhase = fp.phase;
          phaseRevision = revision;
        }
      }
    }
  }
  return {
    sessionId: data.session.id,
    status: data.session.status,
    lastSeq: data.session.last_seq,
    messages,
    turnPhase,
  };
}