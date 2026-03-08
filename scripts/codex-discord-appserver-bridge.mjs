#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const DEFAULT_CHANNEL = process.env.CODEX_DISCORD_BRIDGE_CHANNEL || "discord";
const DEFAULT_TARGET = process.env.CODEX_DISCORD_BRIDGE_TARGET || "1480021215044440145";
const DEFAULT_ALLOWED_USERS = String(process.env.CODEX_DISCORD_BRIDGE_ALLOWED_USERS || "1088114536579616898")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);
const DEFAULT_CODEX_BIN = process.env.CODEX_DISCORD_BRIDGE_CODEX_BIN || "codex";
const DEFAULT_OPENCLAW_BIN = process.env.CODEX_DISCORD_BRIDGE_OPENCLAW_BIN || "openclaw";
const DEFAULT_POLL_MS = Number(process.env.CODEX_DISCORD_BRIDGE_POLL_MS || "2500");
const DEFAULT_RECENT_TTL_MS = Number(process.env.CODEX_DISCORD_BRIDGE_RECENT_TTL_MS || `${30 * 60 * 1000}`);
const DEFAULT_PENDING_FILE = process.env.CODEX_DISCORD_BRIDGE_PENDING_FILE
  || path.join(process.env.HOME || os.homedir(), ".codex", "tmp", "discord-appserver-bridge-state.json");
const DEFAULT_LOG_FILE = process.env.CODEX_DISCORD_BRIDGE_LOG_FILE
  || path.join(process.env.HOME || os.homedir(), ".codex", "log", "discord-appserver-bridge.log");
const ACTIVE_STATUSES = new Set(["awaiting_send", "waiting_reply"]);
const CLOSED_STATUSES = new Set(["answered_client", "answered_discord", "resolved_client", "resolved_discord", "stale"]);

function normalizeWhitespace(value) {
  return String(value || "").replace(/\r/g, "").trim();
}

function ensureArray(value) {
  return Array.isArray(value) ? value : [];
}

function nowIso() {
  return new Date().toISOString();
}

function isDigitsOnly(value) {
  return typeof value === "string" && /^\d+$/.test(value);
}

function compareMessageIds(left, right) {
  const a = String(left || "");
  const b = String(right || "");
  if (!a && !b) return 0;
  if (!a) return -1;
  if (!b) return 1;
  if (isDigitsOnly(a) && isDigitsOnly(b)) {
    const bigA = BigInt(a);
    const bigB = BigInt(b);
    return bigA === bigB ? 0 : bigA > bigB ? 1 : -1;
  }
  return a.localeCompare(b);
}

function pickFirst(...values) {
  for (const value of values) {
    if (value === undefined || value === null) continue;
    if (typeof value === "string" && value.trim() === "") continue;
    return value;
  }
  return null;
}

export function extractJsonObject(raw) {
  const text = String(raw || "");
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error("未找到 JSON 对象");
  }
  return JSON.parse(text.slice(start, end + 1));
}

export function createReplyToken(input) {
  const raw = JSON.stringify(input || {});
  return crypto.createHash("sha1").update(raw).digest("hex").slice(0, 6).toUpperCase();
}

function normalizeQuestion(question) {
  return {
    id: normalizeWhitespace(question?.id),
    header: normalizeWhitespace(question?.header),
    question: normalizeWhitespace(question?.question),
    isOther: question?.isOther === true,
    isSecret: question?.isSecret === true,
    options: Array.isArray(question?.options)
      ? question.options
          .map((option) => ({
            label: normalizeWhitespace(option?.label),
            description: normalizeWhitespace(option?.description),
          }))
          .filter((option) => option.label)
      : null,
  };
}

function normalizeQuestions(questions) {
  return ensureArray(questions).map(normalizeQuestion).filter((question) => question.id);
}

function formatOption(option, index) {
  const suffix = option.description ? ` — ${option.description}` : "";
  return `  ${index}. ${option.label}${suffix}`;
}

