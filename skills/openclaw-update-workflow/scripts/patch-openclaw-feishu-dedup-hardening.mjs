import path from "node:path";
import { access, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const DEFAULT_TARGET_ROOT = "/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src";
const DEDUP_STATE_FILE_SIGNATURE_PATTERN =
  /const\s+DEDUP_STATE_FILE\s*=\s*[\s\S]*?OPENCLAW_FEISHU_DEDUP_STATE_FILE[\s\S]*?feishu-dedup-message-ids\.json/;
const LOAD_PERSISTED_MESSAGE_IDS_SIGNATURE_PATTERN =
  /function\s+loadPersistedMessageIds\s*\(\s*\)\s*:\s*Map<\s*string\s*,\s*number\s*>\s*\{/;
const TRY_RECORD_MESSAGE_PERSISTENT_EXPORT_SIGNATURE_PATTERN =
  /export\s+async\s+function\s+tryRecordMessagePersistent\s*\(/;

const DEDUP_TTL_PATTERN =
  /const\s+DEDUP_TTL_MS\s*=\s*30\s*\*\s*60\s*\*\s*1000\s*;\s*\/\/\s*30\s*minutes/;
const DEDUP_CLEANUP_PATTERN =
  /const\s+DEDUP_CLEANUP_INTERVAL_MS\s*=\s*5\s*\*\s*60\s*\*\s*1000\s*;\s*\/\/\s*cleanup every 5 minutes/;
const RECEIVE_LOG_WITHOUT_MESSAGE_ID_PATTERN =
  /feishu\[\$\{account\.accountId\}\]: received message from \$\{ctx\.senderOpenId\} in \$\{ctx\.chatId\} \(\$\{ctx\.chatType\}\)(?! messageId=\$\{ctx\.messageId\})(?! eventId=\$\{eventId\})/g;
const RECEIVE_LOG_WITH_MESSAGE_ID_PATTERN =
  /feishu\[\$\{account\.accountId\}\]: received message from \$\{ctx\.senderOpenId\} in \$\{ctx\.chatId\} \(\$\{ctx\.chatType\}\) messageId=\$\{ctx\.messageId\}(?! eventId=\$\{eventId\})/g;
const DUPLICATE_LOG_PATTERN =
  /log\(`feishu: skipping duplicate message \$\{messageId\}`\);/g;
const MESSAGE_ID_DECL_PATTERN = /const\s+messageId\s*=\s*event\.message\.message_id\s*;/;
const EVENT_ID_DECL_PATTERN = /const\s+eventId\s*=\s*/;

function renderPersistentDedupSource() {
  return `import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Prevent duplicate processing when WebSocket reconnects or Feishu redelivers messages.
const DEDUP_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours
const DEDUP_MAX_SIZE = 1_000;
const DEDUP_CLEANUP_INTERVAL_MS = 10 * 60 * 1000; // cleanup every 10 minutes
const DEDUP_STATE_FILE =
  process.env.OPENCLAW_FEISHU_DEDUP_STATE_FILE ||
  path.join(os.homedir(), ".openclaw", "state", "feishu-dedup-message-ids.json");

const processedMessageIds = loadPersistedMessageIds(); // messageId -> timestamp
let lastCleanupTime = 0;

function loadPersistedMessageIds(): Map<string, number> {
  try {
    const raw = fs.readFileSync(DEDUP_STATE_FILE, "utf8");
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") {
      return new Map();
    }
    const map = new Map<string, number>();
    for (const [id, ts] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof id !== "string" || typeof ts !== "number" || !Number.isFinite(ts)) {
        continue;
      }
      map.set(id, ts);
    }
    return map;
  } catch {
    return new Map();
  }
}

function persistMessageIds() {
  try {
    fs.mkdirSync(path.dirname(DEDUP_STATE_FILE), { recursive: true });
    fs.writeFileSync(
      DEDUP_STATE_FILE,
      JSON.stringify(Object.fromEntries(processedMessageIds), null, 2),
      "utf8"
    );
  } catch {
    // Best-effort persistence only.
  }
}

function cleanupExpired(now: number) {
  let changed = false;
  for (const [id, ts] of processedMessageIds) {
    if (now - ts > DEDUP_TTL_MS) {
      processedMessageIds.delete(id);
      changed = true;
    }
  }
  if (changed) {
    persistMessageIds();
  }
}

export function tryRecordMessage(messageId: string): boolean {
  const now = Date.now();

  // Throttled cleanup: evict expired entries at most once per interval.
  if (now - lastCleanupTime > DEDUP_CLEANUP_INTERVAL_MS) {
    cleanupExpired(now);
    lastCleanupTime = now;
  }

  if (processedMessageIds.has(messageId)) {
    return false;
  }

  // Evict oldest entries if cache is full.
  if (processedMessageIds.size >= DEDUP_MAX_SIZE) {
    const first = processedMessageIds.keys().next().value!;
    processedMessageIds.delete(first);
  }

  processedMessageIds.set(messageId, now);
  persistMessageIds();
  return true;
}

// Backward-compatible async API expected by patched bot.ts in some local workflows.
// Namespace/log parameters are accepted for signature compatibility.
export async function tryRecordMessagePersistent(
  messageId: string,
  _namespace = "global",
  _log?: (...args: unknown[]) => void,
): Promise<boolean> {
  return tryRecordMessage(messageId);
}
`;
}

function hasPersistentDedupSignature(source) {
  return (
    DEDUP_STATE_FILE_SIGNATURE_PATTERN.test(source) &&
    LOAD_PERSISTED_MESSAGE_IDS_SIGNATURE_PATTERN.test(source) &&
    TRY_RECORD_MESSAGE_PERSISTENT_EXPORT_SIGNATURE_PATTERN.test(source)
  );
}

export function patchFeishuDedupSource(source) {
  if (hasPersistentDedupSignature(source)) {
    return source;
  }

  if (
    source.includes("processedMessageIds = new Map") ||
    source.includes("tryRecordMessage(") ||
    DEDUP_TTL_PATTERN.test(source) ||
    DEDUP_CLEANUP_PATTERN.test(source)
  ) {
    return renderPersistentDedupSource();
  }

  return source;
}

export function patchFeishuBotLoggingSource(source) {
  let updated = source;

  if (!EVENT_ID_DECL_PATTERN.test(updated) && MESSAGE_ID_DECL_PATTERN.test(updated)) {
    updated = updated.replace(
      MESSAGE_ID_DECL_PATTERN,
      `const messageId = event.message.message_id;
  const eventId =
    typeof (event as { event_id?: string }).event_id === "string" &&
    (event as { event_id?: string }).event_id
      ? (event as { event_id?: string }).event_id
      : "unknown";`
    );
  }

  updated = updated.replace(
    DUPLICATE_LOG_PATTERN,
    "log(`feishu: skipping duplicate message ${messageId} eventId=${eventId}`);"
  );

  updated = updated.replace(
    RECEIVE_LOG_WITHOUT_MESSAGE_ID_PATTERN,
    "feishu[${account.accountId}]: received message from ${ctx.senderOpenId} in ${ctx.chatId} (${ctx.chatType}) messageId=${ctx.messageId} eventId=${eventId}"
  );

  updated = updated.replace(
    RECEIVE_LOG_WITH_MESSAGE_ID_PATTERN,
    "feishu[${account.accountId}]: received message from ${ctx.senderOpenId} in ${ctx.chatId} (${ctx.chatType}) messageId=${ctx.messageId} eventId=${eventId}"
  );

  return updated;
}

export function patchFeishuSources({ dedupSource, botSource }) {
  return {
    dedupPatched: patchFeishuDedupSource(dedupSource),
    botPatched: patchFeishuBotLoggingSource(botSource),
  };
}

export async function applyPatchToTargetRoot({
  targetRoot = DEFAULT_TARGET_ROOT,
  apply = false,
} = {}) {
  const dedupPath = path.join(targetRoot, "dedup.ts");
  const botPath = path.join(targetRoot, "bot.ts");

  const dedupOriginal = await readFile(dedupPath, "utf8");
  const botOriginal = await readFile(botPath, "utf8");

  const { dedupPatched, botPatched } = patchFeishuSources({
    dedupSource: dedupOriginal,
    botSource: botOriginal,
  });

  const dedupChanged = dedupPatched !== dedupOriginal;
  const botChanged = botPatched !== botOriginal;

  if (apply && dedupChanged) {
    const backupPath = `${dedupPath}.bak`;
    try {
      await access(backupPath);
    } catch {
      await writeFile(backupPath, dedupOriginal, "utf8");
    }
    await writeFile(dedupPath, dedupPatched, "utf8");
  }

  if (apply && botChanged) {
    const backupPath = `${botPath}.bak`;
    try {
      await access(backupPath);
    } catch {
      await writeFile(backupPath, botOriginal, "utf8");
    }
    await writeFile(botPath, botPatched, "utf8");
  }

  return {
    targetRoot,
    dedupPath,
    botPath,
    dedupChanged,
    botChanged,
    apply,
  };
}

function parseCliArgs(argv) {
  let apply = false;
  let targetRoot = DEFAULT_TARGET_ROOT;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === "--apply") {
      apply = true;
      continue;
    }
    if (arg === "--dry-run") {
      apply = false;
      continue;
    }
    if (arg === "--target-root") {
      i += 1;
      if (i >= argv.length) {
        throw new Error("Missing value for --target-root");
      }
      targetRoot = argv[i];
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  return { apply, targetRoot };
}

const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const result = await applyPatchToTargetRoot(parseCliArgs(process.argv.slice(2)));
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
