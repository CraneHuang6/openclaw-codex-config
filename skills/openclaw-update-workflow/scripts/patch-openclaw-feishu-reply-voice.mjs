import path from "node:path";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const DEFAULT_TARGET_ROOT = "/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src";

const MEDIA_IMPORT_PATTERN =
  /import\s+\{\s*downloadMessageResourceFeishu\s*(?:,\s*sendMediaFeishu\s*)?\}\s+from\s+"\.\/media\.js";/m;
const MEDIA_IMPORT_REPLACEMENT =
  'import { downloadMessageResourceFeishu, sendMediaFeishu } from "./media.js";';
const TYPE_IMPORT_ANCHORS = [
  'import type { DynamicAgentCreationConfig } from "./types.js";',
  'import type { FeishuMessageContext, FeishuMediaInfo, ResolvedFeishuAccount } from "./types.js";',
];
const TYPE_IMPORT_FALLBACK_PATTERN = /import\s+type\s+\{[^}]+\}\s+from\s+"\.\/types\.js";/g;
const REPLY_VOICE_COMMAND_IMPORT =
  'import { normalizeReplyVoiceCommand, resolveReplyVoiceCommand, splitReplyVoiceText } from "./reply-voice-command.js";';
const REPLY_VOICE_TTS_IMPORT =
  'import { createReplyVoiceTtsBridge, createVoiceModeStateBridge } from "./reply-voice-tts.js";';
const REPLY_VOICE_IMPORT_MARKER = REPLY_VOICE_COMMAND_IMPORT;
const REPLY_VOICE_COMMAND_IMPORT_PATTERN =
  /import\s+\{[^}]*\}\s+from\s+"\.\/reply-voice-command\.js";\n?/g;
const REPLY_VOICE_TTS_IMPORT_PATTERN =
  /import\s+\{[^}]*createReplyVoiceTtsBridge[^}]*\}\s+from\s+"\.\/reply-voice-tts\.js";\n?/g;
const REPLY_VOICE_TTS_BRIDGE_MARKER = "const replyVoiceTtsBridge = createReplyVoiceTtsBridge();";
const VOICE_MODE_STATE_BRIDGE_MARKER = "const voiceModeStateBridge = createVoiceModeStateBridge();";
const VOICE_MODE_STATE_CACHE_MARKER = 'const voiceModeStateCache = new Map<string, "on" | "off">();';
const VOICE_MODE_NO_REPLY_FALLBACK_TEXT_MARKER = "const VOICE_MODE_NO_REPLY_FALLBACK_TEXT =";
const VOICE_MODE_NO_REPLY_FALLBACK_TEXT_BLOCK =
  'const VOICE_MODE_NO_REPLY_FALLBACK_TEXT =\n  "这次没有生成语音回复（可能模型繁忙或执行超时），请稍后重试。";';
const HARD_TIMEOUT_FALLBACK_TEXT_MARKER = "const HARD_TIMEOUT_FALLBACK_TEXT =";
const TEXT_MODE_NO_REPLY_FALLBACK_TEXT_MARKER = "const TEXT_MODE_NO_REPLY_FALLBACK_TEXT =";
const REPLY_VOICE_FALLBACK_TEXT_DEFAULTS_BLOCK =
  'const HARD_TIMEOUT_FALLBACK_TEXT =\n  "这次响应超时了，请稍后重试。";\nconst TEXT_MODE_NO_REPLY_FALLBACK_TEXT =\n  "这次没有生成文本回复，请稍后重试。";';
const FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_PATTERN =
  /const FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS = [^;]+;/;
const FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_REPLACEMENT =
  "const FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS = 60_000;";
const FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MARKER =
  "const FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS =";
const FEISHU_REPLY_TIMEOUT_OVERRIDE_PATTERN =
  /const FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS = \d+;/;
const FEISHU_REPLY_TIMEOUT_OVERRIDE_REPLACEMENT =
  "const FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS = 90;";
const REPLY_VOICE_THINKING_OFF_MARKER = 'thinking: voiceModeEnabled ? "off" : undefined,';
const REPLY_VOICE_FORCE_TTS_MARKER = "forceVoiceModeTts: voiceModeEnabled,";
const REPLY_VOICE_TIMEOUT_OVERRIDE_LINE_MARKER =
  "timeoutOverrideSeconds: FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS,";