export function buildRequestUserInputBody(request) {
  const questions = normalizeQuestions(request?.questions);
  const token = normalizeWhitespace(request?.token) || createReplyToken(request);
  const lines = [];

  lines.push("等待回答：Codex request_user_input");
  lines.push(`request_id: ${request?.requestId ?? "-"}`);
  lines.push(`thread_id: ${request?.threadId || "-"}`);
  lines.push(`turn_id: ${request?.turnId || "-"}`);
  lines.push(`item_id: ${request?.itemId || "-"}`);
  lines.push("");

  for (const question of questions) {
    lines.push(`- ${question.header || question.id}`);
    lines.push(`  question_id: ${question.id}`);
    lines.push(`  问题: ${question.question || "-"}`);
    if (Array.isArray(question.options) && question.options.length > 0) {
      lines.push("  选项:");
      question.options.forEach((option, index) => {
        lines.push(formatOption(option, index + 1));
      });
    } else if (question.isSecret) {
      lines.push("  选项: 保密输入");
    } else {
      lines.push("  选项: 自由文本");
    }
  }

  lines.push("");
  lines.push(`回复口令: ${token}`);
  lines.push("回复说明：优先直接回复这条消息；若 reply context 缺失，请带上上面的回复口令。");
  lines.push("接受格式：选项序号、完整选项标签，或 `isOther=true` 场景下的自由文本。");
  if (questions.length <= 1) {
    const onlyQuestion = questions[0];
    if (onlyQuestion) {
      lines.push("示例:");
      lines.push(`- ${token}`);
      lines.push("  1");
      lines.push(`- ${onlyQuestion.id}: 1`);
      if (onlyQuestion.isOther || !onlyQuestion.options || onlyQuestion.options.length === 0) {
        lines.push(`- ${onlyQuestion.id}: 你的自由文本`);
      }
    }
  } else {
    lines.push("多题请逐行回复，格式固定为 question_id: answer");
    lines.push(`- ${token}`);
    for (const question of questions) {
      const answerHint = question.options?.length ? "选项序号/完整标签" : "你的回答";
      lines.push(`- ${question.id}: ${answerHint}`);
    }
  }

  return lines.join("\n");
}

function resolveOptionAnswer(question, rawAnswer) {
  const answer = normalizeWhitespace(rawAnswer);
  if (!answer) {
    throw new Error(`问题 ${question.id} 缺少回答`);
  }

  if (!Array.isArray(question.options) || question.options.length === 0) {
    return answer;
  }

  const numeric = Number(answer);
  if (Number.isInteger(numeric) && numeric >= 1 && numeric <= question.options.length) {
    return question.options[numeric - 1].label;
  }

  const byLabel = question.options.find((option) => option.label.toLowerCase() === answer.toLowerCase());
  if (byLabel) {
    return byLabel.label;
  }

  if (question.isOther) {
    return answer;
  }

  throw new Error(`问题 ${question.id} 的回答不在选项内`);
}

function stripToken(content, token) {
  const normalized = String(content || "").replace(/\r/g, "");
  const lines = normalized.split("\n");
  let removed = false;
  const kept = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!removed && trimmed === token) {
      removed = true;
      continue;
    }
    kept.push(line);
  }
  return { body: kept.join("\n").trim(), tokenMatched: removed || normalized.includes(token) };
}

