#!/usr/bin/env node
import fs from "node:fs/promises";
import fsSync from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";

const SESSIONS_ROOT = process.env.CODEX_SESSIONS_ROOT || path.join(process.env.HOME || "", ".codex", "sessions");
const STATE_FILE = process.env.CODEX_NOTIFY_STATE_FILE || path.join(process.env.HOME || "", ".codex", "tmp", "feishu-notify-state.json");
const SEND_SCRIPT = process.env.CODEX_FEISHU_SEND_SCRIPT || path.join(process.env.HOME || "", ".codex", "scripts", "codex-feishu-send.sh");
const LOG_FILE = process.env.CODEX_NOTIFY_LOG_FILE || path.join(process.env.HOME || "", ".codex", "log", "feishu-notify.log");
const PRECHECK_TARGET = process.env.CODEX_FEISHU_TARGET || "ou_9911a4b1244b09203d2ea79f5cef2bee";
const DEDUPE_TTL_SECONDS = 6 * 3600;
const POLL_MS = Number(process.env.CODEX_NOTIFY_POLL_MS || "2000");
const COMPLETION_QUIET_MS = Number(process.env.CODEX_NOTIFY_COMPLETION_QUIET_MS || "20000");
const READ_HISTORY = process.env.CODEX_NOTIFY_READ_HISTORY === "1";
const LOCK_DIR = `${STATE_FILE}.lock`;
const FEISHU_INBOUND_PATTERNS = [
  /Feishu\[[^\]]+\]\s*DM\s+from/i,
  /System:\s*\[[^\]]+\]\s*Feishu\[[^\]]+\]/i,
];

const fileState = new Map();
const pendingCompletions = new Map();

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

async function ensureParent(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
}

async function log(level, message) {
  const line = `[${new Date().toISOString()}] [${level}] ${message}\n`;
  await ensureParent(LOG_FILE);
  await fs.appendFile(LOG_FILE, line, "utf8");
}

function truncateSummary(raw) {
  if (!raw) return "-";
  const compact = String(raw).replace(/\s+/g, " ").trim();
  if (compact.length <= 120) return compact;
  return `${compact.slice(0, 120)}...`;
}

function shanghaiTimeString() {
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date());
}