const REPLY_VOICE_DISABLE_BLOCK_STREAMING_EXPRESSION = "voiceModeEnabled ? true : undefined";
const REPLY_VOICE_DISABLE_BLOCK_STREAMING_MARKER = `disableBlockStreaming: ${REPLY_VOICE_DISABLE_BLOCK_STREAMING_EXPRESSION},`;
const REPLY_VOICE_CREATE_DISPATCHER_CALL_PATTERN = /createFeishuReplyDispatcher\s*\(\s*\{/g;
const REPLY_VOICE_DISPATCH_CALL_PATTERN = /dispatchReplyFromConfig\s*\(\s*\{/g;
const FEISHU_SLOW_REPLY_NOTICE_MS_REPLACEMENT = "const FEISHU_SLOW_REPLY_NOTICE_MS = 45_000;";
const FEISHU_SLOW_REPLY_NOTICE_MS_PATTERN = /const FEISHU_SLOW_REPLY_NOTICE_MS = [^;]+;/;
const FEISHU_SLOW_REPLY_NOTICE_ENABLED_PATTERN =
  /const FEISHU_SLOW_REPLY_NOTICE_ENABLED = (?:true|false);/;
const FEISHU_SLOW_REPLY_NOTICE_ENABLED_REPLACEMENT =
  "const FEISHU_SLOW_REPLY_NOTICE_ENABLED = false;";
const FEISHU_SLOW_REPLY_TIMER_COMPAT_MARKER =
  "// const slowReplyTimer = FEISHU_SLOW_REPLY_NOTICE_ENABLED (compat marker: dispatcher-managed)";
const PERMISSION_COOLDOWN_ANCHOR = "const PERMISSION_ERROR_COOLDOWN_MS = 5 * 60 * 1000;";
const PARSE_REPLY_VOICE_MARKER =
  "function parseReplyTargetContentForVoice(content: string, messageType: string): string {";
const VOICE_MODE_TOGGLE_HELPER_MARKER =
  'function resolveVoiceModeToggleCommand(text: string): "on" | "off" | null {';
const PARSE_REPLY_VOICE_INSERT_ANCHOR =
  "function checkBotMentioned(event: FeishuMessageEvent, botOpenId?: string";
const REPLY_VOICE_CANDIDATE_MARKER = "const replyVoiceCommandCandidate = resolveReplyVoiceCommand(ctx.content);";
const REPLY_VOICE_CANDIDATE_ANCHOR = 'const isGroup = ctx.chatType === "group";';
const REPLY_VOICE_RUNTIME_STATE_MARKER =
  'const voiceModeSessionKey = `feishu:${account.accountId}:${isGroup ? "group" : "direct"}:${isGroup ? ctx.chatId : ctx.senderOpenId}`;';
const REPLY_VOICE_RUNTIME_STATE_LEGACY_MARKER = "const voiceModeEnabled = false;";
const REPLY_VOICE_RUNTIME_STATE_LEGACY_BLOCK = `  const voiceModeEnabled = false;
  const slowReplyNotified = false;`;
const REPLY_VOICE_RUNTIME_STATE_BLOCK = `  const voiceModeSessionKey = \`feishu:\${account.accountId}:\${isGroup ? "group" : "direct"}:\${isGroup ? ctx.chatId : ctx.senderOpenId}\`;
  const voiceModeCommandCandidate = resolveVoiceModeToggleCommand(ctx.content);
  const cachedVoiceModeState = voiceModeStateCache.get(voiceModeSessionKey);
  const voiceModeState = await voiceModeStateBridge.get(voiceModeSessionKey, cachedVoiceModeState);
  voiceModeStateCache.set(voiceModeSessionKey, voiceModeState);
  const voiceModeEnabled = voiceModeState === "on";
  const slowReplyNotified = false;`;
const REPLY_VOICE_RUNTIME_STATE_BLOCK_END_MARKER = "  const slowReplyNotified = false;";
const REPLY_VOICE_MODE_TOGGLE_MARKER = "handled voice mode command locally (";
const REPLY_VOICE_MODE_ENABLED_LOG_MARKER = "voice mode enabled for session";
const REPLY_VOICE_MODE_TOGGLE_STATE_SET_MARKER =
  "const nextVoiceModeState = await voiceModeStateBridge.set(voiceModeSessionKey, voiceModeCommandCandidate);";
const REPLY_VOICE_MODE_TOGGLE_BLOCK_START_MARKER = "    if (voiceModeCommandCandidate) {\n";
const REPLY_VOICE_MODE_TOGGLE_BLOCK_END_MARKER = "    if (replyVoiceCommandCandidate) {\n";
const REPLY_VOICE_FASTPATH_MARKER = "reply voice synthesis failed after ${sentChunks} chunk(s):";
const REPLY_VOICE_FASTPATH_ANCHOR =
  'const feishuTo = isGroup ? `chat:${ctx.chatId}` : `user:${ctx.senderOpenId}`;';
const REPLY_VOICE_MENTION_GUARD_PATTERN =
  /if\s*\(requireMention\s*&&\s*!ctx\.mentionedBot\)/g;
const REPLY_VOICE_MISSING_SCRIPT_HINT_MARKER =
  "无法找到语音脚本，请检查 xiaoke-voice-mode/scripts/generate_tts_media.sh。";
const REPLY_VOICE_FASTPATH_START_MARKER = "    if (replyVoiceCommandCandidate) {\n";
const REPLY_VOICE_FASTPATH_END_MARKER = "      return;\n    }\n";
const NO_FINAL_FALLBACK_GENERIC_START_MARKER = "    if (!queuedFinal && counts.final === 0) {";
const NO_FINAL_FALLBACK_DISPATCH_DRAIN_START_MARKER =
  "    try {\n      dispatcher.markComplete();\n      await dispatcher.waitForIdle();\n    } catch (dispatchDrainErr) {";
const NO_FINAL_FALLBACK_BLOCK_AWARE_START_MARKER = "    const finalCount = counts.final ?? 0;";
const NO_FINAL_FALLBACK_VOICE_ONLY_START_MARKER =
  "    if (voiceModeEnabled && !queuedFinal && counts.final === 0) {";
const NO_FINAL_FALLBACK_BLOCK_END_MARKERS = [
  "    doneAtMs = Date.now();",
  "  } catch (err) {",
];
const NO_FINAL_FALLBACK_INSERT_PATTERN =
  /(log\(\n\s*`feishu\[\$\{account\.accountId\}\]: dispatch complete \(queuedFinal=\$\{queuedFinal\}, replies=\$\{counts\.final\}\)`\s*,\n\s*\);\n)/m;
const NO_FINAL_FALLBACK_DIRECT_LOG_MARKER =
  "sent no-final fallback text via direct message";
const NO_FINAL_FALLBACK_COMPLETE_SIGNATURE_MARKERS = [
  NO_FINAL_FALLBACK_BLOCK_AWARE_START_MARKER,
  "const voiceNoDeliveryAfterSupplementFailureFallbackState =",
  "const voiceQueuedButNoDeliveryDelayFallbackState =",
  NO_FINAL_FALLBACK_DIRECT_LOG_MARKER,
  "queued final reply without confirmed outbound delivery in voice mode; scheduling delayed fallback text in ${FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS}ms",
  "delayed no-delivery fallback timer fired after ${FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS}ms; forcing fallback text",
  "supplemental voice delivery failed in voice mode; forcing fallback text",
];
const SLOW_REPLY_TIMER_LEGACY_START = "const slowReplyTimer = setTimeout(() => {";
const SLOW_REPLY_TIMER_GUARDED_START =
  "const slowReplyTimer = FEISHU_SLOW_REPLY_NOTICE_ENABLED\n      ? setTimeout(() => {";
const SLOW_REPLY_TIMER_LEGACY_END = "    }, FEISHU_SLOW_REPLY_NOTICE_MS);";
const SLOW_REPLY_TIMER_GUARDED_END = "    }, FEISHU_SLOW_REPLY_NOTICE_MS)\n      : null;";
const SLOW_REPLY_TIMER_LEGACY_CLEAR = "      clearTimeout(slowReplyTimer);";
const SLOW_REPLY_TIMER_GUARDED_CLEAR =
  "      if (slowReplyTimer) {\n        clearTimeout(slowReplyTimer);\n      }";
const BROKEN_PARSE_JOIN_LITERAL_PATTERN = /return lines\.join\("\r?\n"\)\.trim\(\);/g;
const FIXED_PARSE_JOIN_LITERAL = 'return lines.join("\\n").trim();';
const REPLY_DISPATCHER_STREAMING_COUNTER_MARKER = "let streamingUpdateCount = 0;";
const REPLY_DISPATCHER_STREAMING_COUNTER_RESET_MARKER = "streamingUpdateCount = 0;";
const REPLY_DISPATCHER_ASSISTANT_START_MARKER =
  "streaming warmup: onAssistantMessageStart (renderMode=card)";
const REPLY_DISPATCHER_PARTIAL_WARMUP_MARKER = "streaming warmup: first partial";
const REPLY_DISPATCHER_PARTIAL_UPDATE_MARKER = "streaming partial update #";

const REPLY_VOICE_COMMAND_TEMPLATE = `const COMMAND_CORE = "生成语音";

export function normalizeReplyVoiceCommand(text: string): string {
  return text
    .replace(/[\\s\\u3000。！？!?，,、；;：:"“”‘’'\`~～()（）【】\\[\\]{}<>《》]/g, "")
    .trim();
}

export function resolveReplyVoiceCommand(text: string): boolean {
  const normalized = normalizeReplyVoiceCommand(text);
  return (
    normalized === COMMAND_CORE ||
    normalized === \`请\${COMMAND_CORE}\` ||
    normalized === \`帮我\${COMMAND_CORE}\`
  );
}

function findSplitIndex(windowText: string): number {
  const markers = ["。", "！", "？", ".", "!", "?", "\\n"];
  let splitAt = -1;
  for (const marker of markers) {
    const markerPos = windowText.lastIndexOf(marker);
    if (markerPos > splitAt) {
      splitAt = markerPos;
    }
  }
  return splitAt;
}

export function splitReplyVoiceText(text: string, maxLen = 500): string[] {
  const cleaned = text.replace(/\\s+/g, " ").trim();
  if (!cleaned) {
    return [];
  }
  if (cleaned.length <= maxLen) {
    return [cleaned];
  }

  const chunks: string[] = [];
  let cursor = 0;
  while (cursor < cleaned.length) {
    const remaining = cleaned.slice(cursor);
    if (remaining.length <= maxLen) {
      chunks.push(remaining);
      break;
    }

    const windowText = remaining.slice(0, maxLen);
    const splitAt = findSplitIndex(windowText);
    const cut = splitAt >= Math.floor(maxLen * 0.6) ? splitAt + 1 : maxLen;
    chunks.push(remaining.slice(0, cut).trim());
    cursor += cut;
  }
  return chunks.filter(Boolean);
}
`;

const REPLY_VOICE_TTS_TEMPLATE = `import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const DEFAULT_TIMEOUT_MS = 90_000;
const DEFAULT_STATE_TIMEOUT_MS = 5_000;
const MIN_TIMEOUT_MS = 30_000;
const DEFAULT_MAX_BUFFER = 2 * 1024 * 1024;
const MIN_MAX_BUFFER = 256 * 1024;

export type VoiceModeState = "on" | "off";
export type ReplyVoiceExecResult = { stdout?: string; stderr?: string } | string;
export type ReplyVoiceExec = (
  file: string,
  args: string[],
  options: { timeout: number; maxBuffer: number },
) => Promise<ReplyVoiceExecResult>;

function defaultExec(
  file: string,
  args: string[],
  options: { timeout: number; maxBuffer: number },
): Promise<{ stdout: string; stderr: string }> {
  return execFileAsync(file, args, options);
}

function normalizeStdout(result: ReplyVoiceExecResult): string {
  if (typeof result === "string") {
    return result;
  }
  return result.stdout ?? "";
}

function parsePositiveInt(raw: string | undefined, fallback: number, minValue: number): number {
  if (!raw) {
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < minValue) {
    return fallback;
  }
  return parsed;
}

function resolveTimeoutMs(): number {
  return parsePositiveInt(
    process.env.OPENCLAW_REPLY_VOICE_TTS_TIMEOUT_MS,
    DEFAULT_TIMEOUT_MS,
    MIN_TIMEOUT_MS,
  );
}

function resolveMaxBuffer(): number {
  return parsePositiveInt(
    process.env.OPENCLAW_REPLY_VOICE_TTS_MAX_BUFFER,
    DEFAULT_MAX_BUFFER,
    MIN_MAX_BUFFER,
  );
}

function clipErrorText(value: unknown, maxLen = 300): string {
  if (typeof value !== "string") {
    return "";
  }
  const cleaned = value.replace(/\\s+/g, " ").trim();
  if (!cleaned) {
    return "";
  }
  if (cleaned.length <= maxLen) {
    return cleaned;
  }
  return \`\${cleaned.slice(0, maxLen)}...\`;
}

function describeExecError(error: unknown): string {
  if (!(error instanceof Error)) {
    return String(error);
  }
  const extended = error as Error & {
    code?: string | number;
    signal?: string;
    killed?: boolean;
    stderr?: string;
    stdout?: string;
  };
  const details: string[] = [error.message];
  if (extended.code !== undefined) {
    details.push(\`code=\${String(extended.code)}\`);
  }
  if (extended.signal) {
    details.push(\`signal=\${extended.signal}\`);
  }
  if (typeof extended.killed === "boolean") {
    details.push(\`killed=\${String(extended.killed)}\`);
  }
  const stderrText = clipErrorText(extended.stderr);
  if (stderrText) {
    details.push(\`stderr=\${stderrText}\`);
  }
  const stdoutText = clipErrorText(extended.stdout);
  if (stdoutText) {
    details.push(\`stdout=\${stdoutText}\`);
  }
  return details.join("; ");
}

function uniqueNonEmpty(values: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const value of values) {
    const trimmed = value.trim();
    if (!trimmed || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    out.push(trimmed);
  }
  return out;
}

function inferCandidateFromStateScriptPath(stateScriptPath: string): string {
  const stateFileName = basename(stateScriptPath);
  if (stateFileName === "voice_mode_state.sh") {
    return join(dirname(stateScriptPath), "generate_tts_media.sh");
  }
  return stateScriptPath;
}

function buildScriptPathCandidates(explicitScriptPath?: string): string[] {
  const envScript = process.env.XIAOKE_REPLY_VOICE_SCRIPT ?? "";
  const stateScript = process.env.XIAOKE_VOICE_MODE_STATE_SCRIPT ?? "";
  const openclawHome = process.env.OPENCLAW_HOME?.trim() || "";
  const home = process.env.HOME?.trim() || "";

  const candidates = [
    explicitScriptPath ?? "",
    envScript,
    inferCandidateFromStateScriptPath(stateScript),
    openclawHome
      ? \`\${openclawHome}/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh\`
      : "",
    home ? \`\${home}/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh\` : "",
    "/Users/crane/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh",
  ];
  return uniqueNonEmpty(candidates);
}

function buildStateScriptPathCandidates(explicitScriptPath?: string): string[] {
  const envScript = process.env.XIAOKE_VOICE_MODE_STATE_SCRIPT ?? "";
  const openclawHome = process.env.OPENCLAW_HOME?.trim() || "";
  const home = process.env.HOME?.trim() || "";

  return uniqueNonEmpty([
    explicitScriptPath ?? "",
    envScript,
    openclawHome
      ? \`\${openclawHome}/workspace/skills/xiaoke-voice-mode/scripts/voice_mode_state.sh\`
      : "",
    home ? \`\${home}/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/voice_mode_state.sh\` : "",
    "/Users/crane/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/voice_mode_state.sh",
  ]);
}

function normalizeVoiceModeState(value: string | undefined, fallback: VoiceModeState = "off"): VoiceModeState {
  return value?.trim() === "on" ? "on" : fallback;
}

export function createVoiceModeStateBridge(params: {
  stateScriptPath?: string;
  exec?: ReplyVoiceExec;
} = {}) {
  const stateScriptPathCandidates = buildStateScriptPathCandidates(params.stateScriptPath);
  const execImpl = params.exec ?? defaultExec;

  return {
    async get(sessionKey: string, fallbackState?: string): Promise<VoiceModeState> {
      const scriptPath = stateScriptPathCandidates.find((candidate) => existsSync(candidate));
      const normalizedFallback = normalizeVoiceModeState(fallbackState, "off");
      if (!scriptPath) {
        return normalizedFallback;
      }

      try {
        const result = await execImpl("bash", [scriptPath, "get", sessionKey], {
          timeout: DEFAULT_STATE_TIMEOUT_MS,
          maxBuffer: MIN_MAX_BUFFER,
        });
        return normalizeVoiceModeState(normalizeStdout(result), normalizedFallback);
      } catch {
        return normalizedFallback;
      }
    },
    async set(sessionKey: string, mode: VoiceModeState): Promise<VoiceModeState> {
      const scriptPath = stateScriptPathCandidates.find((candidate) => existsSync(candidate));
      const normalizedMode = normalizeVoiceModeState(mode, "off");
      if (!scriptPath) {
        return normalizedMode;
      }

      try {
        const result = await execImpl("bash", [scriptPath, "set", sessionKey, normalizedMode], {
          timeout: DEFAULT_STATE_TIMEOUT_MS,
          maxBuffer: MIN_MAX_BUFFER,
        });
        return normalizeVoiceModeState(normalizeStdout(result), normalizedMode);
      } catch (error) {
        throw new Error(\`voice mode state script execution failed: \${describeExecError(error)}\`);
      }
    },
  };
}

export function createReplyVoiceTtsBridge(params: {
  scriptPath?: string;
  exec?: ReplyVoiceExec;
} = {}) {
  const scriptPathCandidates = buildScriptPathCandidates(params.scriptPath);
  const execImpl = params.exec ?? defaultExec;

  return {
    async generate(text: string): Promise<{ mediaUrl: string }> {
      const scriptPath = scriptPathCandidates.find((candidate) => existsSync(candidate));
      if (!scriptPath) {
        throw new Error(
          \`reply voice script not found; checked: \${scriptPathCandidates.join(", ")}\`,
        );
      }

      const timeoutMs = resolveTimeoutMs();
      const maxBuffer = resolveMaxBuffer();
      let result: ReplyVoiceExecResult;
      try {
        result = await execImpl(
          "bash",
          [scriptPath, "--text", text, "--voice-id", "wakaba_mutsumi"],
          {
            timeout: timeoutMs,
            maxBuffer,
          },
        );
      } catch (error) {
        throw new Error(
          \`reply voice script execution failed (timeoutMs=\${timeoutMs}, maxBuffer=\${maxBuffer}): \${describeExecError(error)}\`,
        );
      }

      const stdout = normalizeStdout(result);
      const mediaLine = stdout
        .split(/\\r?\\n/)
        .map((line) => line.trim())
        .find((line) => line.startsWith("MEDIA:"));
      if (!mediaLine) {
        throw new Error("reply voice script output missing MEDIA line");
      }

      const mediaUrl = mediaLine.slice("MEDIA:".length).trim();
      if (!mediaUrl) {
        throw new Error("reply voice script output MEDIA is empty");
      }
      return { mediaUrl };
    },
  };
}
`;

const VOICE_MODE_TOGGLE_HELPER_FUNCTION = `function normalizeVoiceModeToggleCommand(text: string): string {
  return text
    .replace(/[\\s\\u3000。！？!?，,、；;：:"“”‘’'\`~～()（）【】\\[\\]{}<>《》]/g, "")
    .trim();
}

function resolveVoiceModeToggleCommand(text: string): "on" | "off" | null {
  const normalized = normalizeVoiceModeToggleCommand(text);
  const matches = (phrases: string[]): boolean =>
    phrases.some(
      (phrase) =>
        normalized === phrase || normalized === \`请\${phrase}\` || normalized === \`帮我\${phrase}\`,
    );

  if (matches(["开启语音模式", "打开语音模式", "启用语音模式"])) {
    return "on";
  }
  if (matches(["关闭语音模式", "关掉语音模式", "停用语音模式"])) {
    return "off";
  }
  return null;
}
`;

const PARSE_REPLY_VOICE_FUNCTION = `function parseReplyTargetContentForVoice(content: string, messageType: string): string {
  if (!content || typeof content !== "string") {
    return "";
  }

  if (messageType === "text") {
    try {
      const parsed = JSON.parse(content);
      const text = typeof parsed?.text === "string" ? parsed.text : "";
      return text.trim();
    } catch {
      return content.trim();
    }
  }

  if (messageType === "post") {
    try {
      const parsed = JSON.parse(content);
      const title = typeof parsed?.title === "string" ? parsed.title.trim() : "";
      const blocks = Array.isArray(parsed?.content) ? parsed.content : [];
      const lines: string[] = [];
      if (title) {
        lines.push(title);
      }
      for (const paragraph of blocks) {
        if (!Array.isArray(paragraph)) {
          continue;
        }
        let line = "";
        for (const element of paragraph) {
          if (element?.tag === "text") {
            line += element.text || "";
          } else if (element?.tag === "a") {
            line += element.text || element.href || "";
          } else if (element?.tag === "at") {
            const name = element.user_name || element.user_id || "";
            if (name) {
              line += \`@\${name}\`;
            }
          }
        }
        const cleaned = line.trim();
        if (cleaned) {
          lines.push(cleaned);
        }
      }
      return lines.join("\\n").trim();
    } catch {
      return "";
    }
  }

  return "";
}
`;

const REPLY_VOICE_MODE_TOGGLE_BLOCK = `    if (voiceModeCommandCandidate) {
      const nextVoiceModeState = await voiceModeStateBridge.set(voiceModeSessionKey, voiceModeCommandCandidate);
      voiceModeStateCache.set(voiceModeSessionKey, nextVoiceModeState);
      log(
        \`feishu[\${account.accountId}]: handled voice mode command locally (\${voiceModeCommandCandidate}, \${voiceModeSessionKey})\`,
      );

      await sendMessageFeishu({
        cfg,
        to: feishuTo,
        text:
          voiceModeCommandCandidate === "on"
            ? "语音模式已开启，从现在开始我会优先回复语音。"
            : "语音模式已关闭，从现在开始我会回复文本。",
        replyToMessageId: ctx.messageId,
        accountId: account.accountId,
      });
      return;
    }

    if (voiceModeEnabled) {
      log(
        \`feishu[\${account.accountId}]: voice mode enabled for session \${voiceModeSessionKey}, forcing TTS reply\`,
      );
    }
`;

const REPLY_VOICE_FASTPATH_BLOCK = `    if (replyVoiceCommandCandidate) {
      if (!ctx.parentId) {
        await sendMessageFeishu({
          cfg,
          to: feishuTo,
          text: "请先回复一条消息再发送“生成语音”。",
          replyToMessageId: ctx.messageId,
          accountId: account.accountId,
        });
        return;
      }

      let replyText = "";
      try {
        const repliedMessage = await getMessageFeishu({
          cfg,
          messageId: ctx.parentId,
          accountId: account.accountId,
        });
        if (repliedMessage) {
          replyText = parseReplyTargetContentForVoice(
            repliedMessage.content,
            repliedMessage.contentType,
          );
        }
      } catch (err) {
        log(
          \`feishu[\${account.accountId}]: failed to fetch reply target for voice command: \${String(err)}\`,
        );
      }

      const chunks = splitReplyVoiceText(replyText, 500);
      if (chunks.length === 0) {
        await sendMessageFeishu({
          cfg,
          to: feishuTo,
          text: "该消息无法语音化，请回复一条包含文本的消息。",
          replyToMessageId: ctx.messageId,
          accountId: account.accountId,
        });
        return;
      }

      let sentChunks = 0;
      for (const chunk of chunks) {
        try {
          const { mediaUrl } = await replyVoiceTtsBridge.generate(chunk);
          await sendMediaFeishu({
            cfg,
            to: feishuTo,
            mediaUrl,
            replyToMessageId: ctx.messageId,
            accountId: account.accountId,
          });
          sentChunks += 1;
        } catch (err) {
          const errText = String(err);
          const missingVoiceScript =
            errText.includes("reply voice script not found") ||
            errText.includes("无法找到语音脚本");
          log(
            \`feishu[\${account.accountId}]: reply voice synthesis failed after \${sentChunks} chunk(s): \${errText}\`,
          );
          await sendMessageFeishu({
            cfg,
            to: feishuTo,
            text:
              missingVoiceScript
                ? "无法找到语音脚本，请检查 xiaoke-voice-mode/scripts/generate_tts_media.sh。"
                : sentChunks > 0
                  ? "语音生成中途失败，后续分段已停止。"
                  : "语音生成失败，请稍后重试。",
            replyToMessageId: ctx.messageId,
            accountId: account.accountId,
          });
          return;
        }
      }
      return;
    }
`;

const NO_FINAL_FALLBACK_BLOCK = `    try {
      dispatcher.markComplete();
      await dispatcher.waitForIdle();
    } catch (dispatchDrainErr) {
      error(
        \`feishu[\${account.accountId}]: failed to drain reply dispatcher queue: \${String(dispatchDrainErr)}\`,
      );
    }

    const finalCount = counts.final ?? 0;
    const dispatcherState = dispatcher as {
      __openclawFeishuNoFinalTextCandidate?: () => string;
      __openclawFeishuHadOutboundDelivery?: () => boolean;
      __openclawFeishuHadMediaDelivery?: () => boolean;
    };
    const outboundDeliveryState = dispatcherState.__openclawFeishuHadOutboundDelivery?.();
    const hasOutboundDeliverySignal = typeof outboundDeliveryState === "boolean";
    let hadOutboundDelivery = outboundDeliveryState === true;
    const outboundMediaState = dispatcherState.__openclawFeishuHadMediaDelivery?.();
    const hasOutboundMediaSignal = typeof outboundMediaState === "boolean";
    let hadOutboundMediaDelivery = outboundMediaState === true;
    let supplementalVoiceFailed = false;
    const noFinalFallbackState = !queuedFinal && finalCount === 0;
    void noFinalFallbackState;
    if (
      voiceModeEnabled &&
      queuedFinal &&
      finalCount > 0 &&
      (!hasOutboundMediaSignal || !hadOutboundMediaDelivery)
    ) {
      const voiceCandidate = (dispatcherState.__openclawFeishuNoFinalTextCandidate?.() ?? "").trim();
      const voiceChunks = splitReplyVoiceText(voiceCandidate, 500);
      if (voiceChunks.length > 0) {
        try {
          for (const voiceChunk of voiceChunks) {
            const { mediaUrl } = await replyVoiceTtsBridge.generate(voiceChunk);
            await sendMediaFeishu({
              cfg,
              to: feishuTo,
              mediaUrl,
              replyToMessageId: ctx.messageId,
              accountId: account.accountId,
            });
          }
          hadOutboundDelivery = true;
          hadOutboundMediaDelivery = true;
          log(
            \`feishu[\${account.accountId}]: delivered supplemental voice media from final text candidate\`,
          );
        } catch (voiceSupplementErr) {
          supplementalVoiceFailed = true;
          error(
            \`feishu[\${account.accountId}]: failed to deliver supplemental voice media from final text candidate: \${String(voiceSupplementErr)}\`,
          );
        }
      }
    }

    const voiceNoDeliveryAfterSupplementFailureFallbackState =
      voiceModeEnabled &&
      queuedFinal &&
      finalCount > 0 &&
      !hadOutboundDelivery &&
      supplementalVoiceFailed;
    const voiceQueuedButNoDeliveryDelayFallbackState =
      voiceModeEnabled &&
      queuedFinal &&
      finalCount > 0 &&
      !hadOutboundDelivery &&
      !voiceNoDeliveryAfterSupplementFailureFallbackState;

    if (voiceQueuedButNoDeliveryDelayFallbackState) {
      log(
        \`feishu[\${account.accountId}]: queued final reply without confirmed outbound delivery in voice mode; scheduling delayed fallback text in \${FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS}ms (deliverySignal=\${hasOutboundDeliverySignal ? "present" : "missing"})\`,
      );
      setTimeout(() => {
        void (async () => {
          const delayedOutboundDeliveryState = dispatcherState.__openclawFeishuHadOutboundDelivery?.();
          const delayedHadOutboundDelivery = delayedOutboundDeliveryState === true;
          if (delayedHadOutboundDelivery) {
            log(
              \`feishu[\${account.accountId}]: delayed no-delivery fallback skipped after \${FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS}ms because outbound delivery recovered\`,
            );
            return;
          }

          const delayedNoFinalTextCandidate =
            (dispatcherState.__openclawFeishuNoFinalTextCandidate?.() ?? "").trim();
          if (delayedNoFinalTextCandidate.length > 0) {
            log(
              \`feishu[\${account.accountId}]: using no-final text candidate from dispatcher\`,
            );
          }
          const delayedFallbackText = slowReplyNotified
            ? HARD_TIMEOUT_FALLBACK_TEXT
            : delayedNoFinalTextCandidate.length > 0
              ? delayedNoFinalTextCandidate
              : VOICE_MODE_NO_REPLY_FALLBACK_TEXT;
          log(
            \`feishu[\${account.accountId}]: delayed no-delivery fallback timer fired after \${FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS}ms; forcing fallback text\`,
          );

          let delayedFallbackTextSent = false;
          try {
            await sendMessageFeishu({
              cfg,
              to: feishuTo,
              text: delayedFallbackText,
              replyToMessageId: ctx.messageId,
              accountId: account.accountId,
            });
            delayedFallbackTextSent = true;
            log(
              \`feishu[\${account.accountId}]: sent no-final fallback text via reply\`,
            );
          } catch (delayedFallbackTextErr) {
            error(
              \`feishu[\${account.accountId}]: failed to send voice mode no-reply fallback text via reply: \${String(delayedFallbackTextErr)}\`,
            );
          }

          if (!delayedFallbackTextSent) {
            try {
              await sendMessageFeishu({
                cfg,
                to: feishuTo,
                text: delayedFallbackText,
                accountId: account.accountId,
              });
              delayedFallbackTextSent = true;
              log(
                \`feishu[\${account.accountId}]: sent no-final fallback text via direct message\`,
              );
            } catch (delayedFallbackDirectErr) {
              error(
                \`feishu[\${account.accountId}]: failed to send voice mode no-reply fallback text via direct message: \${String(delayedFallbackDirectErr)}\`,
              );
            }
          }
        })().catch((delayedFallbackErr) => {
          error(
            \`feishu[\${account.accountId}]: delayed no-delivery fallback task failed: \${String(delayedFallbackErr)}\`,
          );
        });
      }, FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS);
    }

    if (voiceNoDeliveryAfterSupplementFailureFallbackState) {
      log(
        \`feishu[\${account.accountId}]: supplemental voice delivery failed in voice mode; forcing fallback text\`,
      );
    }

    if (voiceNoDeliveryAfterSupplementFailureFallbackState) {
      const noFinalTextCandidate =
        (dispatcherState.__openclawFeishuNoFinalTextCandidate?.() ?? "").trim();
      if (noFinalTextCandidate.length > 0) {
        log(
          \`feishu[\${account.accountId}]: using no-final text candidate from dispatcher\`,
        );
      }
      const fallbackText = slowReplyNotified
        ? HARD_TIMEOUT_FALLBACK_TEXT
        : noFinalTextCandidate.length > 0
          ? noFinalTextCandidate
          : voiceModeEnabled
            ? VOICE_MODE_NO_REPLY_FALLBACK_TEXT
            : TEXT_MODE_NO_REPLY_FALLBACK_TEXT;
      let fallbackTextSent = false;
      try {
        await sendMessageFeishu({
          cfg,
          to: feishuTo,
          text: fallbackText,
          replyToMessageId: ctx.messageId,
          accountId: account.accountId,
        });
        fallbackTextSent = true;
        log(
          \`feishu[\${account.accountId}]: sent no-final fallback text via reply\`,
        );
      } catch (fallbackTextErr) {
        error(
          \`feishu[\${account.accountId}]: failed to send voice mode no-reply fallback text via reply: \${String(fallbackTextErr)}\`,
        );
      }

      if (!fallbackTextSent) {
        try {
          await sendMessageFeishu({
            cfg,
            to: feishuTo,
            text: fallbackText,
            accountId: account.accountId,
          });
          fallbackTextSent = true;
          log(
            \`feishu[\${account.accountId}]: sent no-final fallback text via direct message\`,
          );
        } catch (fallbackDirectErr) {
          error(
            \`feishu[\${account.accountId}]: failed to send voice mode no-reply fallback text via direct message: \${String(fallbackDirectErr)}\`,
          );
        }
      }
    }
`;

function insertAfterAnchor(source, anchor, snippet, label) {
  const index = source.indexOf(anchor);
  if (index === -1) {
    throw new Error(`${label} anchor not found`);
  }
  const insertAt = index + anchor.length;
  return `${source.slice(0, insertAt)}\n${snippet}${source.slice(insertAt)}`;
}

function insertBeforeAnchor(source, anchor, snippet, label) {
  const index = source.indexOf(anchor);
  if (index === -1) {
    throw new Error(`${label} anchor not found`);
  }
  return `${source.slice(0, index)}${snippet}\n${source.slice(index)}`;
}

function replaceReplyVoiceFastpathBlock(source) {
  const start = source.indexOf(REPLY_VOICE_FASTPATH_START_MARKER);
  if (start === -1) {
    throw new Error("reply voice fastpath start marker not found");
  }

  const marker = source.indexOf(REPLY_VOICE_FASTPATH_MARKER, start);
  if (marker === -1) {
    throw new Error("reply voice fastpath marker not found for replacement");
  }

  const end = source.indexOf(REPLY_VOICE_FASTPATH_END_MARKER, marker);
  if (end === -1) {
    throw new Error("reply voice fastpath end marker not found");
  }

  return `${source.slice(0, start)}${REPLY_VOICE_FASTPATH_BLOCK}${source.slice(
    end + REPLY_VOICE_FASTPATH_END_MARKER.length,
  )}`;
}

function upsertVoiceModeToggleBlock(source) {
  let updated = source;

  if (
    updated.includes(REPLY_VOICE_MODE_TOGGLE_STATE_SET_MARKER) &&
    updated.includes(REPLY_VOICE_MODE_ENABLED_LOG_MARKER)
  ) {
    return updated;
  }

  const legacyStart = updated.indexOf(REPLY_VOICE_MODE_TOGGLE_BLOCK_START_MARKER);
  if (legacyStart !== -1) {
    const fastpathStart = updated.indexOf(REPLY_VOICE_MODE_TOGGLE_BLOCK_END_MARKER, legacyStart);
    if (fastpathStart !== -1) {
      return `${updated.slice(0, legacyStart)}${REPLY_VOICE_MODE_TOGGLE_BLOCK}\n${updated.slice(fastpathStart)}`;
    }
  }

  if (!updated.includes(REPLY_VOICE_FASTPATH_ANCHOR)) {
    throw new Error("voice mode toggle anchor not found");
  }
  updated = insertAfterAnchor(
    updated,
    REPLY_VOICE_FASTPATH_ANCHOR,
    REPLY_VOICE_MODE_TOGGLE_BLOCK,
    "voice mode toggle block",
  );

  return updated;
}

function replaceNoFinalFallbackBlockByBoundary(source, startMarker) {
  const start = source.indexOf(startMarker);
  if (start === -1) {
    return null;
  }
  let end = -1;
  for (const marker of NO_FINAL_FALLBACK_BLOCK_END_MARKERS) {
    const candidate = source.indexOf(marker, start);
    if (candidate !== -1 && (end === -1 || candidate < end)) {
      end = candidate;
    }
  }
  if (end === -1) {
    throw new Error("no-final fallback block end marker not found");
  }
  return `${source.slice(0, start)}${NO_FINAL_FALLBACK_BLOCK}\n${source.slice(end)}`;
}

function hasCompleteNoFinalFallbackBlockSignature(source) {
  return NO_FINAL_FALLBACK_COMPLETE_SIGNATURE_MARKERS.every((marker) => source.includes(marker));
}

function upsertNoFinalFallbackBlock(source) {
  const dispatchDrainReplaced = replaceNoFinalFallbackBlockByBoundary(
    source,
    NO_FINAL_FALLBACK_DISPATCH_DRAIN_START_MARKER,
  );
  if (dispatchDrainReplaced !== null) {
    return dispatchDrainReplaced;
  }

  const blockAwareReplaced = replaceNoFinalFallbackBlockByBoundary(
    source,
    NO_FINAL_FALLBACK_BLOCK_AWARE_START_MARKER,
  );
  if (blockAwareReplaced !== null) {
    return blockAwareReplaced;
  }

  const genericReplaced = replaceNoFinalFallbackBlockByBoundary(
    source,
    NO_FINAL_FALLBACK_GENERIC_START_MARKER,
  );
  if (genericReplaced !== null) {
    return genericReplaced;
  }

  const voiceOnlyReplaced = replaceNoFinalFallbackBlockByBoundary(
    source,
    NO_FINAL_FALLBACK_VOICE_ONLY_START_MARKER,
  );
  if (voiceOnlyReplaced !== null) {
    return voiceOnlyReplaced;
  }

  if (hasCompleteNoFinalFallbackBlockSignature(source)) {
    return source;
  }

  if (!NO_FINAL_FALLBACK_INSERT_PATTERN.test(source)) {
    if (!source.includes("dispatch complete (queuedFinal=") && !source.includes("counts.final")) {
      return source;
    }
    throw new Error("no-final fallback insert anchor not found");
  }

  return source.replace(NO_FINAL_FALLBACK_INSERT_PATTERN, `$1${NO_FINAL_FALLBACK_BLOCK}`);
}

function upsertSlowReplyNoticeDisable(source) {
  let updated = source;

  if (FEISHU_SLOW_REPLY_NOTICE_ENABLED_PATTERN.test(updated)) {
    updated = updated.replace(
      FEISHU_SLOW_REPLY_NOTICE_ENABLED_PATTERN,
      FEISHU_SLOW_REPLY_NOTICE_ENABLED_REPLACEMENT,
    );
  } else if (FEISHU_SLOW_REPLY_NOTICE_MS_PATTERN.test(updated)) {
    updated = updated.replace(
      FEISHU_SLOW_REPLY_NOTICE_MS_PATTERN,
      (line) => `${line}\n${FEISHU_SLOW_REPLY_NOTICE_ENABLED_REPLACEMENT}`,
    );
  } else if (!updated.includes(FEISHU_SLOW_REPLY_NOTICE_ENABLED_REPLACEMENT)) {
    throw new Error("feishu slow reply notice marker not found");
  }

  if (updated.includes(SLOW_REPLY_TIMER_GUARDED_START)) {
    return updated;
  }

  if (updated.includes(SLOW_REPLY_TIMER_LEGACY_START)) {
    updated = updated.replace(SLOW_REPLY_TIMER_LEGACY_START, SLOW_REPLY_TIMER_GUARDED_START);
  }
  if (updated.includes(SLOW_REPLY_TIMER_LEGACY_END)) {
    updated = updated.replace(SLOW_REPLY_TIMER_LEGACY_END, SLOW_REPLY_TIMER_GUARDED_END);
  }
  if (updated.includes(SLOW_REPLY_TIMER_LEGACY_CLEAR)) {
    updated = updated.replace(SLOW_REPLY_TIMER_LEGACY_CLEAR, SLOW_REPLY_TIMER_GUARDED_CLEAR);
  }
  if (
    !updated.includes(SLOW_REPLY_TIMER_GUARDED_START) &&
    !updated.includes(FEISHU_SLOW_REPLY_TIMER_COMPAT_MARKER)
  ) {
    updated = insertAfterAnchor(
      updated,
      FEISHU_SLOW_REPLY_NOTICE_ENABLED_REPLACEMENT,
      FEISHU_SLOW_REPLY_TIMER_COMPAT_MARKER,
      "slow reply timer compat marker",
    );
  }

  return updated;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function buildDispatchOptionPropertyPattern(name) {
  return new RegExp(`^\\s*${escapeRegExp(name)}\\b\\s*:`);
}

function buildDispatchOptionShorthandPattern(name) {
  return new RegExp(`^\\s*${escapeRegExp(name)}\\b\\s*,?\\s*(?:\\/\\/.*)?$`);
}

function matchesDispatchOptionLine(line, name) {
  return (
    buildDispatchOptionPropertyPattern(name).test(line) ||
    buildDispatchOptionShorthandPattern(name).test(line)
  );
}

function findMatchingBrace(source, openBraceIndex) {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  let inTemplate = false;
  let inLineComment = false;
  let inBlockComment = false;

  for (let i = openBraceIndex; i < source.length; i += 1) {
    const ch = source[i];
    const next = source[i + 1];
    const prev = source[i - 1];

    if (inLineComment) {
      if (ch === "\n") {
        inLineComment = false;
      }
      continue;
    }
    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }
    if (inSingle) {
      if (ch === "'" && prev !== "\\") {
        inSingle = false;
      }
      continue;
    }
    if (inDouble) {
      if (ch === '"' && prev !== "\\") {
        inDouble = false;
      }
      continue;
    }
    if (inTemplate) {
      if (ch === "`" && prev !== "\\") {
        inTemplate = false;
      }
      continue;
    }

    if (ch === "/" && next === "/") {
      inLineComment = true;
      i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      inBlockComment = true;
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === "`") {
      inTemplate = true;
      continue;
    }

    if (ch === "{") {
      depth += 1;
      continue;
    }
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }

  return -1;
}

function findLastMatchingLineIndex(lines, predicate) {
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (predicate(lines[i])) {
      return i;
    }
  }
  return -1;
}

function detectDispatchOptionIndent(lines) {
  for (const line of lines) {
    const match = line.match(
      /^(\s*)(?:[A-Za-z_$][A-Za-z0-9_$]*\b\s*:|[A-Za-z_$][A-Za-z0-9_$]*\b\s*,|\.\.\.)/,
    );
    if (match) {
      return match[1];
    }
  }
  return "          ";
}

function upsertDispatchReplyOptionsLine(lines, fallbackIndent) {
  const lineIndex = lines.findIndex((line) => /^\s*replyOptions\b/.test(line));
  if (lineIndex === -1) {
    return;
  }

  const line = lines[lineIndex];
  const match = line.match(/^(\s*)replyOptions(?:\s*:\s*([^,]+))?,\s*(?:\/\/.*)?$/);
  if (!match) {
    return;
  }

  const indent = match[1] ?? fallbackIndent;
  const expression = (match[2] ?? "replyOptions").trim();
  if (expression.startsWith("{")) {
    if (expression.includes(`disableBlockStreaming: ${REPLY_VOICE_DISABLE_BLOCK_STREAMING_EXPRESSION}`)) {
      return;
    }
    if (expression.includes("disableBlockStreaming:")) {
      const normalizedExpression = expression.replace(
        /disableBlockStreaming:\s*[^,}]+/,
        `disableBlockStreaming: ${REPLY_VOICE_DISABLE_BLOCK_STREAMING_EXPRESSION}`,
      );
      lines[lineIndex] = `${indent}replyOptions: ${normalizedExpression},`;
      return;
    }
  }

  lines[lineIndex] = `${indent}replyOptions: { ...${expression}, disableBlockStreaming: ${REPLY_VOICE_DISABLE_BLOCK_STREAMING_EXPRESSION} },`;
}

function upsertDispatchOptionLine(lines, { name, value, anchorNames, fallbackIndent }) {
  const propertyPattern = buildDispatchOptionPropertyPattern(name);
  const existingIndex = lines.findIndex((line) => propertyPattern.test(line));
  const desiredLine = (indent) => `${indent}${name}: ${value},`;

  if (existingIndex !== -1) {
    const indent = lines[existingIndex].match(/^(\s*)/)?.[1] ?? fallbackIndent;
    lines[existingIndex] = desiredLine(indent);
    return;
  }

  let anchorIndex = -1;
  for (const anchorName of anchorNames) {
    anchorIndex = findLastMatchingLineIndex(lines, (line) => matchesDispatchOptionLine(line, anchorName));
    if (anchorIndex !== -1) {
      break;
    }
  }

  if (anchorIndex === -1) {
    anchorIndex = findLastMatchingLineIndex(lines, (line) => line.trim().length > 0);
  }

  const indent =
    anchorIndex !== -1 ? (lines[anchorIndex].match(/^(\s*)/)?.[1] ?? fallbackIndent) : fallbackIndent;
  const insertIndex = anchorIndex === -1 ? lines.length : anchorIndex + 1;
  lines.splice(insertIndex, 0, desiredLine(indent));
}

function normalizeDispatchReplyOptionsBody(body) {
  const lines = body.split("\n");
  const fallbackIndent = detectDispatchOptionIndent(lines);
  upsertDispatchReplyOptionsLine(lines, fallbackIndent);

  upsertDispatchOptionLine(lines, {
    name: "timeoutOverrideSeconds",
    value: "FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS",
    anchorNames: ["replyOptions", "dispatcher", "cfg", "ctx"],
    fallbackIndent,
  });
  upsertDispatchOptionLine(lines, {
    name: "forceVoiceModeTts",
    value: "voiceModeEnabled",
    anchorNames: ["timeoutOverrideSeconds", "replyOptions", "dispatcher", "cfg", "ctx"],
    fallbackIndent,
  });
  upsertDispatchOptionLine(lines, {
    name: "thinking",
    value: 'voiceModeEnabled ? "off" : undefined',
    anchorNames: ["forceVoiceModeTts", "timeoutOverrideSeconds", "replyOptions", "dispatcher", "cfg", "ctx"],
    fallbackIndent,
  });
  upsertDispatchOptionLine(lines, {
    name: "disableBlockStreaming",
    value: REPLY_VOICE_DISABLE_BLOCK_STREAMING_EXPRESSION,
    anchorNames: [
      "thinking",
      "forceVoiceModeTts",
      "timeoutOverrideSeconds",
      "replyOptions",
      "dispatcher",
      "cfg",
      "ctx",
    ],
    fallbackIndent,
  });

  return lines.join("\n");
}

function normalizeDispatcherCreateBody(body) {
  const lines = body.split("\n");
  const fallbackIndent = detectDispatchOptionIndent(lines);

  upsertDispatchOptionLine(lines, {
    name: "forceVoiceModeTts",
    value: "voiceModeEnabled",
    anchorNames: [
      "accountId",
      "mentionTargets",
      "replyToMessageId",
      "chatId",
      "runtime",
      "agentId",
      "cfg",
    ],
    fallbackIndent,
  });

  return lines.join("\n");
}

function upsertReplyVoiceDispatchOptions(source) {
  let updated = source;

  if (!updated.includes("dispatchReplyFromConfig")) {
    return updated;
  }

  const callPattern = new RegExp(REPLY_VOICE_DISPATCH_CALL_PATTERN);
  let match = callPattern.exec(updated);
  while (match) {
    const openBraceIndex = match.index + match[0].lastIndexOf("{");
    const closeBraceIndex = findMatchingBrace(updated, openBraceIndex);
    if (closeBraceIndex === -1) {
      throw new Error("reply voice dispatch options block not found");
    }
    const bodyStart = openBraceIndex + 1;
    const body = updated.slice(bodyStart, closeBraceIndex);
    const normalizedBody = normalizeDispatchReplyOptionsBody(body);
    if (normalizedBody !== body) {
      updated = `${updated.slice(0, bodyStart)}${normalizedBody}${updated.slice(closeBraceIndex)}`;
      callPattern.lastIndex = bodyStart + normalizedBody.length;
    } else {
      callPattern.lastIndex = closeBraceIndex + 1;
    }
    match = callPattern.exec(updated);
  }

  return updated;
}

function upsertReplyVoiceDispatcherCreateOptions(source) {
  let updated = source;

  if (!updated.includes("createFeishuReplyDispatcher")) {
    return updated;
  }

  const callPattern = new RegExp(REPLY_VOICE_CREATE_DISPATCHER_CALL_PATTERN);
  let match = callPattern.exec(updated);
  while (match) {
    const openBraceIndex = match.index + match[0].lastIndexOf("{");
    const closeBraceIndex = findMatchingBrace(updated, openBraceIndex);
    if (closeBraceIndex === -1) {
      throw new Error("reply voice dispatcher create options block not found");
    }
    const bodyStart = openBraceIndex + 1;
    const body = updated.slice(bodyStart, closeBraceIndex);
    const normalizedBody = normalizeDispatcherCreateBody(body);
    if (normalizedBody !== body) {
      updated = `${updated.slice(0, bodyStart)}${normalizedBody}${updated.slice(closeBraceIndex)}`;
      callPattern.lastIndex = bodyStart + normalizedBody.length;
    } else {
      callPattern.lastIndex = closeBraceIndex + 1;
    }
    match = callPattern.exec(updated);
  }

  return updated;
}

export function patchFeishuReplyDispatcherSource(source) {
  let updated = source;

  if (!updated.includes("createReplyDispatcherWithTyping")) {
    throw new Error("reply dispatcher patch anchor not found");
  }

  if (!updated.includes(REPLY_DISPATCHER_STREAMING_COUNTER_MARKER)) {
    const streamingStartPromisePattern = /let\s+streamingStartPromise:[^;]+;/m;
    if (!streamingStartPromisePattern.test(updated)) {
      throw new Error("reply dispatcher streaming start promise anchor not found");
    }
    updated = updated.replace(
      streamingStartPromisePattern,
      "$&\n  let streamingUpdateCount = 0;",
    );
  }

  if (
    !updated.includes(REPLY_DISPATCHER_STREAMING_COUNTER_RESET_MARKER) &&
    updated.includes('lastPartial = "";')
  ) {
    updated = updated.replace('lastPartial = "";', 'lastPartial = "";\n    streamingUpdateCount = 0;');
  }

  const onModelSelectedPattern = /^([ \t]*)onModelSelected:\s*prefixContext\.onModelSelected,\s*$/m;
  const replyOptionsKeyPattern = /replyOptions:\s*\{/g;
  let replyOptionsBodyStart = -1;
  let replyOptionsCloseBraceIndex = -1;
  let replyOptionsBody = "";
  while (true) {
    const keyMatch = replyOptionsKeyPattern.exec(updated);
    if (!keyMatch) {
      break;
    }
    const blockOpenBraceIndex = keyMatch.index + keyMatch[0].lastIndexOf("{");
    const blockCloseBraceIndex = findMatchingBrace(updated, blockOpenBraceIndex);
    if (blockCloseBraceIndex === -1) {
      continue;
    }
    const bodyStart = blockOpenBraceIndex + 1;
    const candidateBody = updated.slice(bodyStart, blockCloseBraceIndex);
    if (!onModelSelectedPattern.test(candidateBody)) {
      replyOptionsKeyPattern.lastIndex = blockCloseBraceIndex + 1;
      continue;
    }
    replyOptionsBodyStart = bodyStart;
    replyOptionsCloseBraceIndex = blockCloseBraceIndex;
    replyOptionsBody = candidateBody;
    break;
  }

  if (replyOptionsBodyStart === -1 || replyOptionsCloseBraceIndex === -1) {
    throw new Error("reply dispatcher onModelSelected anchor not found");
  }

  const onModelSelectedMatch = replyOptionsBody.match(onModelSelectedPattern);
  if (!onModelSelectedMatch) {
    throw new Error("reply dispatcher onModelSelected anchor not found");
  }
  const optionIndent = onModelSelectedMatch[1] ?? "      ";
  const i1 = `${optionIndent}  `;
  const i2 = `${optionIndent}    `;
  const i3 = `${optionIndent}      `;
  const i4 = `${optionIndent}        `;
  const i5 = `${optionIndent}          `;
  const callbacksBlock = [
    `${optionIndent}onAssistantMessageStart:`,
    `${i1}streamingEnabled && renderMode === "card"`,
    `${i2}? () => {`,
    `${i3}params.runtime.log?.(`,
    `${i4}\`feishu[\${account.accountId}] streaming warmup: onAssistantMessageStart (renderMode=card)\`,`,
    `${i3});`,
    `${i3}startStreaming();`,
    `${i2}}`,
    `${i2}: undefined,`,
    `${optionIndent}onPartialReply: streamingEnabled`,
    `${i1}? (payload: ReplyPayload) => {`,
    `${i2}if (!payload.text || payload.text === lastPartial) {`,
    `${i3}return;`,
    `${i2}}`,
    `${i2}if (`,
    `${i3}!streamingStartPromise &&`,
    `${i3}!streaming &&`,
    `${i3}(renderMode === "card" || (renderMode === "auto" && shouldUseCard(payload.text)))`,
    `${i2}) {`,
    `${i3}params.runtime.log?.(`,
    `${i4}\`feishu[\${account.accountId}] streaming warmup: first partial (renderMode=\${renderMode})\`,`,
    `${i3});`,
    `${i3}startStreaming();`,
    `${i2}}`,
    `${i2}lastPartial = payload.text;`,
    `${i2}streamText = payload.text;`,
    `${i2}partialUpdateQueue = partialUpdateQueue.then(async () => {`,
    `${i3}if (streamingStartPromise) {`,
    `${i4}await streamingStartPromise;`,
    `${i3}}`,
    `${i3}if (streaming?.isActive()) {`,
    `${i4}await streaming.update(streamText);`,
    `${i4}streamingUpdateCount += 1;`,
    `${i4}params.runtime.log?.(`,
    `${i5}\`feishu[\${account.accountId}] streaming partial update #\${streamingUpdateCount}\`,`,
    `${i4});`,
    `${i3}}`,
    `${i2}});`,
    `${i1}}`,
    `${i1}: undefined,`,
  ].join("\n");

  const normalizedReplyOptionsBody = replyOptionsBody
    .replace(/^[ \t]*onAssistantMessageStart:\s*[\s\S]*?\n[ \t]*: undefined,\s*\n?/m, "")
    .replace(/^[ \t]*onPartialReply:\s*streamingEnabled[\s\S]*?\n[ \t]*: undefined,\s*\n?/m, "")
    .replace(onModelSelectedPattern, (match) => `${match}\n${callbacksBlock}`)
    .replace(/\n{3,}/g, "\n\n");

  updated = `${updated.slice(0, replyOptionsBodyStart)}${normalizedReplyOptionsBody}${updated.slice(
    replyOptionsCloseBraceIndex,
  )}`;

  return updated;
}

function upsertReplyVoiceMentionGuardBypass(source) {
  return source.replace(
    REPLY_VOICE_MENTION_GUARD_PATTERN,
    "if (requireMention && !ctx.mentionedBot && !voiceModeCommandCandidate && !replyVoiceCommandCandidate)",
  );
}

function findImportAnchor(source) {
  for (const anchor of TYPE_IMPORT_ANCHORS) {
    if (source.includes(anchor)) {
      return anchor;
    }
  }
  const fallbackMatch = source.match(TYPE_IMPORT_FALLBACK_PATTERN);
  if (fallbackMatch && fallbackMatch.length > 0) {
    return fallbackMatch[fallbackMatch.length - 1];
  }
  return null;
}

export function patchFeishuBotReplyVoiceSource(source) {
  let updated = source;

  updated = updated.replace(BROKEN_PARSE_JOIN_LITERAL_PATTERN, FIXED_PARSE_JOIN_LITERAL);

  if (FEISHU_REPLY_TIMEOUT_OVERRIDE_PATTERN.test(updated)) {
    updated = updated.replace(
      FEISHU_REPLY_TIMEOUT_OVERRIDE_PATTERN,
      FEISHU_REPLY_TIMEOUT_OVERRIDE_REPLACEMENT,
    );
  } else if (!updated.includes(FEISHU_REPLY_TIMEOUT_OVERRIDE_REPLACEMENT)) {
    updated = insertAfterAnchor(
      updated,
      PERMISSION_COOLDOWN_ANCHOR,
      `${FEISHU_REPLY_TIMEOUT_OVERRIDE_REPLACEMENT}\n${FEISHU_SLOW_REPLY_NOTICE_MS_REPLACEMENT}\n${FEISHU_SLOW_REPLY_NOTICE_ENABLED_REPLACEMENT}\n${FEISHU_SLOW_REPLY_TIMER_COMPAT_MARKER}`,
      "feishu reply timeout override marker",
    );
  }
  updated = upsertSlowReplyNoticeDisable(updated);

  if (MEDIA_IMPORT_PATTERN.test(updated)) {
    updated = updated.replace(MEDIA_IMPORT_PATTERN, MEDIA_IMPORT_REPLACEMENT);
  } else if (!updated.includes(MEDIA_IMPORT_REPLACEMENT)) {
    throw new Error("media import anchor not found");
  }

  // Normalize reply-voice imports first to avoid duplicate bindings after repeated patch runs.
  updated = updated.replace(REPLY_VOICE_COMMAND_IMPORT_PATTERN, "");
  updated = updated.replace(REPLY_VOICE_TTS_IMPORT_PATTERN, "");
  {
    const anchor = findImportAnchor(updated);
    if (!anchor) {
      throw new Error("reply voice import anchor not found");
    }
    updated = insertAfterAnchor(
      updated,
      anchor,
      `${REPLY_VOICE_COMMAND_IMPORT}\n${REPLY_VOICE_TTS_IMPORT}`,
      "reply voice imports",
    );
  }

  if (!updated.includes(REPLY_VOICE_TTS_BRIDGE_MARKER)) {
    updated = insertAfterAnchor(
      updated,
      PERMISSION_COOLDOWN_ANCHOR,
      `${REPLY_VOICE_TTS_BRIDGE_MARKER}\n${VOICE_MODE_STATE_BRIDGE_MARKER}`,
      "reply voice bridge const",
    );
  } else if (!updated.includes(VOICE_MODE_STATE_BRIDGE_MARKER)) {
    updated = insertAfterAnchor(
      updated,
      REPLY_VOICE_TTS_BRIDGE_MARKER,
      VOICE_MODE_STATE_BRIDGE_MARKER,
      "voice mode state bridge const",
    );
  }

  if (!updated.includes(VOICE_MODE_STATE_CACHE_MARKER)) {
    updated = insertAfterAnchor(
      updated,
      REPLY_VOICE_TTS_BRIDGE_MARKER,
      VOICE_MODE_STATE_CACHE_MARKER,
      "voice mode state cache",
    );
  }

  if (!updated.includes(VOICE_MODE_NO_REPLY_FALLBACK_TEXT_MARKER)) {
    const fallbackTextAnchor = updated.includes(VOICE_MODE_STATE_CACHE_MARKER)
      ? VOICE_MODE_STATE_CACHE_MARKER
      : REPLY_VOICE_TTS_BRIDGE_MARKER;
    updated = insertAfterAnchor(
      updated,
      fallbackTextAnchor,
      VOICE_MODE_NO_REPLY_FALLBACK_TEXT_BLOCK,
      "voice mode no-reply fallback text",
    );
  }

  if (
    !updated.includes(HARD_TIMEOUT_FALLBACK_TEXT_MARKER) ||
    !updated.includes(TEXT_MODE_NO_REPLY_FALLBACK_TEXT_MARKER)
  ) {
    updated = insertAfterAnchor(
      updated,
      VOICE_MODE_NO_REPLY_FALLBACK_TEXT_BLOCK,
      REPLY_VOICE_FALLBACK_TEXT_DEFAULTS_BLOCK,
      "voice mode fallback text defaults",
    );
  }

  if (FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_PATTERN.test(updated)) {
    updated = updated.replace(
      FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_PATTERN,
      FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_REPLACEMENT,
    );
  } else if (!updated.includes(FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MARKER)) {
    if (!updated.includes(HARD_TIMEOUT_FALLBACK_TEXT_MARKER)) {
      throw new Error("voice no-delivery fallback delay anchor not found");
    }
    updated = updated.replace(
      HARD_TIMEOUT_FALLBACK_TEXT_MARKER,
      `${FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_REPLACEMENT}\n${HARD_TIMEOUT_FALLBACK_TEXT_MARKER}`,
    );
  }

  if (!updated.includes(PARSE_REPLY_VOICE_MARKER)) {
    updated = insertBeforeAnchor(
      updated,
      PARSE_REPLY_VOICE_INSERT_ANCHOR,
      PARSE_REPLY_VOICE_FUNCTION,
      "reply voice parse function",
    );
  }

  if (!updated.includes(VOICE_MODE_TOGGLE_HELPER_MARKER)) {
    updated = insertBeforeAnchor(
      updated,
      PARSE_REPLY_VOICE_MARKER,
      VOICE_MODE_TOGGLE_HELPER_FUNCTION,
      "voice mode toggle helper function",
    );
  }

  if (!updated.includes(REPLY_VOICE_CANDIDATE_MARKER)) {
    updated = insertAfterAnchor(
      updated,
      REPLY_VOICE_CANDIDATE_ANCHOR,
      `  ${REPLY_VOICE_CANDIDATE_MARKER}`,
      "reply voice candidate",
    );
  }

  if (!updated.includes(REPLY_VOICE_RUNTIME_STATE_BLOCK)) {
    if (updated.includes(REPLY_VOICE_RUNTIME_STATE_MARKER)) {
      const runtimeStateStart = updated.indexOf(REPLY_VOICE_RUNTIME_STATE_MARKER);
      const runtimeStateEnd = updated.indexOf(
        REPLY_VOICE_RUNTIME_STATE_BLOCK_END_MARKER,
        runtimeStateStart,
      );
      if (runtimeStateEnd === -1) {
        throw new Error("reply voice runtime state block end marker not found");
      }
      updated = `${updated.slice(0, runtimeStateStart)}${REPLY_VOICE_RUNTIME_STATE_BLOCK}${updated.slice(
        runtimeStateEnd + REPLY_VOICE_RUNTIME_STATE_BLOCK_END_MARKER.length,
      )}`;
    } else if (updated.includes(REPLY_VOICE_RUNTIME_STATE_LEGACY_BLOCK)) {
      updated = updated.replace(REPLY_VOICE_RUNTIME_STATE_LEGACY_BLOCK, REPLY_VOICE_RUNTIME_STATE_BLOCK);
    } else if (updated.includes(REPLY_VOICE_RUNTIME_STATE_LEGACY_MARKER)) {
      updated = updated.replace(REPLY_VOICE_RUNTIME_STATE_LEGACY_MARKER, REPLY_VOICE_RUNTIME_STATE_BLOCK);
    } else {
      updated = insertAfterAnchor(
        updated,
        REPLY_VOICE_CANDIDATE_MARKER,
        REPLY_VOICE_RUNTIME_STATE_BLOCK,
        "reply voice runtime state defaults",
      );
    }
  }

  updated = upsertReplyVoiceMentionGuardBypass(updated);
  updated = upsertVoiceModeToggleBlock(updated);

  if (!updated.includes(REPLY_VOICE_FASTPATH_MARKER)) {
    updated = insertAfterAnchor(
      updated,
      REPLY_VOICE_FASTPATH_ANCHOR,
      REPLY_VOICE_FASTPATH_BLOCK,
      "reply voice fastpath block",
    );
  } else if (!updated.includes(REPLY_VOICE_MISSING_SCRIPT_HINT_MARKER)) {
    updated = replaceReplyVoiceFastpathBlock(updated);
  }

  updated = upsertNoFinalFallbackBlock(updated);

  updated = upsertReplyVoiceDispatcherCreateOptions(updated);
  updated = upsertReplyVoiceDispatchOptions(updated);

  return updated;
}

async function readOptionalFile(filePath) {
  try {
    return await readFile(filePath, "utf8");
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

async function writeWithOptionalBackup({ filePath, original, next }) {
  if (original !== null) {
    const backupPath = `${filePath}.bak`;
    try {
      await access(backupPath);
    } catch {
      await writeFile(backupPath, original, "utf8");
    }
  }

  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, next, "utf8");
}

export async function applyPatchToTargetRoot({
  targetRoot = DEFAULT_TARGET_ROOT,
  apply = false,
} = {}) {
  const botPath = path.join(targetRoot, "bot.ts");
  const replyDispatcherPath = path.join(targetRoot, "reply-dispatcher.ts");
  const replyVoiceCommandPath = path.join(targetRoot, "reply-voice-command.ts");
  const replyVoiceTtsPath = path.join(targetRoot, "reply-voice-tts.ts");

  const originalBot = await readFile(botPath, "utf8");
  const patchedBot = patchFeishuBotReplyVoiceSource(originalBot);
  const originalReplyDispatcher = await readFile(replyDispatcherPath, "utf8");
  const patchedReplyDispatcher = patchFeishuReplyDispatcherSource(originalReplyDispatcher);
  const originalReplyVoiceCommand = await readOptionalFile(replyVoiceCommandPath);
  const originalReplyVoiceTts = await readOptionalFile(replyVoiceTtsPath);

  const botChanged = patchedBot !== originalBot;
  const replyDispatcherChanged = patchedReplyDispatcher !== originalReplyDispatcher;
  const replyVoiceCommandChanged = originalReplyVoiceCommand !== REPLY_VOICE_COMMAND_TEMPLATE;
  const replyVoiceTtsChanged = originalReplyVoiceTts !== REPLY_VOICE_TTS_TEMPLATE;
  const changed = botChanged || replyDispatcherChanged || replyVoiceCommandChanged || replyVoiceTtsChanged;

  if (apply && changed) {
    if (botChanged) {
      await writeWithOptionalBackup({
        filePath: botPath,
        original: originalBot,
        next: patchedBot,
      });
    }
    if (replyDispatcherChanged) {
      await writeWithOptionalBackup({
        filePath: replyDispatcherPath,
        original: originalReplyDispatcher,
        next: patchedReplyDispatcher,
      });
    }
    if (replyVoiceCommandChanged) {
      await writeWithOptionalBackup({
        filePath: replyVoiceCommandPath,
        original: originalReplyVoiceCommand,
        next: REPLY_VOICE_COMMAND_TEMPLATE,
      });
    }
    if (replyVoiceTtsChanged) {
      await writeWithOptionalBackup({
        filePath: replyVoiceTtsPath,
        original: originalReplyVoiceTts,
        next: REPLY_VOICE_TTS_TEMPLATE,
      });
    }
  }

  return {
    targetRoot,
    botPath,
    replyDispatcherPath,
    replyVoiceCommandPath,
    replyVoiceTtsPath,
    changed,
    apply,
    files: {
      botChanged,
      replyDispatcherChanged,
      replyVoiceCommandChanged,
      replyVoiceTtsChanged,
    },
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

  return { targetRoot, apply };
}

const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const options = parseCliArgs(process.argv.slice(2));
  const result = await applyPatchToTargetRoot(options);
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