export function parseDiscordReply({ content, pending, replyToMessageId }) {
  const questions = normalizeQuestions(pending?.questions);
  const token = normalizeWhitespace(pending?.token) || createReplyToken(pending);
  const { body, tokenMatched } = stripToken(content, token);
  const hasReplyContext = replyToMessageId && String(replyToMessageId) === String(pending?.discordMessageId || "");

  if (!tokenMatched && !hasReplyContext) {
    throw new Error("未匹配到回复口令或通知消息引用");
  }

  const lines = body.split("\n").map((line) => line.trim()).filter(Boolean);
  const answers = {};

  if (questions.length <= 1) {
    const question = questions[0];
    if (!question) {
      throw new Error("缺少待回答问题");
    }

    let rawAnswer = lines.join("\n").trim();
    if (lines.length === 1 && lines[0].includes(":")) {
      const [candidateId, candidateAnswer] = lines[0].split(/:(.+)/, 2);
      if (normalizeWhitespace(candidateId) !== question.id) {
        throw new Error(`未知问题ID: ${candidateId}`);
      }
      rawAnswer = normalizeWhitespace(candidateAnswer);
    } else if (lines.length > 1) {
      const found = lines.find((line) => line.startsWith(`${question.id}:`));
      if (!found) {
        throw new Error(`问题 ${question.id} 缺少回答`);
      }
      rawAnswer = normalizeWhitespace(found.split(/:(.+)/, 2)[1]);
    }

    answers[question.id] = { answers: [resolveOptionAnswer(question, rawAnswer)] };
    return { token, answers };
  }

  for (const line of lines) {
    const parts = line.split(/:(.+)/, 2);
    if (parts.length !== 2) {
      throw new Error(`多题回复必须使用 question_id: answer 格式，错误行: ${line}`);
    }
    const questionId = normalizeWhitespace(parts[0]);
    const rawAnswer = normalizeWhitespace(parts[1]);
    if (answers[questionId]) {
      throw new Error(`重复回答 question_id: ${questionId}`);
    }
    const question = questions.find((entry) => entry.id === questionId);
    if (!question) {
      throw new Error(`未知问题ID: ${questionId}`);
    }
    answers[questionId] = { answers: [resolveOptionAnswer(question, rawAnswer)] };
  }

  for (const question of questions) {
    if (!answers[question.id]) {
      throw new Error(`问题 ${question.id} 缺少回答`);
    }
  }

  return { token, answers };
}

export function normalizeReadMessages(raw) {
  const source = raw?.payload?.messages || raw?.messages || [];
  if (!Array.isArray(source)) return [];
  return source
    .map((message) => ({
      id: String(pickFirst(message?.id, message?.messageId, message?.message_id) || ""),
      channelId: String(pickFirst(message?.channel_id, message?.channelId, message?.channel?.id) || ""),
      content: String(pickFirst(message?.content, message?.text, message?.message) || ""),
      authorId: String(pickFirst(message?.author?.id, message?.senderId, message?.authorId, message?.userId) || ""),
      isBot: Boolean(pickFirst(message?.author?.bot, message?.bot, false)),
      replyToMessageId: (() => {
        const rawId = pickFirst(
          message?.reply_to_id,
          message?.replyToId,
          message?.replyTo?.id,
          message?.message_reference?.message_id,
          message?.messageReference?.messageId,
          message?.referenced_message?.id,
          message?.referencedMessage?.id,
        );
        return rawId === null ? null : String(rawId);
      })(),
    }))
    .filter((message) => message.id && message.channelId);
}

export function extractSentMessageId(rawOutput) {
  try {
    const parsed = typeof rawOutput === "string" ? extractJsonObject(rawOutput) : rawOutput;
    const found = pickFirst(
      parsed?.payload?.result?.messageId,
      parsed?.payload?.result?.message_id,
      parsed?.payload?.result?.id,
      parsed?.payload?.messageId,
      parsed?.payload?.message_id,
      parsed?.payload?.id,
      parsed?.payload?.message?.id,
      parsed?.messageId,
      parsed?.message_id,
      parsed?.id,
    );
    return found === null ? null : String(found);
  } catch {
    return null;
  }
}

function createInitialState() {
  return {
    lastReadMessageId: null,
    requests: {},
  };
}

function isRecentRecord(record, ttlMs) {
  return Boolean(record) && Number(record.updatedAt || 0) > 0 && Date.now() - Number(record.updatedAt || 0) <= ttlMs;
}