async function runCommand(cmd, args, options = {}) {
  return await new Promise((resolve) => {
    const child = spawn(cmd, args, {
      stdio: ["ignore", "pipe", "pipe"],
      ...options,
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => {
      stdout += d.toString();
    });
    child.stderr.on("data", (d) => {
      stderr += d.toString();
    });
    child.on("close", (code) => {
      resolve({ ok: code === 0, code: code ?? 1, stdout, stderr, output: `${stdout}${stderr}` });
    });
    child.on("error", (err) => {
      resolve({ ok: false, code: 1, stdout, stderr: String(err), output: `${stdout}${stderr}${String(err)}` });
    });
  });
}

async function preflightFeishu() {
  const args = [
    "message",
    "send",
    "--channel",
    process.env.CODEX_FEISHU_CHANNEL || "feishu",
    "--target",
    PRECHECK_TARGET,
    "--message",
    `codex-notify preflight ${new Date().toISOString()}`,
    "--dry-run",
    "--json",
  ];

  let result = await runCommand("openclaw", args);
  if (result.ok) {
    await log("INFO", "preflight ok");
    return true;
  }

  if (result.output.includes("createReplyVoiceTtsBridge") || result.output.includes("Unknown channel: feishu")) {
    await log("WARN", "preflight detected feishu plugin issue, running repatch-openclaw-feishu-reply-voice.sh --apply");
    const repair = await runCommand("bash", ["/Users/crane/.openclaw/scripts/repatch-openclaw-feishu-reply-voice.sh", "--apply"]);
    await log(repair.ok ? "INFO" : "ERROR", `repair exit=${repair.code}`);
    result = await runCommand("openclaw", args);
    if (result.ok) {
      await log("INFO", "preflight ok after repair");
      return true;
    }
  }

  const compact = truncateSummary(result.output);
  await log("ERROR", `preflight failed: ${compact}`);
  return false;
}

async function sleep(ms) {
  await new Promise((r) => setTimeout(r, ms));
}

async function withStateLock(fn) {
  await ensureParent(STATE_FILE);
  for (let i = 0; i < 120; i += 1) {
    try {
      await fs.mkdir(LOCK_DIR);
      break;
    } catch (err) {
      if (err && err.code === "EEXIST") {
        await sleep(50);
        continue;
      }
      throw err;
    }
  }

  try {
    return await fn();
  } finally {
    try {
      await fs.rmdir(LOCK_DIR);
    } catch {
      // ignore
    }
  }
}

async function loadState() {
  try {
    const raw = await fs.readFile(STATE_FILE, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || typeof parsed.keys !== "object") {
      return { version: 1, keys: {} };
    }
    return parsed;
  } catch {
    return { version: 1, keys: {} };
  }
}

async function saveState(state) {
  const tmpPath = `${STATE_FILE}.tmp`;
  await fs.writeFile(tmpPath, JSON.stringify(state), "utf8");
  await fs.rename(tmpPath, STATE_FILE);
}

async function dedupeAllow(key) {
  return await withStateLock(async () => {
    const state = await loadState();
    const now = nowSeconds();

    for (const [k, ts] of Object.entries(state.keys)) {
      if (typeof ts !== "number" || now - ts > DEDUPE_TTL_SECONDS) {
        delete state.keys[k];
      }
    }

    if (state.keys[key]) {
      await saveState(state);
      return false;
    }

    state.keys[key] = now;
    await saveState(state);
    return true;
  });
}

function buildBody(n) {
  return [
    `时间: ${shanghaiTimeString()} (Asia/Shanghai)`,
    `线程ID: ${n.threadId || "-"}`,
    `回合ID: ${n.turnId || "-"}`,
    `目录: ${n.cwd || "-"}`,
    `摘要: ${truncateSummary(n.summary)}`,
  ].join("\n");
}

async function sendNotification(n) {
  const allowed = await dedupeAllow(n.dedupeKey);
  if (!allowed) {
    await log("INFO", `dedupe skip key=${n.dedupeKey}`);
    return;
  }

  const body = buildBody(n);
  const result = await runCommand(SEND_SCRIPT, ["--title", n.title, "--body", body]);
  if (!result.ok) {
    await log("ERROR", `send failed key=${n.dedupeKey} output=${truncateSummary(result.output)}`);
    return;
  }

  await log("INFO", `sent key=${n.dedupeKey} title=${n.title}`);
}

function queueCompletionNotification(n) {
  const threadId = n.threadId || "-";
  pendingCompletions.set(threadId, {
    threadId,
    turnId: n.turnId || "-",
    eventType: n.eventType || "task_complete",
    cwd: n.cwd || "",
    summary: n.summary || "",
    seenAtMs: Date.now(),
    notification: n,
  });
}

async function flushPendingCompletions(force = false) {
  const nowMs = Date.now();
  for (const [threadId, candidate] of pendingCompletions.entries()) {
    if (!force && nowMs - candidate.seenAtMs < COMPLETION_QUIET_MS) continue;
    await sendNotification(candidate.notification);
    pendingCompletions.delete(threadId);
  }
}

async function routeNotification(n, source) {
  if (!n) return;
  if (n.kind === "task_complete") {
    queueCompletionNotification(n);
    await log("INFO", `queue completion source=${source} thread=${n.threadId || "-"} turn=${n.turnId || "-"}`);
    return;
  }
  await sendNotification(n);
}

function normalizeKind(kind, eventType, threadId, turnId, callId, cwd, summary) {
  if (!threadId) threadId = "-";
  if (!turnId) turnId = "-";

  let title;
  let dedupeKey;

  if (kind === "authorization") {
    title = "Codex 等待你授权";
    dedupeKey = `${threadId}:${turnId}:${eventType || "approval"}:${callId || "-"}`;
  } else if (kind === "user_input") {
    title = "Codex 等待你回答";
    dedupeKey = `${threadId}:${turnId}:request_user_input:${callId || "-"}`;
  } else {
    title = "Codex 任务完成";
    dedupeKey = eventType === "agent-turn-complete"
      ? `notify:${threadId}:${turnId}:agent-turn-complete`
      : `${threadId}:${turnId}:task_complete`;
  }

  return {
    kind,
    eventType,
    title,
    dedupeKey,
    threadId,
    turnId,
    callId,
    cwd,
    summary,
  };
}

function parseThreadIdFromPath(filePath) {
  const m = filePath.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i);
  return m ? m[1] : "-";
}

