#!/usr/bin/env node
import crypto from "node:crypto";

function normalizeWhitespace(value) {
  return String(value || "").replace(/\r/g, "").trim();
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
      ? question.options.map((option) => ({
          label: normalizeWhitespace(option?.label),
          description: normalizeWhitespace(option?.description),
        })).filter((option) => option.label)
      : null,
  };
}

function formatOption(option, index) {
  const suffix = option.description ? ` — ${option.description}` : "";
  return `  ${index}. ${option.label}${suffix}`;
}

export function buildRequestUserInputBody(request) {
  const questions = Array.isArray(request?.questions) ? request.questions.map(normalizeQuestion).filter((question) => question.id) : [];
  const token = normalizeWhitespace(request?.token) || createReplyToken(request);
  const lines = [];

  lines.push("等待回答：");
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
  lines.push("回复格式:");
  if (questions.length <= 1) {
    const onlyQuestion = questions[0];
    if (onlyQuestion) {
      lines.push(`- ${token}`);
      lines.push(`- ${onlyQuestion.id}: 1`);
      if (onlyQuestion.isOther || !onlyQuestion.options || onlyQuestion.options.length === 0) {
        lines.push(`- ${onlyQuestion.id}: 你的自由文本`);
      }
    } else {
      lines.push(`- ${token}`);
      lines.push("- question_id: 你的回答");
    }
  } else {
    lines.push(`- ${token}`);
    for (const question of questions) {
      lines.push(`- ${question.id}: ${question.options?.length ? "选项序号/完整标签" : "你的回答"}`);
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
  const questions = Array.isArray(pending?.questions) ? pending.questions.map(normalizeQuestion).filter((question) => question.id) : [];
  const token = normalizeWhitespace(pending?.token) || createReplyToken(pending);
  const { body, tokenMatched } = stripToken(content, token);

  if (!tokenMatched && !(replyToMessageId && String(replyToMessageId) === String(pending?.discordMessageId || ""))) {
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

export function normalizeReadMessages(raw) {
  const source = raw?.payload?.messages || raw?.messages || [];
  if (!Array.isArray(source)) return [];
  return source.map((message) => ({
    id: String(pickFirst(message?.id, message?.messageId, message?.message_id) || ""),
    channelId: String(pickFirst(message?.channel_id, message?.channelId, message?.channel?.id) || ""),
    content: String(pickFirst(message?.content, message?.text, message?.message) || ""),
    authorId: String(pickFirst(message?.author?.id, message?.senderId, message?.authorId, message?.userId) || ""),
    isBot: Boolean(pickFirst(message?.author?.bot, message?.bot, false)),
    replyToMessageId: pickFirst(
      message?.reply_to_id,
      message?.replyToId,
      message?.replyTo?.id,
      message?.message_reference?.message_id,
      message?.messageReference?.messageId,
      message?.referenced_message?.id,
      message?.referencedMessage?.id,
    ),
  })).filter((message) => message.id && message.channelId);
}

export function extractSentMessageId(rawOutput) {
  try {
    const parsed = typeof rawOutput === "string" ? extractJsonObject(rawOutput) : rawOutput;
    return pickFirst(
      parsed?.payload?.messageId,
      parsed?.payload?.message_id,
      parsed?.payload?.id,
      parsed?.payload?.message?.id,
      parsed?.messageId,
      parsed?.message_id,
      parsed?.id,
    );
  } catch {
    return null;
  }
}