export function findPendingRequest({ message, requests, recentTtlMs = DEFAULT_RECENT_TTL_MS }) {
  const records = Object.values(requests || {})
    .filter(Boolean)
    .sort((left, right) => Number(right.createdAt || 0) - Number(left.createdAt || 0));

  if (message?.replyToMessageId) {
    const byReply = records.find((record) => String(record.discordMessageId || "") === String(message.replyToMessageId));
    if (byReply) {
      return byReply;
    }
  }

  const content = String(message?.content || "");
  const tokenMatches = records.filter((record) => record.token && content.includes(record.token));
  if (tokenMatches.length === 0) {
    return null;
  }

  tokenMatches.sort((left, right) => {
    const leftWeight = ACTIVE_STATUSES.has(left.status) ? 2 : isRecentRecord(left, recentTtlMs) ? 1 : 0;
    const rightWeight = ACTIVE_STATUSES.has(right.status) ? 2 : isRecentRecord(right, recentTtlMs) ? 1 : 0;
    if (leftWeight !== rightWeight) return rightWeight - leftWeight;
    return Number(right.createdAt || 0) - Number(left.createdAt || 0);
  });
  return tokenMatches[0] || null;
}

async function ensureParent(filePath) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
}

async function readJsonFile(filePath, fallback) {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

async function writeJsonAtomic(filePath, payload) {
  await ensureParent(filePath);
  const tempPath = `${filePath}.tmp`;
  await fs.writeFile(tempPath, JSON.stringify(payload, null, 2));
  await fs.rename(tempPath, filePath);
}

async function runCommand(cmd, args, options = {}) {
  const captureDir = await fs.mkdtemp(path.join(os.tmpdir(), "codex-discord-bridge-cmd-"));
  const stdoutPath = path.join(captureDir, "stdout.log");
  const stderrPath = path.join(captureDir, "stderr.log");
  const stdoutHandle = await fs.open(stdoutPath, "w");
  const stderrHandle = await fs.open(stderrPath, "w");

  try {
    return await new Promise((resolve) => {
      const child = spawn(cmd, args, {
        stdio: ["ignore", stdoutHandle.fd, stderrHandle.fd],
        ...options,
      });

      child.on("close", async (code) => {
        const [stdout, stderr] = await Promise.all([
          fs.readFile(stdoutPath, "utf8").catch(() => ""),
          fs.readFile(stderrPath, "utf8").catch(() => ""),
        ]);
        resolve({ ok: code === 0, code: code ?? 1, stdout, stderr, output: `${stdout}${stderr}` });
      });

      child.on("error", async (error) => {
        const [stdout, stderr] = await Promise.all([
          fs.readFile(stdoutPath, "utf8").catch(() => ""),
          fs.readFile(stderrPath, "utf8").catch(() => ""),
        ]);
        resolve({ ok: false, code: 1, stdout, stderr: `${stderr}${String(error)}`, output: `${stdout}${stderr}${String(error)}` });
      });
    });
  } finally {
    await stdoutHandle.close().catch(() => {});
    await stderrHandle.close().catch(() => {});
    await fs.rm(captureDir, { recursive: true, force: true }).catch(() => {});
  }
}

function hasCodexListenArg(codexArgs) {
  return codexArgs.some((arg, index) => arg === "--listen" || (index > 0 && codexArgs[index - 1] === "--listen") || arg.startsWith("--listen="));
}

function parseCliArgs(argv) {
  const options = {
    channel: DEFAULT_CHANNEL,
    target: DEFAULT_TARGET,
    allowedUsers: DEFAULT_ALLOWED_USERS,
    codexBin: DEFAULT_CODEX_BIN,
    openclawBin: DEFAULT_OPENCLAW_BIN,
    pollMs: DEFAULT_POLL_MS,
    recentTtlMs: DEFAULT_RECENT_TTL_MS,
    pendingFile: DEFAULT_PENDING_FILE,
    logFile: DEFAULT_LOG_FILE,
    codexArgs: ["app-server"],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--channel") {
      options.channel = argv[index + 1] || options.channel;
      index += 1;
      continue;
    }
    if (arg === "--target") {
      options.target = argv[index + 1] || options.target;
      index += 1;
      continue;
    }
    if (arg === "--allowed-user" || arg === "--allowed-users") {
      const raw = argv[index + 1] || "";
      options.allowedUsers = String(raw).split(",").map((value) => value.trim()).filter(Boolean);
      index += 1;
      continue;
    }
    if (arg === "--codex-bin") {
      options.codexBin = argv[index + 1] || options.codexBin;
      index += 1;
      continue;
    }
    if (arg === "--openclaw-bin") {
      options.openclawBin = argv[index + 1] || options.openclawBin;
      index += 1;
      continue;
    }
    if (arg === "--poll-ms") {
      options.pollMs = Number(argv[index + 1] || options.pollMs);
      index += 1;
      continue;
    }
    if (arg === "--recent-ttl-ms") {
      options.recentTtlMs = Number(argv[index + 1] || options.recentTtlMs);
      index += 1;
      continue;
    }
    if (arg === "--pending-file") {
      options.pendingFile = argv[index + 1] || options.pendingFile;
      index += 1;
      continue;
    }
    if (arg === "--log-file") {
      options.logFile = argv[index + 1] || options.logFile;
      index += 1;
      continue;
    }
    if (arg === "--") {
      options.codexArgs.push(...argv.slice(index + 1));
      break;
    }
    options.codexArgs.push(arg);
  }

  options.allowedUsers = options.allowedUsers.map((value) => String(value).trim()).filter(Boolean);
  if (!hasCodexListenArg(options.codexArgs)) {
    options.codexArgs.push("--listen", "stdio://");
  }
  return options;
}