function isFeishuInboundText(raw) {
  if (!raw) return false;
  const text = String(raw);
  return FEISHU_INBOUND_PATTERNS.some((re) => re.test(text));
}

function isFeishuInboundRolloutLine(obj) {
  if (!obj || typeof obj !== "object") return false;

  if (obj.type === "event_msg" && obj.payload?.type === "user_message") {
    return isFeishuInboundText(obj.payload?.message);
  }

  if (obj.type === "response_item" && obj.payload?.type === "message" && obj.payload?.role === "user") {
    const content = Array.isArray(obj.payload?.content) ? obj.payload.content : [];
    return content.some((c) => isFeishuInboundText(c?.text));
  }

  return false;
}

function isFeishuInboundNotifyPayload(payload) {
  if (!payload || typeof payload !== "object") return false;
  if (isFeishuInboundText(payload["last-assistant-message"])) return true;
  const inputMessages = Array.isArray(payload["input-messages"]) ? payload["input-messages"] : [];
  return inputMessages.some((m) => isFeishuInboundText(m));
}

function fromRolloutEvent(payload, threadId, cwd) {
  const t = payload?.type;
  if (!t) return null;

  if (t === "exec_approval_request" || t === "apply_patch_approval_request") {
    return normalizeKind(
      "authorization",
      t,
      threadId,
      payload.turn_id,
      payload.call_id,
      cwd || payload.cwd,
      payload.reason || payload.command?.join(" ") || payload.command,
    );
  }

  if (t === "request_user_input") {
    const firstQ = Array.isArray(payload.questions) && payload.questions.length > 0
      ? payload.questions.map((q) => q.question || "").filter(Boolean).join(" / ")
      : "request_user_input";
    return normalizeKind("user_input", t, threadId, payload.turn_id, payload.call_id, cwd, firstQ);
  }

  if (t === "task_complete") {
    return normalizeKind("task_complete", t, threadId, payload.turn_id, null, cwd, payload.last_agent_message);
  }

  return null;
}

function fromRolloutResponseItem(payload, threadId, turnId, cwd) {
  if (!payload || payload.type !== "function_call") return null;
  if (payload.name !== "request_user_input") return null;

  let args = {};
  if (typeof payload.arguments === "string" && payload.arguments.trim()) {
    try {
      args = JSON.parse(payload.arguments);
    } catch {
      args = {};
    }
  } else if (payload.arguments && typeof payload.arguments === "object") {
    args = payload.arguments;
  }

  const firstQ = Array.isArray(args.questions) && args.questions.length > 0
    ? args.questions.map((q) => q?.question || "").filter(Boolean).join(" / ")
    : "request_user_input";

  return normalizeKind(
    "user_input",
    "request_user_input",
    threadId,
    turnId,
    payload.call_id,
    cwd,
    firstQ,
  );
}

function fromNotifyPayload(payload) {
  if (!payload || payload.type !== "agent-turn-complete") return null;
  const summary = payload["last-assistant-message"] || (payload["input-messages"] || []).join(" ");
  return normalizeKind(
    "task_complete",
    "agent-turn-complete",
    payload["thread-id"],
    payload["turn-id"],
    null,
    payload.cwd,
    summary,
  );
}

