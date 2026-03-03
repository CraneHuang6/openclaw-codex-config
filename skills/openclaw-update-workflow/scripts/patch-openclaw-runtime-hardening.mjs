import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_TARGET_ROOT = "/opt/homebrew/lib/node_modules/openclaw/dist";
const REDACT_IMPORT_BASENAME = "redact-CVRUv382.js";
const REPLY_TERMINAL_ASSISTANT_ERROR_MARKER_PATTERN =
  /const\s+terminalAssistantError\s*=\s*lastAssistant\?\.\s*stopReason\s*===\s*"error"\s*;/m;
const REPLY_AUTH_FAILURE_ANCHOR_PATTERN =
  /const\s+authFailure\s*=\s*isAuthAssistantError\(\s*lastAssistant\s*\)\s*;/m;
const REPLY_DROP_FINAL_PAYLOADS_PATTERN =
  /const\s+filteredPayloads\s*=\s*shouldDropFinalPayloads\s*\?\s*\[\]\s*:/m;
const REPLY_PRESERVE_FINAL_MEDIA_PATTERN =
  /const\s+filteredPayloads\s*=\s*shouldDropFinalPayloads\s*\?\s*(?:dedupedPayloads|mediaFilteredPayloads)\.filter\(\(payload\)\s*=>\s*Boolean\(payload\.mediaUrl\)\s*\|\|\s*\(payload\.mediaUrls\?\.length\s*\?\?\s*0\)\s*>\s*0\s*\|\|\s*Boolean\(payload\.audioAsVoice\)\s*\|\|\s*Boolean\(payload\.channelData\s*&&\s*Object\.keys\(payload\.channelData\)\.length\s*>\s*0\)\)\s*:/m;
const REPLY_MEDIA_FILTERED_PAYLOADS_DECLARATION_PATTERN =
  /const\s+mediaFilteredPayloads\s*=/m;
const REPLY_THINK_OVERRIDE_MARKER =
  "const replyOptionThinkLevel = normalizeThinkLevel(opts?.thinking);";
const REPLY_THINK_OVERRIDE_PATTERN =
  /const\s+thinkOverride\s*=\s*normalizeThinkLevel\(opts\.thinking\)\s*;/m;
const DELIVER_REASONING_SUPPRESS_GUARD_MARKER =
  "const hasRenderableContent = Boolean(text || payload.mediaUrl || payload.mediaUrls && payload.mediaUrls.length > 0 || payload.audioAsVoice || payload.channelData && Object.keys(payload.channelData).length > 0);";
const DELIVER_REASONING_SUPPRESS_PATTERN =
  /function\s+shouldSuppressReasoningPayload\s*\(\s*payload\s*\)\s*\{\s*return\s+payload\.isReasoning\s*===\s*true\s*;\s*\}/m;
const MIRROR_TRANSCRIPT_FUNCTION_PATTERN =
  /function\s+resolveMirroredTranscriptText\s*\(\s*params\s*\)\s*\{/m;
const MIRROR_TEXT_PREFERS_TEXT_PATTERN =
  /const\s+trimmed\s*=\s*\(params\.text\s*\?\?\s*""\)\.trim\(\);\s*if\s*\(trimmed\)\s*return\s*trimmed;\s*const\s+mediaUrls[\s\S]*if\s*\(mediaUrls\.length\s*>\s*0\)\s*return\s+"media";\s*return\s+null;/m;
const SUBSYSTEM_APPEND_RAW_LINE_PATTERN =
  /fs\.appendFileSync\(\s*settings\.file\s*,\s*`\$\{line\}\\n`\s*,\s*\{\s*encoding:\s*"utf8"\s*\}\s*\);/m;
const SUBSYSTEM_SANITIZED_ASSIGNMENT_PATTERN = /const\s+sanitized\s*=\s*[^;]+;/m;
const SUBSYSTEM_REDACTED_IMPORT_PATTERN =
  /import\s+\{\s*n\s+as\s+redactSensitiveText\s*\}\s+from\s+"\.\/redact-[^"]+\.js";/m;

function findFunctionBlock(source, signaturePattern) {
  const signatureMatch = signaturePattern.exec(source);
  if (!signatureMatch) {
    return null;
  }

  const start = signatureMatch.index;
  const openBraceIndex = findFunctionBodyOpenBraceIndex(source, start);
  if (openBraceIndex < 0) {
    return null;
  }

  let depth = 0;
  for (let i = openBraceIndex; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === "{") {
      depth += 1;
      continue;
    }
    if (ch !== "}") {
      continue;
    }
    depth -= 1;
    if (depth === 0) {
      return {
        start,
        end: i + 1,
        text: source.slice(start, i + 1),
      };
    }
  }

  return null;
}

function findFunctionBodyOpenBraceIndex(source, signatureStart) {
  const openParenIndex = source.indexOf("(", signatureStart);
  if (openParenIndex < 0) {
    return -1;
  }

  let depth = 0;
  for (let i = openParenIndex; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === "(") {
      depth += 1;
      continue;
    }
    if (ch !== ")") {
      continue;
    }
    depth -= 1;
    if (depth === 0) {
      return source.indexOf("{", i + 1);
    }
  }

  return -1;
}

function findNamedFunctionBlock(source, functionName, startIndex = 0) {
  const signaturePattern = new RegExp(`(?:async\\s+)?function\\s+${functionName}\\s*\\(`, "g");
  signaturePattern.lastIndex = Math.max(0, startIndex);
  const signatureMatch = signaturePattern.exec(source);
  if (!signatureMatch) {
    return null;
  }

  const start = signatureMatch.index;
  const openBraceIndex = findFunctionBodyOpenBraceIndex(source, start);
  if (openBraceIndex < 0) {
    return null;
  }

  let depth = 0;
  for (let i = openBraceIndex; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === "{") {
      depth += 1;
      continue;
    }
    if (ch !== "}") {
      continue;
    }
    depth -= 1;
    if (depth === 0) {
      return {
        start,
        end: i + 1,
        text: source.slice(start, i + 1),
      };
    }
  }

  return null;
}

function removeDuplicateNamedFunctionBlocks(source, functionNames) {
  let updated = source;
  for (const functionName of functionNames) {
    const blocks = [];
    let cursor = 0;
    while (true) {
      const block = findNamedFunctionBlock(updated, functionName, cursor);
      if (!block) break;
      blocks.push(block);
      cursor = block.end;
    }
    if (blocks.length <= 1) continue;

    for (let i = blocks.length - 1; i >= 1; i -= 1) {
      const block = blocks[i];
      updated = `${updated.slice(0, block.start)}${updated.slice(block.end)}`;
    }
  }
  return updated;
}

