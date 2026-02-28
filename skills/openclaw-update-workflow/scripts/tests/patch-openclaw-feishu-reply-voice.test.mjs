import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { access, mkdtemp, readFile, writeFile } from "node:fs/promises";

import {
  applyPatchToTargetRoot,
  patchFeishuBotReplyVoiceSource,
} from "../patch-openclaw-feishu-reply-voice.mjs";

const BOT_SOURCE_FIXTURE = `
import { downloadMessageResourceFeishu } from "./media.js";
import { getMessageFeishu, sendMessageFeishu } from "./send.js";
import type { FeishuMessageContext, FeishuMediaInfo, ResolvedFeishuAccount } from "./types.js";
import type { DynamicAgentCreationConfig } from "./types.js";

const PERMISSION_ERROR_COOLDOWN_MS = 5 * 60 * 1000;
const FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS = 30;
const FEISHU_SLOW_REPLY_NOTICE_MS = 15_000;
const FEISHU_SLOW_LOG_THRESHOLD_MS = 20_000;
const VOICE_MODE_NO_REPLY_FALLBACK_TEXT = "x";
const TEXT_MODE_NO_REPLY_FALLBACK_TEXT = "y";
const HARD_TIMEOUT_FALLBACK_TEXT = "z";

function checkBotMentioned(event: FeishuMessageEvent, botOpenId?: string): boolean {
  return false;
}

export async function handleFeishuMessage(params: {
  cfg: ClawdbotConfig;
  event: FeishuMessageEvent;
  botOpenId?: string;
  runtime?: RuntimeEnv;
}): Promise<void> {
  let ctx = parseFeishuMessageEvent(event, botOpenId);
  const isGroup = ctx.chatType === "group";

  const senderResult = await resolveFeishuSenderName({
    account,
    senderOpenId: ctx.senderOpenId,
    log,
  });
  if (senderResult.name) ctx = { ...ctx, senderName: senderResult.name };

  const voiceModeEnabled = false;
  const slowReplyNotified = false;
  const feishuFrom = \`feishu:\${ctx.senderOpenId}\`;
  const feishuTo = isGroup ? \`chat:\${ctx.chatId}\` : \`user:\${ctx.senderOpenId}\`;
  const queuedFinal = false;
  const counts = { final: 0 };
  let doneAtMs = Date.now();
  const eventId = "event-id";
  const preDispatchMs = 1;
  const dispatchMs = 2;
  const totalMs = 3;
  let dispatchSettled = false;
  let slowReplyNotified = false;
  const route = { agentId: "agent-main" };
  const runtime = {};
  const ctxPayload = {};
  const dispatcher = {};
  const replyOptions = {};
  const slowReplyTimer = setTimeout(() => {
    if (dispatchSettled) {
      return;
    }
    slowReplyNotified = true;
    void sendMessageFeishu({
      cfg,
      to: feishuTo,
      text: "slow-notice",
      replyToMessageId: ctx.messageId,
      accountId: account.accountId,
    }).catch(() => {});
  }, FEISHU_SLOW_REPLY_NOTICE_MS);

  const { dispatcher: realDispatcher, replyOptions: realReplyOptions, markDispatchIdle } =
    createFeishuReplyDispatcher({
      cfg,
      agentId: route.agentId,
      runtime: runtime as RuntimeEnv,
      chatId: ctx.chatId,
      replyToMessageId: ctx.messageId,
      mentionTargets: ctx.mentionTargets,
      accountId: account.accountId,
    });
  console.log(realDispatcher, realReplyOptions, markDispatchIdle);

  try {
    await core.channel.reply.dispatchReplyFromConfig({
      ctx: ctxPayload,
      cfg,
      dispatcher,
      replyOptions: replyOptions,
      thinking: "high",
    });
    log(
      \`feishu[\${account.accountId}]: dispatch complete (queuedFinal=\${queuedFinal}, replies=\${counts.final})\`,
    );
    if (!queuedFinal && counts.final === 0) {
      await sendMessageFeishu({
        cfg,
        to: feishuTo,
        text: "legacy",
        replyToMessageId: ctx.messageId,
        accountId: account.accountId,
      });
    }
    doneAtMs = Date.now();
  } finally {
    dispatchSettled = true;
    clearTimeout(slowReplyTimer);
  }
  log(
    \`feishu[\${account.accountId}]: dispatch metrics messageId=\${ctx.messageId} eventId=\${eventId} pre_dispatch_ms=\${preDispatchMs} dispatch_ms=\${dispatchMs} total_ms=\${totalMs} queuedFinal=\${queuedFinal} replies=\${counts.final} voice_mode=\${voiceModeEnabled ? "on" : "off"}\`,
  );
  console.log(slowReplyNotified);
  if (dispatchMs >= FEISHU_SLOW_LOG_THRESHOLD_MS) {
    log("slow");
  }
  console.log(feishuFrom, feishuTo, doneAtMs);
}
`;

