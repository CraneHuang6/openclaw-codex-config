import path from "node:path";
import { access, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const DEFAULT_TARGET_ROOT = "/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src";
const MEDIA_IMPORT_STATEMENT = 'import { sendMediaFeishu } from "./media.js";';
const SEND_IMPORT_PATTERN =
  /import\s+\{\s*(?:sendMarkdownCardFeishu,\s*sendMessageFeishu|sendMessageFeishu,\s*sendMarkdownCardFeishu)\s*\}\s+from\s+"\.\/send\.js";/m;
const HELPER_INSERT_ANCHOR = "export function createFeishuReplyDispatcher(";
const TEXT_MEDIA_FALLBACK_HELPER_PATTERN = /function\s+extractMediaUrlsFromTextFallback\s*\(/m;
const VOICE_HELPER_INSERT_ANCHOR = "function extractMediaUrlsFromTextFallback(text) {";
const DELIVER_FALLBACK_MARKER = "const fallback = extractMediaUrlsFromTextFallback(originalText);";
const DELIVER_BLOCK_SUPPRESSION_MARKER = 'if (info?.kind === "block") {';
const DELIVER_NO_FINAL_CANDIDATE_MARKER = "__openclawFeishuNoFinalTextCandidate";
const DELIVER_OUTBOUND_DELIVERY_MARKER = "__openclawFeishuHadOutboundDelivery";
const DELIVER_MEDIA_DELIVERY_MARKER = "__openclawFeishuHadMediaDelivery";
const DELIVER_DISPATCHER_STATE_BINDING_MARKER = "const dispatcherState = dispatcher as {";
const DELIVER_DISPATCHER_STATE_MIRROR_MARKER = "__openclawFeishuDispatcherStateMirror";
const DELIVER_VOICE_ERROR_RE_MARKER = "VOICE_ERROR_TEXT_RE";
const DELIVER_VOICE_PREFER_TEXT_MARKER = "shouldPreferTextDeliveryInVoiceMode";
const DELIVER_VOICE_FALLBACK_SEND_FAILED_MARKER = "voice fallback send failed";
const DELIVER_BLOCK_PATTERN =
  /deliver:\s*async\s*\(payload:\s*ReplyPayload,\s*info\)\s*=>\s*\{[\s\S]*?\n\s*\},\n\s*onError:/m;
const DISPATCHER_PARAMS_TYPE_ALIAS_PATTERN =
  /export\s+type\s+CreateFeishuReplyDispatcherParams\s*=\s*\{[\s\S]*?\n\};/m;
const DISPATCHER_PARAMS_INTERFACE_PATTERN =
  /export\s+interface\s+CreateFeishuReplyDispatcherParams\s*\{[\s\S]*?\n\}/m;
const FORCE_VOICE_MODE_TTS_TYPE_FIELD = "  forceVoiceModeTts?: boolean;";
const STREAMING_ENABLED_OLD =
  'const streamingEnabled = account.config?.streaming !== false && renderMode !== "raw";';
const STREAMING_ENABLED_NEW =
  'const streamingEnabled = account.config?.streaming !== false && renderMode !== "raw" && !params.forceVoiceModeTts;';

const VOICE_TEXT_FALLBACK_HELPERS = `const VOICE_ERROR_TEXT_RE = /(?:这次没有生成语音回复|语音生成失败|voice fallback|tts|无法找到语音脚本)/i;

function shouldPreferTextDeliveryInVoiceMode(text) {
  const normalized = (text ?? "").trim();
  if (!normalized) {
    return false;
  }
  return VOICE_ERROR_TEXT_RE.test(normalized);
}
`;

const TEXT_MEDIA_FALLBACK_HELPERS = `${VOICE_TEXT_FALLBACK_HELPERS}
const MEDIA_PATH_LINE_RE = /^\\s*(?:Saved:\\s*)?(.+?)\\s*$/i;
const MEDIA_MARKDOWN_IMAGE_RE = /!\\[[^\\]]*]\\(([^)]+)\\)/;
const LOCAL_MEDIA_PATH_RE = /^(?:\\.{1,2}\\/|\\/|~\\/|[a-zA-Z]:[\\\\/]|\\\\\\\\)/;
const HTTP_MEDIA_URL_RE = /^https?:\\/\\//i;
const MEDIA_EXT_RE = /\\.(?:png|jpe?g|gif|webp|bmp|tiff|ico|svg|mp4|mov|avi|m4v|mp3|wav|ogg|opus|m4a)(?:[?#].*)?$/i;

function stripPathWrapper(raw) {
  return raw.trim().replace(/^[\`"']+/, "").replace(/[\`"']+$/, "");
}

function extractMediaUrlsFromTextFallback(text) {
  if (!text.trim()) {
    return { text, mediaUrls: [] };
  }

  const lines = text.split("\\n");
  const kept = [];
  const mediaUrls = [];
  let inFence = false;

  for (const line of lines) {
    if (/^\\s*\`\`\`/.test(line)) {
      inFence = !inFence;
      kept.push(line);
      continue;
    }

    if (inFence) {
      kept.push(line);
      continue;
    }

    let extracted = null;
    const markdownMatch = line.match(MEDIA_MARKDOWN_IMAGE_RE);
    if (markdownMatch?.[1]) {
      extracted = stripPathWrapper(markdownMatch[1]);
    } else {
      const directMatch = line.match(MEDIA_PATH_LINE_RE);
      const candidate = directMatch?.[1] ? stripPathWrapper(directMatch[1]) : "";
      if (candidate.startsWith("MEDIA:")) {
        extracted = stripPathWrapper(candidate.replace(/^MEDIA:\\s*/i, ""));
      } else if (
        candidate &&
        MEDIA_EXT_RE.test(candidate) &&
        (LOCAL_MEDIA_PATH_RE.test(candidate) || HTTP_MEDIA_URL_RE.test(candidate))
      ) {
        extracted = candidate;
      }
    }

    if (extracted) {
      mediaUrls.push(extracted);
      continue;
    }

    kept.push(line);
  }

  const deduped = Array.from(new Set(mediaUrls));
  const cleanedText = kept.join("\\n").replace(/\\n{3,}/g, "\\n\\n").trim();
  return { text: cleanedText, mediaUrls: deduped };
}
`;

const PATCHED_DELIVER_BLOCK = `deliver: async (payload: ReplyPayload, info) => {
        const originalText = payload.text ?? "";
        const fallback = extractMediaUrlsFromTextFallback(originalText);
        const text = fallback.text;
        const mediaUrls =
          payload.mediaUrls?.length
            ? payload.mediaUrls
            : payload.mediaUrl
              ? [payload.mediaUrl]
              : fallback.mediaUrls;
        const hasText = text.trim().length > 0;
        const canSendMedia = info?.kind === "final" || !info?.kind;
        const dedupState = params as {
          __openclawFeishuLastDeliveredTextForDedup?: string;
          __openclawFeishuLastDeliveredRawTextForDedup?: string;
          __openclawFeishuNoFinalTextCandidate?: () => string;
          __openclawFeishuHadOutboundDelivery?: () => boolean;
          __openclawFeishuHadMediaDelivery?: () => boolean;
          __openclawFeishuDispatcherStateMirror?: true;
        };
        const dispatcherState = dispatcher as {
          __openclawFeishuNoFinalTextCandidate?: () => string;
          __openclawFeishuHadOutboundDelivery?: () => boolean;
          __openclawFeishuHadMediaDelivery?: () => boolean;
          __openclawFeishuDispatcherStateMirror?: true;
        };
        dispatcherState.__openclawFeishuDispatcherStateMirror = true;
        const lastDeliveredTextForDedup =
          dedupState.__openclawFeishuLastDeliveredTextForDedup ?? null;
        const dedupNoFinalTextCandidate =
          (dedupState.__openclawFeishuNoFinalTextCandidate?.() ?? "").trim();
        const dispatcherNoFinalTextCandidate =
          (dispatcherState.__openclawFeishuNoFinalTextCandidate?.() ?? "").trim();
        let noFinalTextCandidate =
          dedupNoFinalTextCandidate.length > 0
            ? dedupNoFinalTextCandidate
            : dispatcherNoFinalTextCandidate;
        const dedupHadOutboundDelivery =
          dedupState.__openclawFeishuHadOutboundDelivery?.() === true;
        const dispatcherHadOutboundDelivery =
          dispatcherState.__openclawFeishuHadOutboundDelivery?.() === true;
        let hadOutboundDelivery = dedupHadOutboundDelivery || dispatcherHadOutboundDelivery;
        const dedupHadMediaDelivery = dedupState.__openclawFeishuHadMediaDelivery?.() === true;
        const dispatcherHadMediaDelivery =
          dispatcherState.__openclawFeishuHadMediaDelivery?.() === true;
        let hadMediaDelivery = dedupHadMediaDelivery || dispatcherHadMediaDelivery;

        try {
          if (!hasText && (!canSendMedia || mediaUrls.length === 0)) {
            return;
          }
          if (info?.kind === "block") {
            if (
              streamingEnabled &&
              (renderMode === "card" || (renderMode === "auto" && shouldUseCard(text)))
            ) {
              startStreaming();
            }
            return;
          }

          const useCard =
            hasText && (renderMode === "card" || (renderMode === "auto" && shouldUseCard(text)));

          if ((info?.kind === "block" || info?.kind === "final") && streamingEnabled && useCard) {
            startStreaming();
            if (streamingStartPromise) {
              await streamingStartPromise;
            }
          }

          let textDeliveredByStreaming = false;
          if (streaming?.isActive()) {
            if (info?.kind !== "final") {
              return;
            }
            streamText = text;
            await closeStreaming();
            textDeliveredByStreaming = true;
          }

          const normalizedSourceText = text.replace(/\\s+/g, " ").trim();
          const shouldSkipDuplicatedText =
            hasText &&
            normalizedSourceText.length > 0 &&
            lastDeliveredTextForDedup != null &&
            lastDeliveredTextForDedup === normalizedSourceText;

          let textToDeliver = text;
          let normalizedTextToDeliver = normalizedSourceText;
          const shouldTrimFinalPrefix =
            !shouldSkipDuplicatedText &&
            !textDeliveredByStreaming &&
            hasText &&
            info?.kind === "final" &&
            lastDeliveredTextForDedup != null &&
            normalizedSourceText.startsWith(lastDeliveredTextForDedup);

          if (shouldTrimFinalPrefix) {
            const lastDeliveredRawTextForDedup =
              dedupState.__openclawFeishuLastDeliveredRawTextForDedup ?? "";
            const trimmedCurrent = textToDeliver.trimStart();
            const trimmedLast = lastDeliveredRawTextForDedup.trim();

            if (trimmedLast && trimmedCurrent.startsWith(trimmedLast)) {
              textToDeliver = trimmedCurrent.slice(trimmedLast.length).trimStart();
            }

            normalizedTextToDeliver = textToDeliver.replace(/\\s+/g, " ").trim();
          }

          const hasTextToDeliver = normalizedTextToDeliver.length > 0;
          const suppressTextDelivery = params.forceVoiceModeTts === true;
          const preferTextDeliveryInVoiceMode =
            suppressTextDelivery && shouldPreferTextDeliveryInVoiceMode(textToDeliver);

          if (hasTextToDeliver && info?.kind === "final") {
            noFinalTextCandidate = textToDeliver.trim();
          }

          if (
            (!suppressTextDelivery || preferTextDeliveryInVoiceMode) &&
            !textDeliveredByStreaming &&
            hasTextToDeliver &&
            !shouldSkipDuplicatedText
          ) {
            let first = true;
            if (useCard) {
              for (const chunk of core.channel.text.chunkTextWithMode(
                textToDeliver,
                textChunkLimit,
                chunkMode,
              )) {
                await sendMarkdownCardFeishu({
                  cfg,
                  to: chatId,
                  text: chunk,
                  replyToMessageId,
                  mentions: first ? mentionTargets : undefined,
                  accountId,
                });
                hadOutboundDelivery = true;
                first = false;
              }
            } else {
              const converted = core.channel.text.convertMarkdownTables(textToDeliver, tableMode);
              for (const chunk of core.channel.text.chunkTextWithMode(
                converted,
                textChunkLimit,
                chunkMode,
              )) {
                await sendMessageFeishu({
                  cfg,
                  to: chatId,
                  text: chunk,
                  replyToMessageId,
                  mentions: first ? mentionTargets : undefined,
                  accountId,
                });
                hadOutboundDelivery = true;
                first = false;
              }
            }
          }

          if (
            hasText &&
            normalizedSourceText.length > 0 &&
            (!shouldSkipDuplicatedText || textDeliveredByStreaming)
          ) {
            dedupState.__openclawFeishuLastDeliveredTextForDedup = normalizedSourceText;
            dedupState.__openclawFeishuLastDeliveredRawTextForDedup = text;
          }
          if (textDeliveredByStreaming) {
            hadOutboundDelivery = true;
          }

          if (canSendMedia && mediaUrls.length > 0) {
            for (const mediaUrl of mediaUrls) {
              try {
                await sendMediaFeishu({
                  cfg,
                  to: chatId,
                  mediaUrl,
                  replyToMessageId,
                  accountId,
                });
                hadOutboundDelivery = true;
                hadMediaDelivery = true;
              } catch (error) {
                params.runtime.error?.(
                  \`feishu[\${account.accountId}] media send failed: \${String(error)}\`,
                );
                try {
                  await sendMessageFeishu({
                    cfg,
                    to: chatId,
                    text: \`Attachment: \${mediaUrl}\`,
                    replyToMessageId,
                    accountId,
                  });
                  hadOutboundDelivery = true;
                } catch (voiceFallbackErr) {
                  params.runtime.error?.(
                    \`feishu[\${account.accountId}] voice fallback send failed: \${String(voiceFallbackErr)}\`,
                  );
                }
              }
            }
          }
        } finally {
          dedupState.__openclawFeishuNoFinalTextCandidate = () => noFinalTextCandidate;
          dedupState.__openclawFeishuHadOutboundDelivery = () => hadOutboundDelivery;
          dedupState.__openclawFeishuHadMediaDelivery = () => hadMediaDelivery;
          dispatcherState.__openclawFeishuNoFinalTextCandidate = () => noFinalTextCandidate;
          dispatcherState.__openclawFeishuHadOutboundDelivery = () => hadOutboundDelivery;
          dispatcherState.__openclawFeishuHadMediaDelivery = () => hadMediaDelivery;
          dispatcherState.__openclawFeishuDispatcherStateMirror = true;
        }
      },
      onError:`;

function findFallbackHelperInsertIndex(source) {
  const exportIndex = source.search(/^export\s/m);
  if (exportIndex !== -1) {
    return exportIndex;
  }

  const constObjectIndex = source.search(/^\s*(?:const|let|var)\s+\w+\s*=\s*\{/m);
  if (constObjectIndex !== -1) {
    return constObjectIndex;
  }

  return -1;
}

function upsertForceVoiceModeTtsTypeField(source) {
  if (source.includes(FORCE_VOICE_MODE_TTS_TYPE_FIELD)) {
    return source;
  }

  const injectIntoTypeBlock = (block, closingPattern) => {
    if (/forceVoiceModeTts\??\s*:\s*boolean/.test(block)) {
      return block;
    }
    if (/(\n\s*accountId\??\s*:\s*string;\n)/.test(block)) {
      return block.replace(
        /(\n\s*accountId\??\s*:\s*string;\n)/,
        `$1${FORCE_VOICE_MODE_TTS_TYPE_FIELD}\n`,
      );
    }
    if (closingPattern.test(block)) {
      return block.replace(closingPattern, `\n${FORCE_VOICE_MODE_TTS_TYPE_FIELD}$&`);
    }
    return block;
  };

  const aliasMatch = source.match(DISPATCHER_PARAMS_TYPE_ALIAS_PATTERN);
  if (aliasMatch) {
    const updatedBlock = injectIntoTypeBlock(aliasMatch[0], /\n\};/);
    return source.replace(aliasMatch[0], updatedBlock);
  }

  const interfaceMatch = source.match(DISPATCHER_PARAMS_INTERFACE_PATTERN);
  if (interfaceMatch) {
    const updatedBlock = injectIntoTypeBlock(interfaceMatch[0], /\n\}/);
    return source.replace(interfaceMatch[0], updatedBlock);
  }

  return source;
}

export function patchFeishuReplyDispatcherSource(source) {
  let updated = source;

  updated = updated.replace(STREAMING_ENABLED_OLD, STREAMING_ENABLED_NEW);
  updated = upsertForceVoiceModeTtsTypeField(updated);

  if (!updated.includes(MEDIA_IMPORT_STATEMENT)) {
    if (!SEND_IMPORT_PATTERN.test(updated)) {
      throw new Error("send import anchor not found");
    }
    updated = updated.replace(SEND_IMPORT_PATTERN, `${MEDIA_IMPORT_STATEMENT}\n$&`);
  }

  if (!TEXT_MEDIA_FALLBACK_HELPER_PATTERN.test(updated)) {
    let anchorIndex = updated.indexOf(HELPER_INSERT_ANCHOR);
    if (anchorIndex === -1) {
      anchorIndex = findFallbackHelperInsertIndex(updated);
    }
    if (anchorIndex === -1) {
      throw new Error("fallback helper anchor not found");
    }
    updated = `${updated.slice(0, anchorIndex)}${TEXT_MEDIA_FALLBACK_HELPERS}\n${updated.slice(anchorIndex)}`;
  }

  if (
    !updated.includes(DELIVER_VOICE_ERROR_RE_MARKER) ||
    !updated.includes(DELIVER_VOICE_PREFER_TEXT_MARKER)
  ) {
    const helperInsertIndex = updated.indexOf(VOICE_HELPER_INSERT_ANCHOR);
    if (helperInsertIndex === -1) {
      throw new Error("voice helper anchor not found");
    }
    updated = `${updated.slice(0, helperInsertIndex)}${VOICE_TEXT_FALLBACK_HELPERS}\n${updated.slice(helperInsertIndex)}`;
  }

  if (
    !updated.includes(DELIVER_FALLBACK_MARKER) ||
    !updated.includes(DELIVER_BLOCK_SUPPRESSION_MARKER) ||
    !updated.includes(DELIVER_NO_FINAL_CANDIDATE_MARKER) ||
    !updated.includes(DELIVER_OUTBOUND_DELIVERY_MARKER) ||
    !updated.includes(DELIVER_MEDIA_DELIVERY_MARKER) ||
    !updated.includes(DELIVER_DISPATCHER_STATE_BINDING_MARKER) ||
    !updated.includes(DELIVER_DISPATCHER_STATE_MIRROR_MARKER) ||
    !updated.includes(DELIVER_VOICE_ERROR_RE_MARKER) ||
    !updated.includes(DELIVER_VOICE_PREFER_TEXT_MARKER) ||
    !updated.includes(DELIVER_VOICE_FALLBACK_SEND_FAILED_MARKER)
  ) {
    if (!DELIVER_BLOCK_PATTERN.test(updated)) {
      throw new Error("deliver block anchor not found");
    }
    updated = updated.replace(DELIVER_BLOCK_PATTERN, PATCHED_DELIVER_BLOCK);
  }

  return updated;
}

export async function applyPatchToTargetRoot({
  targetRoot = DEFAULT_TARGET_ROOT,
  apply = false,
} = {}) {
  const dispatcherPath = path.join(targetRoot, "reply-dispatcher.ts");
  const original = await readFile(dispatcherPath, "utf8");
  const patched = patchFeishuReplyDispatcherSource(original);
  const changed = patched !== original;

  if (apply && changed) {
    const backupPath = `${dispatcherPath}.bak`;
    try {
      await access(backupPath);
    } catch {
      await writeFile(backupPath, original, "utf8");
    }
    await writeFile(dispatcherPath, patched, "utf8");
  }

  return { targetRoot, dispatcherPath, changed, apply };
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