export class DiscordAppServerBridge {
  constructor(options) {
    this.channel = options.channel;
    this.target = String(options.target);
    this.allowedUserIds = new Set(options.allowedUsers.map((value) => String(value)));
    this.codexBin = options.codexBin;
    this.codexArgs = options.codexArgs;
    this.openclawBin = options.openclawBin;
    this.pollMs = Math.max(250, Number(options.pollMs) || DEFAULT_POLL_MS);
    this.recentTtlMs = Math.max(1000, Number(options.recentTtlMs) || DEFAULT_RECENT_TTL_MS);
    this.pendingFile = options.pendingFile;
    this.logFile = options.logFile;
    this.state = createInitialState();
    this.child = null;
    this.stopped = false;
    this.pollTimer = null;
    this.saveQueue = Promise.resolve();
  }

  async init() {
    await ensureParent(this.pendingFile);
    await ensureParent(this.logFile);
    this.state = await readJsonFile(this.pendingFile, createInitialState());
    if (!this.state || typeof this.state !== "object" || typeof this.state.requests !== "object") {
      this.state = createInitialState();
    }
    await this.pruneOldRequests();
    await this.persistState();
  }

  async log(level, message) {
    const line = `[${nowIso()}] ${level} ${message}\n`;
    await fs.appendFile(this.logFile, line).catch(() => {});
  }

  async persistState() {
    this.saveQueue = this.saveQueue.then(() => writeJsonAtomic(this.pendingFile, this.state));
    await this.saveQueue;
  }

  async start() {
    await this.init();
    await this.spawnChild();
    this.startPoller();
    await this.pumpLines();
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    await this.persistState().catch(() => {});
  }

  async spawnChild() {
    this.child = spawn(this.codexBin, this.codexArgs, {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });

    this.child.stderr.on("data", (chunk) => {
      process.stderr.write(chunk);
    });

    this.child.on("exit", (code, signal) => {
      void this.stop();
      process.exitCode = code ?? (signal ? 1 : 0);
      process.exit(process.exitCode);
    });
  }

  startPoller() {
    this.pollTimer = setInterval(() => {
      void this.pollDiscordReplies().catch((error) => {
        void this.log("ERROR", `poll failed: ${error?.stack || error}`);
      });
    }, this.pollMs);
    this.pollTimer.unref?.();
  }