async function createTargetRoot(source = BOT_SOURCE_FIXTURE) {
  const targetRoot = await mkdtemp(path.join(tmpdir(), "patch-feishu-reply-voice-"));
  const botPath = path.join(targetRoot, "bot.ts");
  await writeFile(botPath, source, "utf8");
  return { targetRoot, botPath, source };
}

async function createNoFinalFallbackRuntimeRunner() {
  const patchScriptPath = fileURLToPath(new URL("../patch-openclaw-feishu-reply-voice.mjs", import.meta.url));
  const patchScriptSource = await readFile(patchScriptPath, "utf8");
  const blockMatch = patchScriptSource.match(
    /const NO_FINAL_FALLBACK_BLOCK = `([\s\S]*?)`;\n\nfunction insertAfterAnchor/,
  );
  assert.ok(blockMatch, "NO_FINAL_FALLBACK_BLOCK template not found");

  let runtimeBlock = blockMatch[1];
  runtimeBlock = runtimeBlock.replace(
    /const dispatcherState = dispatcher as \{[\s\S]*?\n    \};/,
    "const dispatcherState = dispatcher;",
  );
  runtimeBlock = runtimeBlock.replace(/\\`/g, "`").replace(/\\\$\{/g, "${");

  const createRunner = new Function(`
    return async function runNoFinalFallbackScenario(input = {}) {
      const {
        voiceModeEnabled = true,
        queuedFinal = true,
        finalReplies = 1,
        initialOutboundDeliveryState = false,
        initialOutboundMediaState = false,
        voiceCandidate = "final candidate",
        supplementalVoiceFails = true,
        slowReplyNotified = false,
        replySendFails = false,
      } = input;

      const counts = { final: finalReplies };
      const dispatcher = {
        markComplete() {},
        async waitForIdle() {},
        __openclawFeishuNoFinalTextCandidate: () => voiceCandidate,
        __openclawFeishuHadOutboundDelivery:
          initialOutboundDeliveryState === null ? undefined : () => initialOutboundDeliveryState,
        __openclawFeishuHadMediaDelivery:
          initialOutboundMediaState === null ? undefined : () => initialOutboundMediaState,
      };
      const account = { accountId: "default" };
      const cfg = {};
      const feishuTo = "user:test";
      const ctx = { messageId: "msg-1" };
      const logCalls = [];
      const errorCalls = [];
      const messageCalls = [];
      const mediaCalls = [];
      const log = (msg) => logCalls.push(String(msg));
      const error = (msg) => errorCalls.push(String(msg));
      const replyVoiceTtsBridge = {
        async generate(text) {
          if (supplementalVoiceFails) {
            throw new Error("supplemental voice failed");
          }
          return { mediaUrl: "file:///tmp/fallback.opus", text };
        },
      };
      async function sendMediaFeishu(payload) {
        mediaCalls.push(payload);
      }
      async function sendMessageFeishu(payload) {
        messageCalls.push(payload);
        if (replySendFails && payload.replyToMessageId) {
          throw new Error("reply send failed");
        }
      }
      const VOICE_MODE_NO_REPLY_FALLBACK_TEXT = "VOICE_FALLBACK";
      const TEXT_MODE_NO_REPLY_FALLBACK_TEXT = "TEXT_FALLBACK";
      const HARD_TIMEOUT_FALLBACK_TEXT = "HARD_TIMEOUT";
      ${runtimeBlock}
      return { logCalls, errorCalls, messageCalls, mediaCalls };
    };
  `);

  return createRunner();
}

test("patchFeishuBotReplyVoiceSource adds reply voice imports and fastpath", () => {
  const out = patchFeishuBotReplyVoiceSource(BOT_SOURCE_FIXTURE);

  assert.match(
    out,
    /import \{ downloadMessageResourceFeishu, sendMediaFeishu \} from "\.\/media\.js";/
  );
  assert.match(
    out,
    /import \{ (?:normalizeReplyVoiceCommand, )?resolveReplyVoiceCommand, splitReplyVoiceText \} from "\.\/reply-voice-command\.js";/
  );
  assert.match(out, /import \{ createReplyVoiceTtsBridge \} from "\.\/reply-voice-tts\.js";/);
  assert.match(out, /const replyVoiceTtsBridge = createReplyVoiceTtsBridge\(\);/);
  assert.match(
    out,
    /function parseReplyTargetContentForVoice\(content: string, messageType: string\): string \{/
  );
  assert.match(out, /const replyVoiceCommandCandidate = resolveReplyVoiceCommand\(ctx\.content\);/);
  assert.match(out, /if \(replyVoiceCommandCandidate\) \{/);
  assert.match(out, /const chunks = splitReplyVoiceText\(replyText, 500\);/);
  assert.match(out, /return lines\.join\("\\n"\)\.trim\(\);/);
  assert.match(out, /reply voice synthesis failed after \$\{sentChunks\} chunk\(s\):/);
  assert.match(out, /const errText = String\(err\);/);
  assert.match(out, /reply voice script not found/);
  assert.match(out, /无法找到语音脚本，请检查 xiaoke-voice-mode\/scripts\/generate_tts_media\.sh。/);
  assert.match(out, /const FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS = 90;/);
  assert.match(out, /const FEISHU_SLOW_REPLY_NOTICE_ENABLED = false;/);
  assert.match(out, /const slowReplyTimer = FEISHU_SLOW_REPLY_NOTICE_ENABLED/);
  assert.match(
    out,
    /createFeishuReplyDispatcher\(\{[\s\S]*?forceVoiceModeTts: voiceModeEnabled,[\s\S]*?\}\);/
  );
  assert.match(out, /timeoutOverrideSeconds: FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS,/);
  assert.match(out, /replyOptions: \{ \.\.\.replyOptions, disableBlockStreaming: true \},/);
  assert.match(out, /forceVoiceModeTts: voiceModeEnabled,/);
  assert.match(out, /thinking: voiceModeEnabled \? "off" : undefined,/);
  assert.match(out, /disableBlockStreaming: true,/);
  assert.match(out, /const noFinalFallbackState = !queuedFinal && finalCount === 0;/);
  assert.match(out, /__openclawFeishuHadMediaDelivery\?: \(\) => boolean;/);
  assert.match(out, /const hasOutboundMediaSignal = typeof outboundMediaState === "boolean";/);
  assert.match(out, /delivered supplemental voice media from final text candidate/);
  assert.match(out, /failed to deliver supplemental voice media from final text candidate/);
  assert.match(out, /supplemental voice delivery failed in voice mode; forcing fallback text/);
  assert.match(out, /const queuedButNoDeliveryFallbackState =/);
  assert.match(out, /handled voice mode command locally \(/);
  assert.match(out, /sent no-final fallback text via direct message/);
});

test("patchFeishuBotReplyVoiceSource is idempotent", () => {
  const once = patchFeishuBotReplyVoiceSource(BOT_SOURCE_FIXTURE);
  const twice = patchFeishuBotReplyVoiceSource(once);
  assert.equal(twice, once);
});

test("runtime: voice queued-no-delivery falls back to text after supplemental voice failure", async () => {
  const runScenario = await createNoFinalFallbackRuntimeRunner();
  const result = await runScenario({
    voiceModeEnabled: true,
    queuedFinal: true,
    finalReplies: 1,
    initialOutboundDeliveryState: false,
    initialOutboundMediaState: false,
    voiceCandidate: "candidate from final",
    supplementalVoiceFails: true,
  });

  assert.equal(result.mediaCalls.length, 0);
  assert.equal(result.messageCalls.length, 1);
  assert.equal(result.messageCalls[0]?.text, "candidate from final");
  assert.match(
    result.errorCalls.join("\n"),
    /failed to deliver supplemental voice media from final text candidate/,
  );
});

test("patchFeishuBotReplyVoiceSource upgrades old fastpath without missing-script hint", () => {
  const modern = patchFeishuBotReplyVoiceSource(BOT_SOURCE_FIXTURE);
  const legacy = modern.replace(
    "无法找到语音脚本，请检查 xiaoke-voice-mode/scripts/generate_tts_media.sh。",
    "语音生成失败，请稍后重试。",
  );
  assert.notEqual(legacy, modern);

  const upgraded = patchFeishuBotReplyVoiceSource(legacy);
  assert.equal(upgraded, modern);
});

test("patchFeishuBotReplyVoiceSource repairs broken parse join string literal", () => {
  const modern = patchFeishuBotReplyVoiceSource(BOT_SOURCE_FIXTURE);
  const broken = modern.replace('return lines.join("\\n").trim();', 'return lines.join("\n").trim();');
  assert.notEqual(broken, modern);

  const repaired = patchFeishuBotReplyVoiceSource(broken);
  assert.equal(repaired, modern);
});

test("patchFeishuBotReplyVoiceSource tolerates type import anchor drift", () => {
  const drifted = BOT_SOURCE_FIXTURE.replace(
    'import type { FeishuMessageContext, FeishuMediaInfo, ResolvedFeishuAccount } from "./types.js";',
    'import type { FeishuMessageContext } from "./types.js";',
  );

  const patched = patchFeishuBotReplyVoiceSource(drifted);
  assert.match(
    patched,
    /import \{ (?:normalizeReplyVoiceCommand, )?resolveReplyVoiceCommand, splitReplyVoiceText \} from "\.\/reply-voice-command\.js";/,
  );
  assert.match(patched, /import \{ createReplyVoiceTtsBridge \} from "\.\/reply-voice-tts\.js";/);
});

test("patchFeishuBotReplyVoiceSource tolerates dispatch options anchor drift", () => {
  const modern = patchFeishuBotReplyVoiceSource(BOT_SOURCE_FIXTURE);
  const drifted = modern.replace(
    /dispatchReplyFromConfig\(\{[\s\S]*?\n\s*\}\);/,
    `dispatchReplyFromConfig({
          ctx: ctxPayload,
          cfg,
          dispatcher,
          replyOptions: replyOptions,
          disableBlockStreaming: false,
          thinking: "manual",
        });`,
  );
  assert.notEqual(drifted, modern);

  const repaired = patchFeishuBotReplyVoiceSource(drifted);
  const createCallMatches =
    repaired.match(/createFeishuReplyDispatcher\(\{[\s\S]*?forceVoiceModeTts: voiceModeEnabled,[\s\S]*?\}\);/g) ??
    [];
  assert.equal(createCallMatches.length, 1);
  assert.match(repaired, /timeoutOverrideSeconds: FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS,/);
  assert.match(repaired, /replyOptions: \{ \.\.\.replyOptions, disableBlockStreaming: true \},/);
  assert.match(repaired, /forceVoiceModeTts: voiceModeEnabled,/);
  assert.match(repaired, /thinking: voiceModeEnabled \? "off" : undefined,/);
  assert.match(repaired, /disableBlockStreaming: true,/);
  assert.equal((repaired.match(/timeoutOverrideSeconds: FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS,/g) ?? []).length, 1);
  assert.equal((repaired.match(/forceVoiceModeTts: voiceModeEnabled,/g) ?? []).length, 2);
  assert.equal((repaired.match(/disableBlockStreaming: true,/g) ?? []).length, 1);
});

test("applyPatchToTargetRoot writes bot.ts and reply-voice templates", async () => {
  const { targetRoot, botPath, source } = await createTargetRoot();
  const replyVoiceCommandPath = path.join(targetRoot, "reply-voice-command.ts");
  const replyVoiceTtsPath = path.join(targetRoot, "reply-voice-tts.ts");

  const result = await applyPatchToTargetRoot({ targetRoot, apply: true });

  assert.equal(result.apply, true);
  assert.equal(result.changed, true);
  assert.equal(result.files.botChanged, true);
  assert.equal(result.files.replyVoiceCommandChanged, true);
  assert.equal(result.files.replyVoiceTtsChanged, true);
  assert.equal(await readFile(botPath, "utf8"), patchFeishuBotReplyVoiceSource(source));
  assert.match(await readFile(botPath, "utf8"), /无法找到语音脚本，请检查 xiaoke-voice-mode\/scripts\/generate_tts_media\.sh。/);
  assert.match(await readFile(replyVoiceCommandPath, "utf8"), /export function splitReplyVoiceText/);
  assert.match(await readFile(replyVoiceTtsPath, "utf8"), /export function createReplyVoiceTtsBridge/);
  assert.match(await readFile(replyVoiceTtsPath, "utf8"), /MEDIA:/);
  assert.match(await readFile(replyVoiceTtsPath, "utf8"), /reply voice script not found; checked:/);
  assert.match(await readFile(replyVoiceTtsPath, "utf8"), /"--voice-id", "wakaba_mutsumi"/);
  assert.equal(await readFile(`${botPath}.bak`, "utf8"), source);
});

test("applyPatchToTargetRoot is idempotent on second apply", async () => {
  const { targetRoot, botPath } = await createTargetRoot();
  await applyPatchToTargetRoot({ targetRoot, apply: true });
  await writeFile(`${botPath}.bak`, "keep-existing-bot-backup", "utf8");

  const result = await applyPatchToTargetRoot({ targetRoot, apply: true });

  assert.deepEqual(result.files, {
    botChanged: false,
    replyVoiceCommandChanged: false,
    replyVoiceTtsChanged: false,
  });
  assert.equal(result.changed, false);
  assert.equal(await readFile(`${botPath}.bak`, "utf8"), "keep-existing-bot-backup");
});

test("applyPatchToTargetRoot dry-run does not write files", async () => {
  const { targetRoot, botPath, source } = await createTargetRoot();
  const replyVoiceCommandPath = path.join(targetRoot, "reply-voice-command.ts");
  const replyVoiceTtsPath = path.join(targetRoot, "reply-voice-tts.ts");

  const result = await applyPatchToTargetRoot({ targetRoot, apply: false });

  assert.equal(result.apply, false);
  assert.equal(result.changed, true);
  assert.equal(await readFile(botPath, "utf8"), source);
  await assert.rejects(access(`${botPath}.bak`), { code: "ENOENT" });
  await assert.rejects(access(replyVoiceCommandPath), { code: "ENOENT" });
  await assert.rejects(access(replyVoiceTtsPath), { code: "ENOENT" });
});

test("CLI defaults to dry-run and supports --apply with --target-root", async () => {
  const scriptPath = fileURLToPath(new URL("../patch-openclaw-feishu-reply-voice.mjs", import.meta.url));
  const { targetRoot, botPath, source } = await createTargetRoot();

  const dryRun = spawnSync(process.execPath, [scriptPath, "--target-root", targetRoot], {
    encoding: "utf8",
  });
  assert.equal(dryRun.status, 0, dryRun.stderr);
  const dryRunJson = JSON.parse(dryRun.stdout.trim());
  assert.equal(dryRunJson.apply, false);
  assert.equal(dryRunJson.changed, true);
  assert.equal(await readFile(botPath, "utf8"), source);

  const applyRun = spawnSync(
    process.execPath,
    [scriptPath, "--apply", "--target-root", targetRoot],
    { encoding: "utf8" },
  );
  assert.equal(applyRun.status, 0, applyRun.stderr);
  const applyJson = JSON.parse(applyRun.stdout.trim());
  assert.equal(applyJson.apply, true);
  assert.equal(applyJson.changed, true);
  assert.equal(await readFile(botPath, "utf8"), patchFeishuBotReplyVoiceSource(source));
});