function fromAppserverMessage(obj) {
  const method = obj?.method;
  if (!method) return null;

  if (method === "codex/event/exec_approval_request" || method === "codex/event/apply_patch_approval_request") {
    const msg = obj.params?.msg || {};
    return normalizeKind(
      "authorization",
      msg.type || method,
      obj.params?.conversationId || msg.thread_id,
      msg.turn_id,
      msg.call_id,
      msg.cwd,
      msg.reason || msg.command?.join(" ") || msg.command,
    );
  }

  if (method === "codex/event/request_user_input") {
    const msg = obj.params?.msg || {};
    const firstQ = Array.isArray(msg.questions) ? msg.questions.map((q) => q.question || "").filter(Boolean).join(" / ") : "request_user_input";
    return normalizeKind(
      "user_input",
      msg.type || method,
      obj.params?.conversationId,
      msg.turn_id,
      msg.call_id,
      obj.params?.cwd,
      firstQ,
    );
  }

  if (method === "codex/event/task_complete") {
    const msg = obj.params?.msg || {};
    return normalizeKind(
      "task_complete",
      msg.type || method,
      obj.params?.conversationId,
      msg.turn_id || obj.params?.id,
      null,
      obj.params?.cwd,
      msg.last_agent_message,
    );
  }

  if (method === "item/commandExecution/requestApproval" || method === "item/fileChange/requestApproval") {
    const p = obj.params || {};
    return normalizeKind("authorization", method, p.threadId, p.turnId, p.itemId, p.cwd, p.reason || p.command);
  }

  if (method === "item/tool/requestUserInput") {
    const p = obj.params || {};
    const firstQ = Array.isArray(p.questions) ? p.questions.map((q) => q.question || "").filter(Boolean).join(" / ") : "request_user_input";
    return normalizeKind("user_input", method, p.threadId, p.turnId, p.itemId, p.cwd, firstQ);
  }

  return null;
}

async function collectRolloutFiles(root) {
  const out = [];
  const years = await safeReadDir(root);
  for (const y of years) {
    if (!y.isDirectory()) continue;
    const yearPath = path.join(root, y.name);
    const months = await safeReadDir(yearPath);
    for (const m of months) {
      if (!m.isDirectory()) continue;
      const monthPath = path.join(yearPath, m.name);
      const days = await safeReadDir(monthPath);
      for (const d of days) {
        if (!d.isDirectory()) continue;
        const dayPath = path.join(monthPath, d.name);
        const files = await safeReadDir(dayPath);
        for (const f of files) {
          if (!f.isFile()) continue;
          if (!f.name.startsWith("rollout-") || !f.name.endsWith(".jsonl")) continue;
          const p = path.join(dayPath, f.name);
          try {
            const st = await fs.stat(p);
            out.push({ path: p, mtimeMs: st.mtimeMs, size: st.size });
          } catch {
            // ignore
          }
        }
      }
    }
  }

  out.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return out.slice(0, 400);
}

async function safeReadDir(dir) {
  try {
    return await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
}

async function processRolloutFile(entry) {
  const s = fileState.get(entry.path) || {
    offset: READ_HISTORY ? 0 : entry.size,
    remainder: "",
    threadId: parseThreadIdFromPath(entry.path),
    turnId: "",
    cwd: "",
    feishuInbound: false,
    feishuInboundLogged: false,
  };

  if (entry.size < s.offset) {
    s.offset = 0;
    s.remainder = "";
  }

  if (entry.size === s.offset) {
    fileState.set(entry.path, s);
    return;
  }

  const fd = await fs.open(entry.path, "r");
  try {
    const length = entry.size - s.offset;
    const buf = Buffer.alloc(length);
    await fd.read(buf, 0, length, s.offset);
    s.offset = entry.size;

    const merged = s.remainder + buf.toString("utf8");
    const lines = merged.split("\n");
    s.remainder = lines.pop() || "";

    for (const line of lines) {
      if (!line.trim()) continue;
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }

      if (isFeishuInboundRolloutLine(obj)) {
        s.feishuInbound = true;
        if (!s.feishuInboundLogged) {
          s.feishuInboundLogged = true;
          await log("INFO", `mark feishu inbound thread=${s.threadId} file=${path.basename(entry.path)}`);
        }
      }

      if (obj.type === "turn_context") {
        if (obj.payload?.turn_id) s.turnId = obj.payload.turn_id;
        if (obj.payload?.cwd) s.cwd = obj.payload.cwd;
        continue;
      }

      if (obj.type === "response_item") {
        const n = fromRolloutResponseItem(obj.payload, s.threadId, s.turnId, s.cwd);
        if (!n) continue;
        await routeNotification(n, "rollout-response_item");
        continue;
      }

      if (obj.type !== "event_msg") continue;
      const n = fromRolloutEvent(obj.payload, s.threadId, s.cwd);
      if (!n) continue;

      if (n.kind === "task_complete" && s.feishuInbound) {
        await log("INFO", `skip task_complete for feishu inbound thread=${s.threadId} turn=${n.turnId || "-"}`);
        continue;
      }

      await routeNotification(n, "rollout-event_msg");
    }
  } finally {
    await fd.close();
    fileState.set(entry.path, s);
  }
}