  async pumpLines() {
    const stdinRl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
    const stdoutRl = readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity });

    const stdinLoop = (async () => {
      for await (const line of stdinRl) {
        await this.handleClientLine(line);
      }
    })();

    const stdoutLoop = (async () => {
      for await (const line of stdoutRl) {
        await this.handleServerLine(line);
      }
    })();

    await stdoutLoop;
    await stdinLoop;
  }

  async handleClientLine(line) {
    let parsed = null;
    try {
      parsed = JSON.parse(line);
    } catch {
      parsed = null;
    }

    if (parsed && !parsed.method && Object.prototype.hasOwnProperty.call(parsed, "id")) {
      const requestKey = String(parsed.id);
      const record = this.state.requests[requestKey];
      if (record && ACTIVE_STATUSES.has(record.status)) {
        record.status = "answered_client";
        record.resolutionReason = "client_response";
        record.updatedAt = Date.now();
        await this.persistState();
        await this.log("INFO", `client answered request=${requestKey}`);
      }
    }

    if (!this.child.stdin.destroyed) {
      this.child.stdin.write(`${line}\n`);
    }
  }

  async handleServerLine(line) {
    let parsed = null;
    try {
      parsed = JSON.parse(line);
    } catch {
      parsed = null;
    }

    if (parsed?.method === "item/tool/requestUserInput" && Object.prototype.hasOwnProperty.call(parsed, "id")) {
      await this.registerRequestUserInput(parsed);
    } else if (parsed?.method === "serverRequest/resolved") {
      await this.markResolved(parsed?.params?.requestId, "serverRequest/resolved");
    }

    process.stdout.write(`${line}\n`);
  }

  async registerRequestUserInput(message) {
    const params = message?.params || {};
    const requestKey = String(message.id);
    const record = {
      requestId: message.id,
      requestKey,
      threadId: normalizeWhitespace(params.threadId),
      turnId: normalizeWhitespace(params.turnId),
      itemId: normalizeWhitespace(params.itemId),
      questions: normalizeQuestions(params.questions),
      token: createReplyToken({
        requestId: message.id,
        threadId: params.threadId,
        turnId: params.turnId,
        itemId: params.itemId,
        questions: normalizeQuestions(params.questions),
      }),
      status: "awaiting_send",
      discordMessageId: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      resolutionReason: null,
      lastInboundMessageId: null,
      channelId: this.target,
    };
    this.state.requests[requestKey] = record;
    await this.persistState();
    await this.log("INFO", `registered request_user_input request=${requestKey} thread=${record.threadId || "-"}`);
    void this.sendDiscordPrompt(requestKey);
  }

  async sendDiscordPrompt(requestKey) {
    const record = this.state.requests[requestKey];
    if (!record) return;

    const message = buildRequestUserInputBody({
      requestId: record.requestId,
      threadId: record.threadId,
      turnId: record.turnId,
      itemId: record.itemId,
      questions: record.questions,
      token: record.token,
    });
    const preSendCursor = String(this.state.lastReadMessageId || "0");

    const result = await runCommand(this.openclawBin, [
      "message",
      "send",
      "--channel",
      this.channel,
      "--target",
      this.target,
      "--message",
      message,
      "--json",
    ]);

    if (!result.ok) {
      await this.log("ERROR", `prompt send failed request=${requestKey} output=${result.output.replace(/\s+/g, " ").trim()}`);
      return;
    }

    record.discordMessageId = extractSentMessageId(result.output);
    const recoveredDiscordMessageId = await this.recoverSentPromptMessageId({
      extractedId: record.discordMessageId,
      preSendCursor,
      requestId: record.requestId,
    });
    if (recoveredDiscordMessageId) {
      if (record.discordMessageId && recoveredDiscordMessageId !== record.discordMessageId) {
        await this.log("INFO", `prompt canonicalized discordMessageId=${recoveredDiscordMessageId} previous=${record.discordMessageId} request=${requestKey}`);
      } else if (!record.discordMessageId) {
        await this.log("INFO", `prompt recovered discordMessageId=${recoveredDiscordMessageId} request=${requestKey}`);
      }
      record.discordMessageId = recoveredDiscordMessageId;
    } else if (!record.discordMessageId) {
      await this.log("WARN", `prompt fallback token-only request=${requestKey}`);
    }

    if (!record.discordMessageId) {
      await this.log("INFO", `prompt sent without messageId; request=${requestKey}`);
    } else if (!this.state.lastReadMessageId) {
      this.state.lastReadMessageId = record.discordMessageId;
    }
    record.status = "waiting_reply";
    record.updatedAt = Date.now();
    await this.persistState();
    await this.log("INFO", `prompt sent request=${requestKey} discordMessageId=${record.discordMessageId || "-"}`);
  }

  async recoverSentPromptMessageId({ extractedId, preSendCursor, requestId }) {
    const args = [
      "message",
      "read",
      "--channel",
      this.channel,
      "--target",
      this.target,
    ];

    if (extractedId) {
      args.push("--around", String(extractedId));
    } else {
      await this.log("INFO", `prompt sent without messageId; attempting read-back recovery request=${requestId} after=${preSendCursor}`);
      args.push("--after", String(preSendCursor || "0"));
    }
    args.push("--json");

    const result = await runCommand(this.openclawBin, args);

    if (!result.ok) {
      await this.log("WARN", `prompt recovery read failed output=${result.output.replace(/\s+/g, " ").trim()}`);
      return null;
    }

    let parsed;
    try {
      parsed = extractJsonObject(result.output);
    } catch (error) {
      await this.log("WARN", `prompt recovery read parse failed: ${error?.message || error}`);
      return null;
    }

    const promptMatches = normalizeReadMessages(parsed)
      .filter((message) => (
        String(message.channelId) === String(this.target)
        && message.isBot === true
        && String(message.content || "").startsWith("等待回答：Codex request_user_input")
        && String(message.content || "").includes(`request_id: ${requestId}`)
      ))
      .sort((left, right) => compareMessageIds(left.id, right.id));

    if (extractedId) {
      const nearestPreceding = [...promptMatches]
        .reverse()
        .find((message) => compareMessageIds(message.id, String(extractedId)) <= 0);
      if (nearestPreceding?.id) {
        return String(nearestPreceding.id);
      }

      const nearestFollowing = promptMatches
        .find((message) => compareMessageIds(message.id, String(extractedId)) > 0);
      return nearestFollowing?.id ? String(nearestFollowing.id) : null;
    }

    const matched = promptMatches
      .find((message) => compareMessageIds(message.id, String(preSendCursor || "0")) > 0);
    return matched?.id ? String(matched.id) : null;
  }

  async sendDiscordReply(message, { replyTo } = {}) {
    const args = [
      "message",
      "send",
      "--channel",
      this.channel,
      "--target",
      this.target,
      "--message",
      message,
      "--json",
    ];
    if (replyTo) {
      args.push("--reply-to", String(replyTo));
    }
    const result = await runCommand(this.openclawBin, args);
    if (!result.ok) {
      await this.log("ERROR", `discord reply failed output=${result.output.replace(/\s+/g, " ").trim()}`);
    }
    return result;
  }

  async markResolved(requestId, reason) {
    if (requestId === undefined || requestId === null) return;
    const requestKey = String(requestId);
    const record = this.state.requests[requestKey];
    if (!record) return;

    if (record.status === "answered_discord") {
      record.status = "resolved_discord";
    } else if (record.status === "answered_client") {
      record.status = "resolved_client";
    } else if (ACTIVE_STATUSES.has(record.status)) {
      record.status = "stale";
    }

    record.resolutionReason = reason;
    record.updatedAt = Date.now();
    await this.persistState();
    await this.log("INFO", `resolved request=${requestKey} status=${record.status} reason=${reason}`);
  }

  async pruneOldRequests() {
    let changed = false;
    for (const [key, record] of Object.entries(this.state.requests || {})) {
      if (!record) continue;
      if (!CLOSED_STATUSES.has(record.status)) continue;
      if (!isRecentRecord(record, this.recentTtlMs)) {
        delete this.state.requests[key];
        changed = true;
      }
    }
    if (changed) {
      await this.persistState();
    }
  }

  async pollDiscordReplies() {
    if (this.stopped) return;
    const records = Object.values(this.state.requests || {});
    const interesting = records.some((record) => ACTIVE_STATUSES.has(record.status) || isRecentRecord(record, this.recentTtlMs));
    if (!interesting) {
      await this.pruneOldRequests();
      return;
    }

    const after = this.state.lastReadMessageId || records.find((record) => record.discordMessageId)?.discordMessageId || "0";
    const result = await runCommand(this.openclawBin, [
      "message",
      "read",
      "--channel",
      this.channel,
      "--target",
      this.target,
      "--after",
      String(after),
      "--json",
    ]);

    if (!result.ok) {
      await this.log("ERROR", `discord read failed output=${result.output.replace(/\s+/g, " ").trim()}`);
      return;
    }

    let parsed;
    try {
      parsed = extractJsonObject(result.output);
    } catch (error) {
      await this.log("ERROR", `discord read parse failed: ${error?.message || error}`);
      return;
    }

    const messages = normalizeReadMessages(parsed).sort((left, right) => compareMessageIds(left.id, right.id));
    let cursor = this.state.lastReadMessageId;

    for (const message of messages) {
      if (!cursor || compareMessageIds(message.id, cursor) > 0) {
        cursor = message.id;
      }
      await this.processInboundDiscordMessage(message);
    }

    if (cursor && cursor !== this.state.lastReadMessageId) {
      this.state.lastReadMessageId = cursor;
      await this.persistState();
    }

    await this.pruneOldRequests();
  }

  async processInboundDiscordMessage(message) {
    const record = findPendingRequest({
      message,
      requests: this.state.requests,
      recentTtlMs: this.recentTtlMs,
    });
    if (!record) {
      return;
    }

    if (String(message.channelId) !== String(this.target)) {
      return;
    }

    if (message.isBot) {
      return;
    }

    if (!this.allowedUserIds.has(String(message.authorId))) {
      await this.sendDiscordReply("该回复账号不在允许名单内，已忽略。", { replyTo: message.id });
      await this.log("WARN", `ignored unauthorized reply request=${record.requestKey} author=${message.authorId}`);
      return;
    }

    if (ACTIVE_STATUSES.has(record.status)) {
      try {
        const parsed = parseDiscordReply({
          content: message.content,
          pending: record,
          replyToMessageId: message.replyToMessageId,
        });
        await this.respondToServerRequest(record, parsed.answers, message.id);
      } catch (error) {
        await this.sendDiscordReply(`回复无效：${error?.message || error}`, { replyTo: message.id });
        await this.log("WARN", `invalid discord reply request=${record.requestKey} msg=${message.id} error=${error?.message || error}`);
      }
      return;
    }

    const text = record.status === "stale" ? "已失效，请等待最新问题" : "已处理/已过期";
    await this.sendDiscordReply(text, { replyTo: message.id });
  }

  async respondToServerRequest(record, answers, sourceMessageId) {
    const payload = { id: record.requestId, result: { answers } };
    if (!this.child?.stdin || this.child.stdin.destroyed) {
      record.status = "stale";
      record.resolutionReason = "child_stdin_closed";
      record.updatedAt = Date.now();
      await this.persistState();
      await this.sendDiscordReply("已失效，请等待最新问题", { replyTo: sourceMessageId });
      return;
    }

    this.child.stdin.write(`${JSON.stringify(payload)}\n`);
    record.status = "answered_discord";
    record.resolutionReason = "discord_response";
    record.updatedAt = Date.now();
    record.lastInboundMessageId = String(sourceMessageId);
    await this.persistState();
    await this.sendDiscordReply(`已收到回答，正在回填 Codex。request_id=${record.requestKey}`, {
      replyTo: record.discordMessageId || sourceMessageId,
    });
    await this.log("INFO", `discord answered request=${record.requestKey} sourceMessageId=${sourceMessageId}`);
  }
}

async function main() {
  const options = parseCliArgs(process.argv.slice(2));
  const bridge = new DiscordAppServerBridge(options);
  await bridge.start();
}

const isDirectRun = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isDirectRun) {
  main().catch((error) => {
    process.stderr.write(`${error?.stack || error}\n`);
    process.exit(1);
  });
}