export function patchGatewayCronSource(source) {
  const helper = `function deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText) {
  const metaErrorMessage =
    typeof runResult?.meta?.error?.message === "string"
      ? runResult.meta.error.message.trim()
      : "";
  if (metaErrorMessage) {
    return { status: "error", error: metaErrorMessage, summary, outputText };
  }

  if (runResult?.meta?.aborted === true) {
    return { status: "error", error: "Embedded run aborted", summary, outputText };
  }

  const stopReason =
    typeof runResult?.meta?.stopReason === "string" ? runResult.meta.stopReason.trim() : "";
  const pendingToolCalls = Array.isArray(runResult?.meta?.pendingToolCalls)
    ? runResult.meta.pendingToolCalls
    : [];
  if (stopReason === "error") {
    return {
      status: "error",
      error: "Embedded run ended with assistant error stopReason",
      summary,
      outputText,
    };
  }
  if (stopReason === "tool_calls" || stopReason === "toolUse" || pendingToolCalls.length > 0) {
    return {
      status: "error",
      error: "Embedded run ended with pending tool calls",
      summary,
      outputText,
    };
  }

  const payloadList = Array.isArray(payloads) ? payloads : [];
  const syntheticRepair = payloadList.some((payload) => {
    const text = typeof payload?.text === "string" ? payload.text : "";
    return text.includes(
      "missing tool result in session history; inserted synthetic error result"
    );
  });
  if (syntheticRepair) {
    return {
      status: "error",
      error: "Session transcript repair inserted synthetic tool result",
      summary,
      outputText,
    };
  }

  const explicitErrorPayload = payloadList.find((payload) => payload?.isError === true);
  if (explicitErrorPayload) {
    const explicitMessage =
      typeof explicitErrorPayload.text === "string" ? explicitErrorPayload.text.trim() : "";
    return {
      status: "error",
      error: explicitMessage || "Embedded run returned an error payload",
      summary,
      outputText,
    };
  }

  return { status: "ok", summary, outputText };
}

function formatCronDayStamp(runAtMs, tz) {
  const timezone = resolveCronTimezone(tz);
  const date = new Date(
    typeof runAtMs === "number" && Number.isFinite(runAtMs) ? runAtMs : Date.now()
  );
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const year = parts.find((entry) => entry.type === "year")?.value ?? "0000";
  const month = parts.find((entry) => entry.type === "month")?.value ?? "01";
  const day = parts.find((entry) => entry.type === "day")?.value ?? "01";
  return \`\${year}-\${month}-\${day}\`;
}

function buildCronDayKey(jobId, tz, runAtMs) {
  const normalizedJobId =
    typeof jobId === "string" && jobId.trim().length > 0 ? jobId.trim() : "unknown-job";
  const timezone = resolveCronTimezone(tz);
  const dayStamp = formatCronDayStamp(runAtMs, timezone);
  return \`\${normalizedJobId}:\${timezone}:\${dayStamp}\`;
}

function isDuplicateSkipStatus(status) {
  if (typeof status !== "string") return false;
  const normalized = status.trim();
  return (
    normalized === "ok" ||
    normalized === "skipped_duplicate" ||
    normalized === "conflict_redirected"
  );
}

async function shouldSkipDuplicateDay(runLogFile, dayKey, opts = {}) {
  if (typeof runLogFile !== "string" || runLogFile.trim().length === 0) return false;
  if (typeof dayKey !== "string" || dayKey.trim().length === 0) return false;

  const entries = await readCronRunLogEntriesCompat(runLogFile, {
    limit: opts.limit ?? 600,
    jobId: opts.jobId,
  });
  if (!Array.isArray(entries) || entries.length === 0) return false;

  const jobId = opts.jobId;
  const tz = opts.tz;
  for (let i = entries.length - 1; i >= 0; i -= 1) {
    const entry = entries[i];
    const entryRunAtMs = entry?.runAtMs;
    if (typeof entryRunAtMs !== "number" || !Number.isFinite(entryRunAtMs)) continue;
    const entryJobId =
      typeof entry?.jobId === "string" && entry.jobId.trim().length > 0
        ? entry.jobId
        : jobId;
    if (!entryJobId) continue;
    const entryDayKey = buildCronDayKey(entryJobId, tz, entryRunAtMs);
    if (entryDayKey !== dayKey) continue;
    if (isDuplicateSkipStatus(entry?.status)) return true;
  }
  return false;
}

async function readCronRunLogEntriesCompat(runLogFile, opts = {}) {
  const limit = Math.max(1, Math.min(2000, Math.floor(opts.limit ?? 600)));
  const jobId =
    typeof opts.jobId === "string" && opts.jobId.trim().length > 0 ? opts.jobId.trim() : "";
  const normalizedPath =
    typeof runLogFile === "string" && runLogFile.trim().length > 0
      ? path.resolve(runLogFile)
      : "";
  if (!normalizedPath) return [];

  if (typeof readCronRunLogEntries === "function") {
    const legacyEntries = await readCronRunLogEntries(normalizedPath, {
      limit,
      jobId: jobId || void 0,
    }).catch(() => null);
    if (Array.isArray(legacyEntries)) return legacyEntries;
  }

  if (typeof readCronRunLogEntriesPage === "function") {
    const page = await readCronRunLogEntriesPage(normalizedPath, {
      limit,
      offset: 0,
      sortDir: "asc",
      jobId: jobId || void 0,
    }).catch(() => null);
    if (Array.isArray(page?.entries)) return page.entries;
  }

  const raw = await fs.promises.readFile(normalizedPath, "utf-8").catch(() => "");
  if (!raw.trim()) return [];

  const parsed = [];
  const lines = raw.split("\\n");
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;
    try {
      const entry = JSON.parse(line);
      if (!entry || typeof entry !== "object") continue;
      if (entry.action !== "finished") continue;
      if (typeof entry.runAtMs !== "number" || !Number.isFinite(entry.runAtMs)) continue;
      if (typeof entry.jobId !== "string" || entry.jobId.trim().length === 0) continue;
      if (jobId && entry.jobId !== jobId) continue;
      parsed.push(entry);
    } catch {}
  }

  if (parsed.length <= limit) return parsed;
  return parsed.slice(parsed.length - limit);
}

function shouldProtectReviewMemory(job, message) {
  const name = typeof job?.name === "string" ? job.name : "";
  const payloadMessage =
    job?.payload?.kind === "agentTurn" && typeof job.payload.message === "string"
      ? job.payload.message
      : "";
  const runtimeMessage = typeof message === "string" ? message : "";
  const combined = \`\${name}\\n\${payloadMessage}\\n\${runtimeMessage}\`;
  if (!/(复盘|review)/i.test(combined)) return false;
  return /(memory\\/YYYY-MM-DD\\.md|每日复盘|复盘日记)/i.test(combined);
}

function shouldProtectDailySingleton(job, message) {
  if (shouldProtectReviewMemory(job, message)) return true;
  const jobId = typeof job?.id === "string" ? job.id.trim() : "";
  if (!jobId) return false;
  return jobId === "fb1707cc-ed1b-431e-9dc7-5348a60a27a5";
}

function shouldBypassDuplicateDayGuard(job) {
  if (process?.env?.OPENCLAW_CRON_ALLOW_DUPLICATE_DAY === "1") return true;
  return job?.__openclawAllowDuplicateDay === true;
}

function snapshotReviewMemoryBeforeRun(params) {
  if (!params?.shouldProtect) return null;
  const workspaceDir = typeof params.workspaceDir === "string" ? params.workspaceDir.trim() : "";
  if (!workspaceDir) return null;

  const runAtMs =
    typeof params.runAtMs === "number" && Number.isFinite(params.runAtMs)
      ? params.runAtMs
      : Date.now();
  const tz = params.tz;
  const dayStamp = formatCronDayStamp(runAtMs, tz);
  const memoryDir = path.join(workspaceDir, "memory");
  const filePath = path.join(memoryDir, \`\${dayStamp}.md\`);

  let preExisted = false;
  let beforeText = null;
  try {
    preExisted = fs.existsSync(filePath) && fs.statSync(filePath).isFile();
    if (preExisted) beforeText = fs.readFileSync(filePath, "utf-8");
  } catch {
    preExisted = false;
    beforeText = null;
  }

  return {
    enabled: true,
    workspaceDir,
    memoryDir,
    dayStamp,
    filePath,
    preExisted,
    beforeText,
    sessionId:
      typeof params.sessionId === "string" && params.sessionId.trim().length > 0
        ? params.sessionId.trim()
        : "",
    changedAfterRun: false,
    afterText: null,
  };
}

function inspectReviewMemoryAfterRun(ctx) {
  if (!ctx?.enabled) return ctx;
  let afterText = null;
  try {
    if (fs.existsSync(ctx.filePath) && fs.statSync(ctx.filePath).isFile()) {
      afterText = fs.readFileSync(ctx.filePath, "utf-8");
    }
  } catch {
    afterText = null;
  }
  return {
    ...ctx,
    afterText,
    changedAfterRun: Boolean(ctx.preExisted && afterText !== ctx.beforeText),
  };
}

function toConflictFileStem(value) {
  const raw = typeof value === "string" ? value.trim() : "";
  const fallback = randomUUID();
  const sanitized = (raw || fallback).replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
  return sanitized || fallback;
}

function restoreMemoryAndArchiveConflict(ctx, opts = {}) {
  if (!ctx?.enabled || !ctx.preExisted || !ctx.changedAfterRun) return null;
  if (typeof ctx.beforeText !== "string") return null;

  const conflictRelativeDir = \`memory/conflicts/\${ctx.dayStamp}\`;
  const conflictDir = path.join(ctx.workspaceDir, conflictRelativeDir);
  fs.mkdirSync(conflictDir, { recursive: true });

  const stem = toConflictFileStem(opts.sessionId ?? ctx.sessionId);
  let conflictPath = path.join(conflictDir, \`\${stem}.md\`);
  let suffix = 1;
  while (fs.existsSync(conflictPath)) {
    conflictPath = path.join(conflictDir, \`\${stem}-\${suffix}.md\`);
    suffix += 1;
  }

  fs.writeFileSync(conflictPath, ctx.afterText ?? "", "utf-8");
  fs.writeFileSync(ctx.filePath, ctx.beforeText, "utf-8");

  return {
    conflictPath,
    reason: opts.reason ?? "conflict_redirected",
  };
}
`;

  const helperSignaturePattern =
    /function\s+deriveCronOutcomeFromRunResult\s*\(\s*runResult\s*,\s*payloads\s*,\s*summary\s*,\s*outputText\s*\)\s*\{/m;
  const helperMarkers = [
    "Session transcript repair inserted synthetic tool result",
    "Embedded run ended with pending tool calls",
    "Embedded run ended with assistant error stopReason",
    "function buildCronDayKey(jobId, tz, runAtMs)",
    "async function shouldSkipDuplicateDay(runLogFile, dayKey, opts = {})",
    "async function readCronRunLogEntriesCompat(runLogFile, opts = {})",
    "function shouldProtectDailySingleton(job, message)",
    "function shouldBypassDuplicateDayGuard(job)",
    "function snapshotReviewMemoryBeforeRun(params)",
    "function restoreMemoryAndArchiveConflict(ctx, opts = {})",
  ];
  const helperFunctionMarkers = [
    "pendingToolCalls",
    'stopReason === "toolUse"',
    'stopReason === "error"',
    "syntheticRepair",
    "explicitErrorPayload",
  ];
  const guardAssignmentPattern =
    /const\s+cronOutcome\s*=\s*deriveCronOutcomeFromRunResult\s*\(\s*runResult\s*,\s*payloads\s*,\s*summary\s*,\s*outputText\s*\)\s*;/m;
  const guardReturnPattern =
    /if\s*\(\s*cronOutcome\.status\s*===\s*"error"\s*\)\s*(?:\{\s*)?return\s+withRunSession\s*\(\s*\{/m;
  const preRunGuardPattern =
    /const\s+(?:reviewMemoryEnabled|dailySingletonEnabled)\s*=\s*(?:shouldProtectReviewMemory|shouldProtectDailySingleton)\(params\.job,\s*params\.message\);/m;
  const stateDedupePattern = /params\.job\?\.state\?\.lastStatus/m;
  const postRunGuardPattern =
    /const\s+reviewMemoryAfter\s*=\s*inspectReviewMemoryAfterRun\(reviewMemoryCtx\);/m;
  const helperBlock = findFunctionBlock(source, helperSignaturePattern);
  const helperAnchor = "function resolveHeartbeatAckMaxChars(agentCfg) {";

  let updated = source;
  if (!helperBlock) {
    if (updated.includes(helperAnchor)) {
      updated = updated.replace(helperAnchor, `${helper}\n${helperAnchor}`);
    } else {
      updated = `${helper}\n${updated}`;
    }
  } else {
    const hasAllHelperMarkers = helperMarkers.every((marker) => source.includes(marker));
    const hasFunctionMarkers = helperFunctionMarkers.every((marker) =>
      helperBlock.text.includes(marker)
    );
    if (!hasAllHelperMarkers || !hasFunctionMarkers) {
      updated = `${source.slice(0, helperBlock.start)}${helper.trimEnd()}${source.slice(
        helperBlock.end
      )}`;
    }
  }

  updated = removeDuplicateNamedFunctionBlocks(updated, [
    "formatCronDayStamp",
    "buildCronDayKey",
    "isDuplicateSkipStatus",
    "shouldSkipDuplicateDay",
    "readCronRunLogEntriesCompat",
    "shouldProtectReviewMemory",
    "shouldProtectDailySingleton",
    "shouldBypassDuplicateDayGuard",
    "snapshotReviewMemoryBeforeRun",
    "inspectReviewMemoryAfterRun",
    "toConflictFileStem",
    "restoreMemoryAndArchiveConflict",
  ]);

  updated = updated.replace(
    /const\s+reviewMemoryEnabled\s*=\s*shouldProtectReviewMemory\(params\.job,\s*params\.message\);/m,
    `const reviewMemoryProtectionEnabled = shouldProtectReviewMemory(params.job, params.message);
const dailySingletonEnabled = shouldProtectDailySingleton(params.job, params.message);
const bypassDuplicateDayGuard = shouldBypassDuplicateDayGuard(params.job);`
  );
  updated = updated.replace(
    /shouldProtect:\s*reviewMemoryEnabled/m,
    "shouldProtect: reviewMemoryProtectionEnabled"
  );
  updated = updated.replace(
    /reviewMemoryEnabled\s*&&/g,
    "dailySingletonEnabled &&\n  !bypassDuplicateDayGuard &&"
  );
  updated = updated.replace(
    /const\s+bypassDuplicateDayGuard\s*=\s*shouldBypassDuplicateDayGuard\(\s*\);/g,
    "const bypassDuplicateDayGuard = shouldBypassDuplicateDayGuard(params.job);"
  );
  updated = updated.replace(/skip duplicate daily review run:/g, "skip duplicate daily run:");

  const hasGuardAssignment = guardAssignmentPattern.test(updated);
  const hasGuardReturn = guardReturnPattern.test(updated);
  const guardAssignment =
    "const cronOutcome = deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText);";
  const guardReturn = `if (cronOutcome.status === "error") return withRunSession({
  status: "error",
  error: cronOutcome.error,
  summary: cronOutcome.summary,
  outputText: cronOutcome.outputText
});`;
  const outcomeGuard = `${guardAssignment}\n${guardReturn}`;

  if (hasGuardAssignment && !hasGuardReturn) {
    updated = updated.replace(guardAssignmentPattern, (match) => `${match}\n${guardReturn}`);
  }
  if (!hasGuardAssignment && hasGuardReturn) {
    updated = updated.replace(guardReturnPattern, `${guardAssignment}\n$&`);
  }
  if (!hasGuardAssignment && !hasGuardReturn) {
    const outputTextAnchor = "const outputText = pickLastNonEmptyTextFromPayloads(payloads);";
    if (updated.includes(outputTextAnchor)) {
      updated = updated.replace(outputTextAnchor, `${outputTextAnchor}\n${outcomeGuard}`);
    } else {
      const deliveryAnchor =
        "const deliveryPayloadHasStructuredContent = Boolean(deliveryPayload?.mediaUrl)";
      if (updated.includes(deliveryAnchor)) {
        updated = updated.replace(deliveryAnchor, `${outcomeGuard}\n${deliveryAnchor}`);
      } else {
        throw new Error("Gateway cron patch anchor not found");
      }
    }
  }

  const dedupeGuard = `const reviewMemoryProtectionEnabled = shouldProtectReviewMemory(params.job, params.message);
const dailySingletonEnabled = shouldProtectDailySingleton(params.job, params.message);
const bypassDuplicateDayGuard = shouldBypassDuplicateDayGuard(params.job);
const reviewMemoryCtx = snapshotReviewMemoryBeforeRun({
  workspaceDir,
  runAtMs: runStartedAt,
  tz: params.job.schedule?.tz,
  sessionId: runSessionId,
  shouldProtect: reviewMemoryProtectionEnabled
});
const cronDayKey = buildCronDayKey(params.job.id, params.job.schedule?.tz, runStartedAt);
const stateLastRunAtMs = params.job?.state?.lastRunAtMs;
const stateDayKey =
  typeof stateLastRunAtMs === "number" && Number.isFinite(stateLastRunAtMs)
    ? buildCronDayKey(params.job.id, params.job.schedule?.tz, stateLastRunAtMs)
    : null;
if (
  dailySingletonEnabled &&
  !bypassDuplicateDayGuard &&
  stateDayKey === cronDayKey &&
  isDuplicateSkipStatus(params.job?.state?.lastStatus)
) {
  const message = \`skip duplicate daily run: \${cronDayKey}\`;
  return withRunSession({
    status: "skipped_duplicate",
    summary: message,
    outputText: message
  });
}
const cronRunLogPath = resolveCronRunLogPath({
  storePath: resolveCronStorePath(params.cfg.cron?.store),
  jobId: params.job.id
});
if (dailySingletonEnabled && !bypassDuplicateDayGuard && await shouldSkipDuplicateDay(cronRunLogPath, cronDayKey, {
  jobId: params.job.id,
  tz: params.job.schedule?.tz
})) {
  const message = \`skip duplicate daily run: \${cronDayKey}\`;
  return withRunSession({
    status: "skipped_duplicate",
    summary: message,
    outputText: message
  });
}`;
  if (!updated.includes('const forceRun = mode === "force" || mode === "force_allow_duplicate_day";')) {
    updated = updated.replace(
      /if\s*\(!isJobDue\(job,\s*now,\s*\{\s*forced:\s*mode === "force"\s*\}\)\)\s*return\s*\{/m,
      'const forceRun = mode === "force" || mode === "force_allow_duplicate_day";\n\t\tif (!isJobDue(job, now, { forced: forceRun })) return {'
    );
  }
  if (!updated.includes("manual-rerun-blocked-non-error")) {
    updated = updated.replace(
      /const\s+forceRun\s*=\s*mode === "force"\s*\|\|\s*mode === "force_allow_duplicate_day";\s*\n\s*if\s*\(!isJobDue\(job,\s*now,\s*\{\s*forced:\s*forceRun\s*\}\)\)\s*return\s*\{/m,
      `const forceRun = mode === "force" || mode === "force_allow_duplicate_day";
\t\tconst bypassManualRerunGate = mode === "force_allow_duplicate_day";
\t\tconst manualErrorOnlyRerunProtectedJob =
\t\t\ttypeof job?.id === "string" &&
\t\t\tjob.id === "fb1707cc-ed1b-431e-9dc7-5348a60a27a5";
\t\tif (
\t\t\tmanualErrorOnlyRerunProtectedJob &&
\t\t\tmode === "force" &&
\t\t\t!bypassManualRerunGate &&
\t\t\ttypeof job?.state?.lastStatus === "string" &&
\t\t\tjob.state.lastStatus !== "error"
\t\t) return {
\t\t\tok: true,
\t\t\tran: false,
\t\t\treason: "manual-rerun-blocked-non-error"
\t\t};
\t\tif (!isJobDue(job, now, { forced: forceRun })) return {`
    );
  }
  if (!updated.includes("executionJob.__openclawAllowDuplicateDay = true;")) {
    updated = updated.replace(
      /const\s+executionJob\s*=\s*JSON\.parse\(JSON\.stringify\(job\)\);/m,
      'const executionJob = JSON.parse(JSON.stringify(job));\n\t\tif (mode === "force_allow_duplicate_day") executionJob.__openclawAllowDuplicateDay = true;'
    );
  }
  if (!updated.includes("allowForceDuplicateMode")) {
    updated = updated.replace(
      /if\s*\(!validateCronRunParams\(params\)\)\s*\{\s*respond\(\s*false\s*,\s*void 0\s*,\s*errorShape\(\s*ErrorCodes\.INVALID_REQUEST\s*,\s*`invalid cron\.run params: \$\{formatValidationErrors\(validateCronRunParams\.errors\)\}`\s*\)\s*\);\s*return;\s*\}/m,
      `const allowForceDuplicateMode =
      typeof params?.id === "string" &&
      params.id.trim().length > 0 &&
      params?.mode === "force_allow_duplicate_day";
    if (!validateCronRunParams(params) && !allowForceDuplicateMode) {
      respond(
        false,
        void 0,
        errorShape(
          ErrorCodes.INVALID_REQUEST,
          \`invalid cron.run params: \${formatValidationErrors(validateCronRunParams.errors)}\`
        )
      );
      return;
    }`
    );
  }
  const preRunAnchor = "let runEndedAt = runStartedAt;";
  if (!preRunGuardPattern.test(updated) && updated.includes(preRunAnchor)) {
    updated = updated.replace(preRunAnchor, `${preRunAnchor}\n${dedupeGuard}`);
  }
  if (!stateDedupePattern.test(updated)) {
    const cronDayKeyAnchor =
      "const cronDayKey = buildCronDayKey(params.job.id, params.job.schedule?.tz, runStartedAt);";
    const stateDedupeGuard = `const stateLastRunAtMs = params.job?.state?.lastRunAtMs;
const stateDayKey =
  typeof stateLastRunAtMs === "number" && Number.isFinite(stateLastRunAtMs)
    ? buildCronDayKey(params.job.id, params.job.schedule?.tz, stateLastRunAtMs)
    : null;
if (
  dailySingletonEnabled &&
  !bypassDuplicateDayGuard &&
  stateDayKey === cronDayKey &&
  isDuplicateSkipStatus(params.job?.state?.lastStatus)
) {
  const message = \`skip duplicate daily run: \${cronDayKey}\`;
  return withRunSession({
    status: "skipped_duplicate",
    summary: message,
    outputText: message
  });
}`;
    if (updated.includes(cronDayKeyAnchor)) {
      updated = updated.replace(cronDayKeyAnchor, `${cronDayKeyAnchor}\n${stateDedupeGuard}`);
    }
  }

  const memoryGuard = `const reviewMemoryAfter = inspectReviewMemoryAfterRun(reviewMemoryCtx);
if (reviewMemoryAfter?.changedAfterRun) {
  const conflict = restoreMemoryAndArchiveConflict(reviewMemoryAfter, {
    reason: "conflict_redirected",
    sessionId: runSessionId
  });
  const conflictMessage = \`review memory conflict redirected: session=\${runSessionId}; file=\${reviewMemoryAfter.filePath}; archive=\${conflict?.conflictPath ?? "n/a"}\`;
  return withRunSession({
    status: "conflict_redirected",
    summary: conflictMessage,
    outputText: conflictMessage
  });
}`;
  const hasReviewMemoryCtx =
    preRunGuardPattern.test(updated) ||
    /const\s+reviewMemoryCtx\s*=\s*snapshotReviewMemoryBeforeRun\(/m.test(updated);
  if (hasReviewMemoryCtx) {
    if (updated.includes(memoryGuard)) {
      updated = updated.replace(memoryGuard, "");
    } else if (postRunGuardPattern.test(updated)) {
      const existingMemoryGuardPattern =
        /const\s+reviewMemoryAfter\s*=\s*inspectReviewMemoryAfterRun\(reviewMemoryCtx\);[\s\S]*?return\s+withRunSession\(\{\s*[\s\S]*?status:\s*"conflict_redirected"[\s\S]*?\}\);\s*\}/m;
      updated = updated.replace(existingMemoryGuardPattern, "");
    }
    updated = updated.replace(
      /\n{2,}(const\s+cronOutcome\s*=\s*deriveCronOutcomeFromRunResult\s*\(\s*runResult\s*,\s*payloads\s*,\s*summary\s*,\s*outputText\s*\)\s*;)/m,
      "\n$1"
    );
    if (guardAssignmentPattern.test(updated)) {
      updated = updated.replace(guardAssignmentPattern, `${memoryGuard}\n$&`);
    } else {
      const outputTextAnchor = "const outputText = pickLastNonEmptyTextFromPayloads(payloads);";
      const synthesizedAnchor =
        "const synthesizedText = outputText?.trim() || summary?.trim() || void 0;";
      const deliveryAnchor =
        "const deliveryPayloadHasStructuredContent = Boolean(deliveryPayload?.mediaUrl)";
      if (updated.includes(outputTextAnchor)) {
        updated = updated.replace(outputTextAnchor, `${outputTextAnchor}\n${memoryGuard}`);
      } else if (updated.includes(synthesizedAnchor)) {
        updated = updated.replace(synthesizedAnchor, `${memoryGuard}\n${synthesizedAnchor}`);
      } else if (updated.includes(deliveryAnchor)) {
        updated = updated.replace(deliveryAnchor, `${memoryGuard}\n${deliveryAnchor}`);
      }
    }
  }

  return updated;
}

export function patchCronCliSource(source) {
  const patchedModeSnippet =
    'mode: opts.due ? "due" : process?.env?.OPENCLAW_CRON_ALLOW_DUPLICATE_DAY === "1" ? "force_allow_duplicate_day" : "force"';
  if (source.includes(patchedModeSnippet)) {
    return source;
  }

  const modePattern = /mode:\s*opts\.due\s*\?\s*"due"\s*:\s*"force"/m;
  if (!modePattern.test(source)) {
    throw new Error("Cron CLI duplicate-day bypass patch anchor not found");
  }

  return source.replace(modePattern, patchedModeSnippet);
}

export function patchReplySource(source) {
  const patchFinalMediaDrop = (input) => {
    if (REPLY_PRESERVE_FINAL_MEDIA_PATTERN.test(input)) {
      return input;
    }

    if (!REPLY_DROP_FINAL_PAYLOADS_PATTERN.test(input)) {
      return input;
    }

    const preservedPayloadsVar = REPLY_MEDIA_FILTERED_PAYLOADS_DECLARATION_PATTERN.test(input)
      ? "mediaFilteredPayloads"
      : "dedupedPayloads";
    const replacement =
      `const filteredPayloads = shouldDropFinalPayloads ? ${preservedPayloadsVar}.filter((payload) => Boolean(payload.mediaUrl) || (payload.mediaUrls?.length ?? 0) > 0 || Boolean(payload.audioAsVoice) || Boolean(payload.channelData && Object.keys(payload.channelData).length > 0)) :`;

    return input.replace(REPLY_DROP_FINAL_PAYLOADS_PATTERN, replacement);
  };
  const patchReplyThinkOverride = (input) => {
    if (input.includes(REPLY_THINK_OVERRIDE_MARKER)) {
      return input;
    }
    if (!REPLY_THINK_OVERRIDE_PATTERN.test(input)) {
      return input;
    }
    return input.replace(
      REPLY_THINK_OVERRIDE_PATTERN,
      `${REPLY_THINK_OVERRIDE_MARKER}\n\tconst thinkOverride = replyOptionThinkLevel;`
    );
  };

  const assistantErrorKindPattern =
    /systemPromptReport:\s*attempt\.systemPromptReport\s*,\s*error:\s*\{\s*kind:\s*"assistant_error"\s*,\s*message\s*\}\s*,?/m;
  const terminalBlockPattern =
    /(if\s*\(\s*terminalAssistantError\s*\)\s*\{[\s\S]*?\n\})\s*\nconst\s+authFailure\s*=\s*isAuthAssistantError\(\s*lastAssistant\s*\)\s*;/m;

  let updated = source;
  const hasTerminalAssistantError = REPLY_TERMINAL_ASSISTANT_ERROR_MARKER_PATTERN.test(source);
  if (hasTerminalAssistantError) {
    const terminalBlockMatch = source.match(terminalBlockPattern);
    if (!terminalBlockMatch) {
      throw new Error("Reply partial patch anchor not found");
    }
    const terminalBlock = terminalBlockMatch[1];
    if (assistantErrorKindPattern.test(terminalBlock)) {
      return patchReplyThinkOverride(patchFinalMediaDrop(updated));
    }
    const partialTerminalBlockWithMetaPattern =
      /(if\s*\(\s*terminalAssistantError\s*\)\s*\{[\s\S]*?systemPromptReport:\s*attempt\.systemPromptReport)\s*,?/m;
    if (!partialTerminalBlockWithMetaPattern.test(terminalBlock)) {
      throw new Error("Reply partial patch anchor not found");
    }
    const patchedTerminalBlock = terminalBlock.replace(
      partialTerminalBlockWithMetaPattern,
      '$1,\n      error: { kind: "assistant_error", message },'
    );
    updated = source.replace(terminalBlock, patchedTerminalBlock);
    return patchReplyThinkOverride(patchFinalMediaDrop(updated));
  }

  if (REPLY_AUTH_FAILURE_ANCHOR_PATTERN.test(source)) {
    const injection = `const terminalAssistantError = lastAssistant?.stopReason === "error";
if (terminalAssistantError) {
  const message = (lastAssistant?.errorMessage ?? "").trim() || "LLM request failed";
  return {
    payloads: [{ text: message, isError: true }],
    meta: {
      durationMs: Date.now() - started,
      agentMeta: {
        sessionId: sessionIdUsed,
        provider,
        model: lastAssistant?.model ?? model.id,
      },
      systemPromptReport: attempt.systemPromptReport,
      error: { kind: "assistant_error", message },
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);`;

    updated = source.replace(REPLY_AUTH_FAILURE_ANCHOR_PATTERN, injection);
    return patchReplyThinkOverride(patchFinalMediaDrop(updated));
  }

  if (REPLY_DROP_FINAL_PAYLOADS_PATTERN.test(source)) {
    return patchReplyThinkOverride(patchFinalMediaDrop(source));
  }

  if (source.includes(REPLY_THINK_OVERRIDE_MARKER)) {
    return source;
  }
  if (REPLY_THINK_OVERRIDE_PATTERN.test(source)) {
    return patchReplyThinkOverride(source);
  }

  throw new Error("Reply patch anchor not found");
}

function isPatchableReplySource(source) {
  return (
    REPLY_TERMINAL_ASSISTANT_ERROR_MARKER_PATTERN.test(source) ||
    REPLY_AUTH_FAILURE_ANCHOR_PATTERN.test(source) ||
    REPLY_DROP_FINAL_PAYLOADS_PATTERN.test(source) ||
    REPLY_THINK_OVERRIDE_PATTERN.test(source) ||
    source.includes(REPLY_THINK_OVERRIDE_MARKER)
  );
}

export function patchDeliverSource(source) {
  if (source.includes(DELIVER_REASONING_SUPPRESS_GUARD_MARKER)) {
    return source;
  }
  if (!DELIVER_REASONING_SUPPRESS_PATTERN.test(source)) {
    throw new Error("Deliver reasoning suppress patch anchor not found");
  }
  return source.replace(
    DELIVER_REASONING_SUPPRESS_PATTERN,
    `function shouldSuppressReasoningPayload(payload) {
\tconst text = typeof payload.text === "string" ? payload.text.trim() : "";
\tconst hasRenderableContent = Boolean(text || payload.mediaUrl || payload.mediaUrls && payload.mediaUrls.length > 0 || payload.audioAsVoice || payload.channelData && Object.keys(payload.channelData).length > 0);
\tif (payload.isReasoning !== true) return false;
\treturn !hasRenderableContent;
}`
  );
}

function isPatchableDeliverSource(source) {
  return (
    DELIVER_REASONING_SUPPRESS_PATTERN.test(source) ||
    source.includes(DELIVER_REASONING_SUPPRESS_GUARD_MARKER)
  );
}

function isPatchableCronCliSource(source) {
  return (
    /mode:\s*opts\.due\s*\?\s*"due"\s*:\s*"force"/m.test(source) ||
    source.includes("force_allow_duplicate_day")
  );
}

function isPatchableMirrorSource(source) {
  return MIRROR_TRANSCRIPT_FUNCTION_PATTERN.test(source);
}

function isPatchableSubsystemSource(source) {
  return (
    SUBSYSTEM_APPEND_RAW_LINE_PATTERN.test(source) ||
    SUBSYSTEM_SANITIZED_ASSIGNMENT_PATTERN.test(source) ||
    SUBSYSTEM_REDACTED_IMPORT_PATTERN.test(source)
  );
}

export function patchMirrorTranscriptSource(source) {
  const block = findFunctionBlock(source, MIRROR_TRANSCRIPT_FUNCTION_PATTERN);
  if (!block) {
    throw new Error("Mirror transcript patch anchor not found");
  }

  if (MIRROR_TEXT_PREFERS_TEXT_PATTERN.test(block.text)) {
    return source;
  }

  const replacement = `function resolveMirroredTranscriptText(params) {
  const trimmed = (params.text ?? "").trim();
  if (trimmed) return trimmed;
  const mediaUrls = params.mediaUrls?.filter((url) => url && url.trim()) ?? [];
  if (mediaUrls.length > 0) return "media";
  return null;
}`;

  return `${source.slice(0, block.start)}${replacement}${source.slice(block.end)}`;
}

export function patchSubsystemSource(source, options = {}) {
  const redactImportPath = options.redactImportPath ?? `./${REDACT_IMPORT_BASENAME}`;
  const redactImportPattern =
    /import\s+\{\s*n\s+as\s+redactSensitiveText\s*\}\s+from\s+"\.\/redact-[^"]+\.js";/m;
  const redactImportStatement = `import { n as redactSensitiveText } from "${redactImportPath}";`;

  let updated = source;
  if (!redactImportPattern.test(updated)) {
    const utilImportPattern = /import\s+util\s+from\s+"node:util";\s*/m;
    if (utilImportPattern.test(updated)) {
      updated = updated.replace(
        utilImportPattern,
        (match) => `${match}${redactImportStatement}\n`
      );
    } else {
      const shebangMatch = updated.match(/^(#![^\n]*\n?)/);
      if (shebangMatch) {
        const shebangLine = shebangMatch[1].endsWith("\n")
          ? shebangMatch[1]
          : `${shebangMatch[1]}\n`;
        const rest = updated.slice(shebangMatch[1].length);
        updated = `${shebangLine}${redactImportStatement}\n${rest}`;
      } else {
        updated = `${redactImportStatement}\n${updated}`;
      }
    }
  }

  const redactedLinePattern =
    /const\s+redactedLine\s*=\s*redactSensitiveText\s*\(\s*line\s*,\s*\{\s*mode:\s*"tools"\s*\}\s*\)\s*;/m;
  const appendRedactedPattern =
    /fs\.appendFileSync\(\s*settings\.file\s*,\s*`\$\{redactedLine\}\\n`\s*,\s*\{\s*encoding:\s*"utf8"\s*\}\s*\);/m;
  const appendLinePattern = SUBSYSTEM_APPEND_RAW_LINE_PATTERN;
  const hasRedactedFileLine = redactedLinePattern.test(updated) && appendRedactedPattern.test(updated);
  const hasRawFileLine = appendLinePattern.test(updated);
  if (!hasRedactedFileLine && hasRawFileLine) {
    updated = updated.replace(
      appendLinePattern,
      "const redactedLine = redactSensitiveText(line, { mode: \"tools\" });\n\t\t\tfs.appendFileSync(settings.file, `${redactedLine}\\n`, { encoding: \"utf8\" });"
    );
  }

  const redactedConsolePattern =
    /const\s+redacted\s*=\s*redactSensitiveText\s*\(\s*sanitized\s*,\s*\{\s*mode:\s*"tools"\s*\}\s*\)\s*;/m;
  const sanitizedLinePattern = /(const\s+sanitized\s*=\s*[^;]+;)/m;
  if (!redactedConsolePattern.test(updated)) {
    if (!sanitizedLinePattern.test(updated)) {
      throw new Error("Subsystem console patch anchor not found");
    }
    updated = updated.replace(
      sanitizedLinePattern,
      '$1\n\tconst redacted = redactSensitiveText(sanitized, { mode: "tools" });'
    );
  }

  updated = updated
    .replace(
      /\(sink\.error\s*\?\?\s*console\.error\)\s*\(\s*sanitized\s*\)/g,
      "(sink.error ?? console.error)(redacted)"
    )
    .replace(
      /\(sink\.warn\s*\?\?\s*console\.warn\)\s*\(\s*sanitized\s*\)/g,
      "(sink.warn ?? console.warn)(redacted)"
    )
    .replace(
      /\(sink\.log\s*\?\?\s*console\.log\)\s*\(\s*sanitized\s*\)/g,
      "(sink.log ?? console.log)(redacted)"
    );

  const sanitizedSinkPattern =
    /\(sink\.(?:error|warn|log)\s*\?\?\s*console\.(?:error|warn|log)\)\s*\(\s*sanitized\s*\)/m;
  if (sanitizedSinkPattern.test(updated)) {
    throw new Error("Subsystem console patch anchor not found");
  }

  return updated;
}

const TARGET_SPECS = [
  {
    kind: "gateway",
    marker: "cron-outcome-guard",
    pattern: /^gateway-cli-.*\.js$/,
    patcher: patchGatewayCronSource,
    isPatchable: () => true,
  },
  {
    kind: "cron-cli",
    marker: "duplicate-day-bypass-mode",
    pattern: /^cron-cli-.*\.js$/,
    patcher: patchCronCliSource,
    isPatchable: isPatchableCronCliSource,
    optional: true,
  },
  {
    kind: "reply",
    marker: "terminal-assistant-error-meta",
    pattern: /^reply-.*\.js$/,
    patcher: patchReplySource,
    isPatchable: isPatchableReplySource,
  },
  {
    kind: "deliver",
    marker: "reasoning-suppress-guard",
    pattern: /^deliver-.*\.js$/,
    patcher: patchDeliverSource,
    isPatchable: isPatchableDeliverSource,
    optional: true,
  },
  {
    kind: "sessions",
    marker: "mirror-transcript-prefers-text",
    pattern: /^sessions-.*\.js$/,
    patcher: patchMirrorTranscriptSource,
    isPatchable: isPatchableMirrorSource,
    optional: true,
  },
  {
    kind: "pi-helpers",
    marker: "mirror-transcript-prefers-text",
    pattern: /^pi-embedded-helpers-.*\.js$/,
    patcher: patchMirrorTranscriptSource,
    isPatchable: isPatchableMirrorSource,
    optional: true,
  },
  {
    kind: "subsystem",
    marker: "redact-sensitive-text",
    pattern: /^(?:subsystem-.*|daemon-cli|entry)\.js$/,
    patcher: patchSubsystemSource,
    isPatchable: isPatchableSubsystemSource,
  },
];

function resolveRedactImportPath(targetRoot) {
  const names = fs
    .readdirSync(targetRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /^redact-.*\.js$/.test(entry.name))
    .map((entry) => entry.name)
    .sort();

  if (names.length === 0) {
    return `./${REDACT_IMPORT_BASENAME}`;
  }

  if (names.includes(REDACT_IMPORT_BASENAME)) {
    return `./${REDACT_IMPORT_BASENAME}`;
  }

  return `./${names[0]}`;
}

function collectPatchTargets(targetRoot) {
  const entries = fs.readdirSync(targetRoot, { withFileTypes: true });
  const files = entries.filter((entry) => entry.isFile()).map((entry) => entry.name);

  const targets = [];
  for (const spec of TARGET_SPECS) {
    const matched = files.filter((name) => spec.pattern.test(name)).sort();
    if (matched.length === 0) {
      if (spec.optional) {
        continue;
      }
      throw new Error(`No ${spec.kind} target files found under ${targetRoot}`);
    }
    let accepted = 0;
    for (const name of matched) {
      const filePath = path.join(targetRoot, name);
      const source = fs.readFileSync(filePath, "utf8");
      if (typeof spec.isPatchable === "function" && !spec.isPatchable(source)) {
        continue;
      }
      accepted += 1;
      targets.push({
        ...spec,
        filePath,
      });
    }

    if (accepted === 0) {
      if (spec.optional) {
        continue;
      }
      throw new Error(`No patchable ${spec.kind} target files found under ${targetRoot}`);
    }
  }

  return targets;
}

export function patchRuntimeTargets(options = {}) {
  const targetRoot = options.targetRoot ?? DEFAULT_TARGET_ROOT;
  const apply = options.apply === true;

  if (!fs.existsSync(targetRoot)) {
    throw new Error(`Target root does not exist: ${targetRoot}`);
  }

  const redactImportPath = resolveRedactImportPath(targetRoot);
  const targets = collectPatchTargets(targetRoot);
  const backupSuffix = new Date().toISOString().replace(/[:.]/g, "-");

  return targets.map((target) => {
    const source = fs.readFileSync(target.filePath, "utf8");
    const patched =
      target.kind === "subsystem"
        ? patchSubsystemSource(source, { redactImportPath })
        : target.patcher(source);
    const changed = patched !== source;

    let backupPath = null;
    if (apply && changed) {
      backupPath = `${target.filePath}.bak.${backupSuffix}`;
      fs.copyFileSync(target.filePath, backupPath);
      fs.writeFileSync(target.filePath, patched, "utf8");
    }

    return {
      kind: target.kind,
      filePath: target.filePath,
      marker: target.marker,
      changed,
      backupPath,
    };
  });
}

function parseCliArgs(argv) {
  let apply = false;
  let dryRun = false;
  let targetRoot = DEFAULT_TARGET_ROOT;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === "--help" || arg === "-h") {
      return { help: true, apply: false, targetRoot };
    }

    if (arg === "--apply") {
      apply = true;
      continue;
    }

    if (arg === "--dry-run") {
      dryRun = true;
      continue;
    }

    if (arg === "--target-root") {
      const value = argv[i + 1];
      if (!value) {
        throw new Error("Missing value for --target-root");
      }
      targetRoot = value;
      i += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  if (apply && dryRun) {
    throw new Error("Use either --apply or --dry-run, not both");
  }

  if (!apply && !dryRun) {
    dryRun = true;
  }

  return {
    help: false,
    apply,
    targetRoot,
  };
}

function printUsage() {
  console.log("Usage: node scripts/patch-openclaw-runtime-hardening.mjs [--dry-run|--apply] [--target-root <dir>]");
}

function isDirectExecution() {
  if (!process.argv[1]) {
    return false;
  }
  return path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
}

function formatCliLine(result, apply) {
  if (apply) {
    if (result.changed) {
      return `[apply] patched ${result.kind} marker=${result.marker} file=${result.filePath} backup=${result.backupPath}`;
    }
    return `[apply] unchanged ${result.kind} marker=${result.marker} file=${result.filePath}`;
  }

  return `[dry-run] ${result.changed ? "would-patch" : "unchanged"} ${result.kind} marker=${result.marker} file=${result.filePath}`;
}

function main() {
  const cli = parseCliArgs(process.argv.slice(2));
  if (cli.help) {
    printUsage();
    return;
  }

  const results = patchRuntimeTargets({
    targetRoot: cli.targetRoot,
    apply: cli.apply,
  });

  for (const result of results) {
    console.log(formatCliLine(result, cli.apply));
  }

  const changedCount = results.filter((result) => result.changed).length;
  if (cli.apply) {
    console.log(`Patched ${changedCount}/${results.length} target files.`);
  } else {
    console.log(`Would patch ${changedCount}/${results.length} target files.`);
  }
}

if (isDirectExecution()) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