async function runRolloutMode() {
  const preflightOk = await preflightFeishu();
  if (!preflightOk) {
    await log("ERROR", "rollout mode stopped due to preflight failure");
    process.exit(2);
  }

  await log("INFO", `rollout mode started root=${SESSIONS_ROOT}`);

  while (true) {
    const entries = await collectRolloutFiles(SESSIONS_ROOT);
    const keep = new Set(entries.map((e) => e.path));

    for (const e of entries) {
      await processRolloutFile(e);
    }

    for (const k of fileState.keys()) {
      if (!keep.has(k)) fileState.delete(k);
    }

    await flushPendingCompletions(false);
    await sleep(POLL_MS);
  }
}

async function runAppserverMode() {
  const preflightOk = await preflightFeishu();
  if (!preflightOk) {
    await log("ERROR", "appserver mode stopped due to preflight failure");
    process.exit(2);
  }

  await log("INFO", "appserver mode started (reading JSON lines from stdin)");
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  const flushTimer = setInterval(() => {
    void flushPendingCompletions(false);
  }, Math.min(Math.max(POLL_MS, 500), 2000));
  flushTimer.unref?.();

  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }

      const n = fromAppserverMessage(obj);
      if (!n) continue;
      await routeNotification(n, "appserver");
    }
  } finally {
    clearInterval(flushTimer);
    await flushPendingCompletions(true);
  }
}

async function runNotifyMode() {
  const payloadRaw = process.env.CODEX_NOTIFY_PAYLOAD || "";
  if (!payloadRaw) {
    await log("WARN", "notify mode without CODEX_NOTIFY_PAYLOAD");
    return;
  }

  let payload;
  try {
    payload = JSON.parse(payloadRaw);
  } catch {
    await log("ERROR", "notify payload is not valid JSON");
    return;
  }

  const n = fromNotifyPayload(payload);
  if (!n) return;
  if (n.kind === "task_complete") {
    await log("INFO", `notify completion ignored; rollout aggregator authoritative thread=${n.threadId || "-"} turn=${n.turnId || "-"}`);
    return;
  }
  await sendNotification(n);
}

async function main() {
  const modeIdx = process.argv.indexOf("--mode");
  const mode = modeIdx >= 0 ? process.argv[modeIdx + 1] : "rollout";

  await ensureParent(STATE_FILE);
  await ensureParent(LOG_FILE);

  if (!fsSync.existsSync(SEND_SCRIPT)) {
    await log("ERROR", `send script missing: ${SEND_SCRIPT}`);
    process.exit(2);
  }

  if (mode === "rollout") {
    await runRolloutMode();
    return;
  }
  if (mode === "appserver") {
    await runAppserverMode();
    return;
  }
  if (mode === "notify") {
    await runNotifyMode();
    return;
  }

  await log("ERROR", `unknown mode: ${mode}`);
  process.exit(2);
}

main().catch(async (err) => {
  try {
    await log("ERROR", `fatal: ${err?.stack || err}`);
  } catch {
    // ignore
  }
  process.exit(1);
});
