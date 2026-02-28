import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  patchDeliverSource,
  patchGatewayCronSource,
  patchMirrorTranscriptSource,
  patchReplySource,
  patchSubsystemSource,
  patchRuntimeTargets,
} from "../patch-openclaw-runtime-hardening.mjs";

const gatewayFixture = fs.readFileSync(
  new URL("./fixtures/cron-review-gateway-source.fixture.js", import.meta.url),
  "utf8"
);

test("patchGatewayCronSource injects cron outcome guard", () => {
  const input = `
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
`;

  const out = patchGatewayCronSource(input);
  assert.match(out, /deriveCronOutcomeFromRunResult/);
  assert.match(out, /cronOutcome\.status === "error"/);
});

test("patchGatewayCronSource injects same-day dedupe guard", () => {
  const out = patchGatewayCronSource(gatewayFixture);

  assert.match(out, /buildCronDayKey/);
  assert.match(out, /shouldSkipDuplicateDay/);
  assert.match(out, /readCronRunLogEntriesCompat/);
  assert.match(out, /await readCronRunLogEntriesCompat\(runLogFile/);
  assert.match(out, /params\.job\?\.state\?\.lastStatus/);
  assert.match(out, /status:\s*"skipped_duplicate"/);
});

test("patchGatewayCronSource removes duplicate helper overrides", () => {
  const duplicated = `${patchGatewayCronSource(gatewayFixture)}

async function shouldSkipDuplicateDay(runLogFile, dayKey, opts = {}) {
  const entries = await readCronRunLogEntries(runLogFile, {
    limit: opts.limit ?? 600,
    jobId: opts.jobId,
  }).catch(() => []);
  return Array.isArray(entries) && entries.length > 0 && Boolean(dayKey);
}
`;
  const out = patchGatewayCronSource(duplicated);
  const shouldSkipCount = (out.match(/async function shouldSkipDuplicateDay\(/g) ?? []).length;

  assert.equal(shouldSkipCount, 1);
  assert.match(out, /await readCronRunLogEntriesCompat\(runLogFile/);
});

test("patchGatewayCronSource injects memory snapshot restore guard", () => {
  const out = patchGatewayCronSource(gatewayFixture);

  assert.match(out, /snapshotReviewMemoryBeforeRun/);
  assert.match(out, /restoreMemoryAndArchiveConflict/);
  assert.match(out, /status:\s*"conflict_redirected"/);
  assert.match(out, /memory\/conflicts\//);
});

test("patchGatewayCronSource places memory conflict guard before cronOutcome error return", () => {
  const out = patchGatewayCronSource(gatewayFixture);

  const memoryGuardIdx = out.indexOf(
    "const reviewMemoryAfter = inspectReviewMemoryAfterRun(reviewMemoryCtx);"
  );
  const errorReturnIdx = out.indexOf(
    'if (cronOutcome.status === "error") return withRunSession({'
  );

  assert.ok(memoryGuardIdx >= 0, "memory guard should exist");
  assert.ok(errorReturnIdx >= 0, "cron outcome error return should exist");
  assert.ok(
    memoryGuardIdx < errorReturnIdx,
    "memory guard must run before cronOutcome error return"
  );
});

test("patchGatewayCronSource does not treat stray status strings as injected guards", () => {
  const input = `
const runStartedAt = Date.now();
let runEndedAt = runStartedAt;
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
const noisy = 'status: "skipped_duplicate" and status: "conflict_redirected"';
const synthesizedText = outputText?.trim() || summary?.trim() || void 0;
`;
  const out = patchGatewayCronSource(input);

  assert.match(
    out,
    /const reviewMemoryEnabled = shouldProtectReviewMemory\(params\.job, params\.message\);/
  );
  assert.match(
    out,
    /const reviewMemoryAfter = inspectReviewMemoryAfterRun\(reviewMemoryCtx\);/
  );
});

test("patchGatewayCronSource is idempotent for the same input", () => {
  const input = `
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
`;

  const once = patchGatewayCronSource(input);
  const twice = patchGatewayCronSource(once);

  assert.equal(twice, once);
});

test("patchGatewayCronSource is idempotent for full cron gateway fixture", () => {
  const once = patchGatewayCronSource(gatewayFixture);
  const twice = patchGatewayCronSource(once);

  assert.equal(twice, once);
});

test("patchGatewayCronSource recovers partial patch with helper but missing guard", () => {
  const input = `
function deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText) {
  return { status: "ok", summary, outputText };
}
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
`;

  const out = patchGatewayCronSource(input);

  assert.match(out, /cronOutcome\.status === "error"/);
});

test("patchGatewayCronSource does not duplicate equivalent guard with whitespace variants", () => {
  const input = `
function deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText) {
  return { status: "ok", summary, outputText };
}
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
const cronOutcome    =
  deriveCronOutcomeFromRunResult(
    runResult,
    payloads,
    summary,
    outputText
  );
if (cronOutcome.status === "error") return withRunSession({
  status: "error",
  error: cronOutcome.error,
  summary: cronOutcome.summary,
  outputText: cronOutcome.outputText
});
`;

  const out = patchGatewayCronSource(input);
  const cronOutcomeCount = (out.match(/const\s+cronOutcome/g) ?? []).length;

  assert.equal(cronOutcomeCount, 1);
});

test("patchGatewayCronSource accepts brace-form error return guard as already patched", () => {
  const input = `
function deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText) {
  return { status: "ok", summary, outputText };
}
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
const cronOutcome = deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText);
if (cronOutcome.status === "error") {
  return withRunSession({
    status: "error",
    error: cronOutcome.error,
    summary: cronOutcome.summary,
    outputText: cronOutcome.outputText
  });
}
`;

  const out = patchGatewayCronSource(input);
  const guardCount = (out.match(/cronOutcome\.status\s*===\s*"error"/g) ?? []).length;

  assert.equal(guardCount, 1);
});

test("patchGatewayCronSource adds missing error-return guard when assignment exists alone", () => {
  const input = `
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
const cronOutcome =
  deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText);
`;

  const out = patchGatewayCronSource(input);

  assert.match(out, /if \(cronOutcome\.status === "error"\)/);
});

test("patchGatewayCronSource replaces broken helper body when signature already exists", () => {
  const input = `
function deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText) {
  return { status: "ok", summary, outputText };
}
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
`;

  const out = patchGatewayCronSource(input);

  assert.match(out, /metaErrorMessage|Embedded run aborted/);
});

test("patchGatewayCronSource replaces helper missing synthetic repair branch", () => {
  const input = `
function deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText) {
  const metaErrorMessage = runResult?.meta?.error?.message?.trim?.() ?? "";
  if (metaErrorMessage) return { status: "error", error: metaErrorMessage, summary, outputText };
  if (runResult?.meta?.aborted === true) {
    return { status: "error", error: "Embedded run aborted", summary, outputText };
  }
  return { status: "ok", summary, outputText };
}
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
`;

  const out = patchGatewayCronSource(input);

  assert.match(out, /stopReason === "tool_calls"/);
  assert.match(out, /stopReason === "toolUse"/);
  assert.match(out, /stopReason === "error"/);
  assert.match(out, /pendingToolCalls/);
  assert.match(out, /Embedded run ended with pending tool calls/);
  assert.match(out, /syntheticRepair/);
  assert.match(out, /explicitErrorPayload/);
  assert.match(out, /Session transcript repair inserted synthetic tool result/);
});

test("patchGatewayCronSource upgrades legacy helper missing compat run-log reader", () => {
  const legacyPatched = patchGatewayCronSource(gatewayFixture).replace(
    /readCronRunLogEntriesCompat/g,
    "readCronRunLogEntries"
  );

  const out = patchGatewayCronSource(legacyPatched);

  assert.match(out, /readCronRunLogEntriesCompat/);
  assert.match(out, /typeof readCronRunLogEntriesPage === "function"/);
});

test("patchGatewayCronSource replaces incomplete helper even when marker strings appear outside helper", () => {
  const input = `
function deriveCronOutcomeFromRunResult(runResult, payloads, summary, outputText) {
  return { status: "ok", summary, outputText };
}
// Session transcript repair inserted synthetic tool result
// function buildCronDayKey(jobId, tz, runAtMs)
// async function shouldSkipDuplicateDay(runLogFile, dayKey, opts = {})
// function snapshotReviewMemoryBeforeRun(params)
// function restoreMemoryAndArchiveConflict(ctx, opts = {})
const payloads = runResult.payloads ?? [];
const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);
const outputText = pickLastNonEmptyTextFromPayloads(payloads);
`;

  const out = patchGatewayCronSource(input);

  assert.match(out, /syntheticRepair/);
  assert.match(out, /explicitErrorPayload/);
});

test("patchMirrorTranscriptSource prefers explicit text over media filename mirrors", () => {
  const input = `
function resolveMirroredTranscriptText(params) {
  const mediaUrls = params.mediaUrls?.filter((url) => url && url.trim()) ?? [];
  if (mediaUrls.length > 0) {
    const names = mediaUrls
      .map((url) => extractFileNameFromMediaUrl(url))
      .filter((name) => Boolean(name && name.trim()));
    if (names.length > 0) return names.join(", ");
    return "media";
  }
  const trimmed = (params.text ?? "").trim();
  return trimmed ? trimmed : null;
}
`;

  const out = patchMirrorTranscriptSource(input);

  assert.match(out, /const trimmed = \(params\.text \?\? ""\)\.trim\(\);/);
  assert.match(out, /if \(trimmed\) return trimmed;/);
  assert.match(out, /if \(mediaUrls\.length > 0\) return "media";/);
  assert.doesNotMatch(out, /names\.join\(", "\)/);
});

test("patchMirrorTranscriptSource is idempotent", () => {
  const input = `
function resolveMirroredTranscriptText(params) {
  const mediaUrls = params.mediaUrls?.filter((url) => url && url.trim()) ?? [];
  if (mediaUrls.length > 0) {
    const names = mediaUrls.map((url) => extractFileNameFromMediaUrl(url)).filter((name) => Boolean(name && name.trim()));
    if (names.length > 0) return names.join(", ");
    return "media";
  }
  const trimmed = (params.text ?? "").trim();
  return trimmed ? trimmed : null;
}
`;

  const once = patchMirrorTranscriptSource(input);
  const twice = patchMirrorTranscriptSource(once);

  assert.equal(twice, once);
});

test("patchReplySource injects terminal assistant error metadata", () => {
  const input = `
const authFailure = isAuthAssistantError(lastAssistant);
const rateLimitFailure = isRateLimitAssistantError(lastAssistant);
`;

  const out = patchReplySource(input);
  assert.match(
    out,
    /const terminalAssistantError = lastAssistant\?\.stopReason === "error";/
  );
  assert.doesNotMatch(out, /!aborted &&/);
  assert.match(out, /kind: "assistant_error"/);
});

test("patchReplySource is idempotent for the same input", () => {
  const input = `
const authFailure = isAuthAssistantError(lastAssistant);
const rateLimitFailure = isRateLimitAssistantError(lastAssistant);
`;

  const once = patchReplySource(input);
  const twice = patchReplySource(once);

  assert.equal(twice, once);
});

test("patchReplySource upgrades reply thinking override to optional-chain marker", () => {
  const input = `
const thinkOverride = normalizeThinkLevel(opts.thinking);
const thinkOnce = normalizeThinkLevel(opts.thinkingOnce);
`;

  const out = patchReplySource(input);

  assert.match(out, /const replyOptionThinkLevel = normalizeThinkLevel\(opts\?\.thinking\);/);
  assert.match(out, /const thinkOverride = replyOptionThinkLevel;/);
});

test("patchDeliverSource keeps renderable reasoning payloads", () => {
  const input = `
function shouldSuppressReasoningPayload(payload) {
  return payload.isReasoning === true;
}
`;

  const out = patchDeliverSource(input);

  assert.match(
    out,
    /const hasRenderableContent = Boolean\(text \|\| payload\.mediaUrl \|\| payload\.mediaUrls && payload\.mediaUrls\.length > 0 \|\| payload\.audioAsVoice \|\| payload\.channelData && Object\.keys\(payload\.channelData\)\.length > 0\);/
  );
  assert.match(out, /if \(payload\.isReasoning !== true\) return false;/);
  assert.match(out, /return !hasRenderableContent;/);
});

test("patchReplySource keeps media final payloads when block streaming already sent text blocks", () => {
  const input = `
const authFailure = isAuthAssistantError(lastAssistant);
const shouldDropFinalPayloads =
  params.blockStreamingEnabled &&
  Boolean(params.blockReplyPipeline?.didStream()) &&
  !params.blockReplyPipeline?.isAborted();
const filteredPayloads = shouldDropFinalPayloads
  ? []
  : params.blockStreamingEnabled
    ? dedupedPayloads.filter((payload) => !params.blockReplyPipeline?.hasSentPayload(payload))
    : dedupedPayloads;
`;

  const out = patchReplySource(input);

  assert.match(
    out,
    /const filteredPayloads = shouldDropFinalPayloads[\s\S]*\? dedupedPayloads\.filter\(\(payload\) =>[\s\S]*payload\.mediaUrl/
  );
  assert.match(out, /payload\.mediaUrls\?\.length/);
  assert.match(out, /payload\.audioAsVoice/);
  assert.match(out, /payload\.channelData && Object\.keys\(payload\.channelData\)\.length > 0/);
});

test("patchReplySource uses mediaFilteredPayloads when that list is present", () => {
  const input = `
const authFailure = isAuthAssistantError(lastAssistant);
const shouldDropFinalPayloads =
  params.blockStreamingEnabled &&
  Boolean(params.blockReplyPipeline?.didStream()) &&
  !params.blockReplyPipeline?.isAborted();
const mediaFilteredPayloads = filterMessagingToolMediaDuplicates({
  payloads: [],
  sentMediaUrls: []
});
const filteredPayloads = shouldDropFinalPayloads
  ? []
  : params.blockStreamingEnabled
    ? mediaFilteredPayloads.filter((payload) => !params.blockReplyPipeline?.hasSentPayload(payload))
    : mediaFilteredPayloads;
`;

  const out = patchReplySource(input);

  assert.match(out, /shouldDropFinalPayloads \? mediaFilteredPayloads\.filter\(/);
  assert.doesNotMatch(out, /shouldDropFinalPayloads \? dedupedPayloads\.filter\(/);
});

test("patchReplySource media-final safeguard is idempotent", () => {
  const input = `
const authFailure = isAuthAssistantError(lastAssistant);
const shouldDropFinalPayloads =
  params.blockStreamingEnabled &&
  Boolean(params.blockReplyPipeline?.didStream()) &&
  !params.blockReplyPipeline?.isAborted();
const filteredPayloads = shouldDropFinalPayloads
  ? []
  : params.blockStreamingEnabled
    ? dedupedPayloads.filter((payload) => !params.blockReplyPipeline?.hasSentPayload(payload))
    : dedupedPayloads;
`;

  const once = patchReplySource(input);
  const twice = patchReplySource(once);

  assert.equal(twice, once);
});

test('patchReplySource recovers partial patch with terminalAssistantError but missing "assistant_error"', () => {
  const input = `
const terminalAssistantError = lastAssistant?.stopReason === "error";
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
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);
const rateLimitFailure = isRateLimitAssistantError(lastAssistant);
`;

  const out = patchReplySource(input);

  assert.match(out, /kind: "assistant_error"/);
});

test('patchReplySource adds terminal meta.error even when unrelated "assistant_error" exists elsewhere', () => {
  const input = `
const unrelated = { kind: "assistant_error", message: "outside terminal block" };
const terminalAssistantError = lastAssistant?.stopReason === "error";
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
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);
`;

  const out = patchReplySource(input);

  assert.match(
    out,
    /systemPromptReport: attempt\.systemPromptReport,\n\s*error: \{ kind: "assistant_error", message \},/
  );
});

test("patchReplySource does not re-inject when terminalAssistantError declaration spacing differs", () => {
  const input = `
const terminalAssistantError=lastAssistant?.stopReason === "error";
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
const authFailure = isAuthAssistantError(lastAssistant);
`;

  const out = patchReplySource(input);
  const terminalDeclarationCount = (out.match(/const\s+terminalAssistantError\b/g) ?? []).length;

  assert.equal(terminalDeclarationCount, 1);
});

test("patchReplySource recovers partial patch when terminal if-guard has compact spacing", () => {
  const input = `
const terminalAssistantError=lastAssistant?.stopReason === "error";
if(terminalAssistantError){
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
      systemPromptReport: attempt.systemPromptReport
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);
`;

  assert.doesNotThrow(() => patchReplySource(input));

  const out = patchReplySource(input);
  assert.match(
    out,
    /systemPromptReport: attempt\.systemPromptReport,\n\s*error: \{ kind: "assistant_error", message \},/
  );
});

test("patchReplySource recovers partial patch when systemPromptReport has no trailing comma", () => {
  const input = `
const terminalAssistantError = lastAssistant?.stopReason === "error";
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
      systemPromptReport: attempt.systemPromptReport
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);
`;

  assert.doesNotThrow(() => patchReplySource(input));

  const out = patchReplySource(input);
  assert.match(
    out,
    /systemPromptReport: attempt\.systemPromptReport,\n\s*error: \{ kind: "assistant_error", message \},/
  );
});

test('patchReplySource does not treat non-error "kind: assistant_error" field as already patched', () => {
  const input = `
const terminalAssistantError = lastAssistant?.stopReason === "error";
if (terminalAssistantError) {
  const message = (lastAssistant?.errorMessage ?? "").trim() || "LLM request failed";
  return {
    payloads: [{ text: message, isError: true }],
    meta: {
      durationMs: Date.now() - started,
      kind: "assistant_error",
      systemPromptReport: attempt.systemPromptReport
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);
`;

  const out = patchReplySource(input);
  assert.match(
    out,
    /systemPromptReport: attempt\.systemPromptReport,\n\s*error: \{ kind: "assistant_error", message \},/
  );
});

test('patchReplySource does not treat unrelated block-level error object as already patched', () => {
  const input = `
const terminalAssistantError = lastAssistant?.stopReason === "error";
if (terminalAssistantError) {
  const message = (lastAssistant?.errorMessage ?? "").trim() || "LLM request failed";
  const debugState = { error: { kind: "assistant_error", message: "debug-only" } };
  return {
    payloads: [{ text: message, isError: true }],
    meta: {
      durationMs: Date.now() - started,
      systemPromptReport: attempt.systemPromptReport
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);
`;

  const out = patchReplySource(input);
  assert.match(
    out,
    /systemPromptReport: attempt\.systemPromptReport,\n\s*error: \{ kind: "assistant_error", message \},/
  );
});

test('patchReplySource does not treat nested meta.debug.error as already patched', () => {
  const input = `
const terminalAssistantError = lastAssistant?.stopReason === "error";
if (terminalAssistantError) {
  const message = (lastAssistant?.errorMessage ?? "").trim() || "LLM request failed";
  return {
    payloads: [{ text: message, isError: true }],
    meta: {
      durationMs: Date.now() - started,
      debug: { error: { kind: "assistant_error", message } },
      systemPromptReport: attempt.systemPromptReport
    },
  };
}
const authFailure = isAuthAssistantError(lastAssistant);
`;

  const out = patchReplySource(input);
  assert.match(
    out,
    /systemPromptReport: attempt\.systemPromptReport,\n\s*error: \{ kind: "assistant_error", message \},/
  );
});

test("patchRuntimeTargets skips non-runtime reply-prefix files", () => {
  const targetRoot = fs.mkdtempSync(path.join(os.tmpdir(), "runtime-hardening-"));
  try {
    fs.writeFileSync(
      path.join(targetRoot, "gateway-cli-A.js"),
      [
        "const payloads = runResult.payloads ?? [];",
        "const summary = pickSummaryFromPayloads(payloads) ?? pickSummaryFromOutput(firstText);",
        "const outputText = pickLastNonEmptyTextFromPayloads(payloads);",
        "",
      ].join("\n"),
      "utf8"
    );
    fs.writeFileSync(
      path.join(targetRoot, "reply-A.js"),
      [
        "const authFailure = isAuthAssistantError(lastAssistant);",
        "const rateLimitFailure = isRateLimitAssistantError(lastAssistant);",
        "",
      ].join("\n"),
      "utf8"
    );
    fs.writeFileSync(
      path.join(targetRoot, "reply-prefix-A.js"),
      "export const marker = 'reply-prefix';\n",
      "utf8"
    );
    fs.writeFileSync(
      path.join(targetRoot, "subsystem-A.js"),
      [
        'import util from "node:util";',
        "const line = '';",
        'fs.appendFileSync(settings.file, `${line}\\n`, { encoding: "utf8" });',
        "const sanitized = line;",
        "(sink.log ?? console.log)(sanitized);",
        "",
      ].join("\n"),
      "utf8"
    );

    const results = patchRuntimeTargets({ targetRoot, apply: false });
    const replyResults = results.filter((result) => result.kind === "reply");

    assert.equal(replyResults.length, 1);
    assert.match(replyResults[0].filePath, /reply-A\.js$/);
  } finally {
    fs.rmSync(targetRoot, { recursive: true, force: true });
  }
});

test("patchSubsystemSource redacts file and console output", () => {
  const input = `
import util from "node:util";
function buildLogger(settings) {
  logger.attachTransport((logObj) => {
    const line = JSON.stringify({ ...logObj, time: "x" });
    fs.appendFileSync(settings.file, \`\${line}\\n\`, { encoding: "utf8" });
  });
}
function writeConsoleLine(level, line) {
  const sanitized = line;
  (sink.log ?? console.log)(sanitized);
}
`;

  const out = patchSubsystemSource(input);

  assert.match(out, /redactSensitiveText/);
  assert.match(out, /const redactedLine = redactSensitiveText\(line, \{ mode: "tools" \}\);/);
  assert.match(out, /const redacted = redactSensitiveText\(sanitized, \{ mode: "tools" \}\);/);
  assert.match(out, /\(sink\.log \?\? console\.log\)\(redacted\);/);
});

test("patchSubsystemSource supports console-only chunks without file append anchors", () => {
  const input = `
import util from "node:util";
function writeConsoleLine(level, line) {
  const sanitized = line;
  (sink.log ?? console.log)(sanitized);
}
`;

  const out = patchSubsystemSource(input);

  assert.match(out, /redactSensitiveText/);
  assert.match(out, /const redacted = redactSensitiveText\(sanitized, \{ mode: "tools" \}\);/);
  assert.match(out, /\(sink\.log \?\? console\.log\)\(redacted\);/);
});

test("patchSubsystemSource preserves shebang as first line", () => {
  const input = `#!/usr/bin/env node
function writeConsoleLine(level, line) {
  const sanitized = line;
  (sink.log ?? console.log)(sanitized);
}
`;

  const out = patchSubsystemSource(input);

  assert.ok(out.startsWith("#!/usr/bin/env node\n"));
  assert.match(out, /import \{ n as redactSensitiveText \} from "\.\/redact-[^"]+\.js";/);
  assert.ok(
    out.indexOf('import { n as redactSensitiveText }') > out.indexOf("#!/usr/bin/env node")
  );
});

test("patchSubsystemSource is idempotent", () => {
  const input = `
import util from "node:util";
function buildLogger(settings) {
  logger.attachTransport((logObj) => {
    const line = JSON.stringify({ ...logObj, time: "x" });
    fs.appendFileSync(settings.file, \`\${line}\\n\`, { encoding: "utf8" });
  });
}
function writeConsoleLine(level, line) {
  const sanitized = line;
  (sink.log ?? console.log)(sanitized);
}
`;

  const once = patchSubsystemSource(input);
  const twice = patchSubsystemSource(once);

  assert.equal(twice, once);
});

test("patchSubsystemSource repairs partial file patch where append still writes raw line", () => {
  const input = `
import util from "node:util";
import { n as redactSensitiveText } from "./redact-CVRUv382.js";
function buildLogger(settings) {
  logger.attachTransport((logObj) => {
    const line = JSON.stringify({ ...logObj, time: "x" });
    const redactedLine = redactSensitiveText(line, { mode: "tools" });
    fs.appendFileSync(settings.file, \`\${line}\\n\`, { encoding: "utf8" });
  });
}
function writeConsoleLine(level, line) {
  const sanitized = line;
  const redacted = redactSensitiveText(sanitized, { mode: "tools" });
  (sink.log ?? console.log)(redacted);
}
`;

  const out = patchSubsystemSource(input);
  assert.match(out, /fs\.appendFileSync\(settings\.file, `\$\{redactedLine\}\\n`, \{ encoding: "utf8" \}\);/);
  assert.doesNotMatch(out, /`\$\{line\}\\n`/);
});

test("patchSubsystemSource redacts compact-spacing sink calls", () => {
  const input = `
import util from "node:util";
function buildLogger(settings) {
  logger.attachTransport((logObj) => {
    const line = JSON.stringify({ ...logObj, time: "x" });
    fs.appendFileSync(settings.file, \`\${line}\\n\`, { encoding: "utf8" });
  });
}
function writeConsoleLine(level, line) {
  const sanitized = line;
  if (level === "error") (sink.error??console.error)(sanitized);
  else if (level === "warn") (sink.warn??console.warn)(sanitized);
  else (sink.log??console.log)(sanitized);
}
`;

  const out = patchSubsystemSource(input);

  assert.doesNotMatch(out, /\)\(\s*sanitized\s*\)/);
  assert.match(out, /\(sink\.error \?\? console\.error\)\(redacted\);/);
  assert.match(out, /\(sink\.warn \?\? console\.warn\)\(redacted\);/);
  assert.match(out, /\(sink\.log \?\? console\.log\)\(redacted\);/);
});

test("patchSubsystemSource redacts sink calls when there is spacing between call groups", () => {
  const input = `
import util from "node:util";
function buildLogger(settings) {
  logger.attachTransport((logObj) => {
    const line = JSON.stringify({ ...logObj, time: "x" });
    fs.appendFileSync(settings.file, \`\${line}\\n\`, { encoding: "utf8" });
  });
}
function writeConsoleLine(level, line) {
  const sanitized = line;
  if (level === "error") (sink.error ?? console.error) (sanitized);
  else if (level === "warn") (sink.warn ?? console.warn) (sanitized);
  else (sink.log ?? console.log) (sanitized);
}
`;

  const out = patchSubsystemSource(input);
  assert.doesNotMatch(out, /\)\s*\(\s*sanitized\s*\)/);
  assert.match(out, /\(sink\.error \?\? console\.error\)\(redacted\);/);
  assert.match(out, /\(sink\.warn \?\? console\.warn\)\(redacted\);/);
  assert.match(out, /\(sink\.log \?\? console\.log\)\(redacted\);/);
});
