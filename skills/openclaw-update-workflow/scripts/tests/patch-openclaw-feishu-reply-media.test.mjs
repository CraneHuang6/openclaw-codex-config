import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { access, mkdtemp, readFile, writeFile } from "node:fs/promises";

import {
  applyPatchToTargetRoot,
  patchFeishuReplyDispatcherSource,
} from "../patch-openclaw-feishu-reply-media.mjs";

const DISPATCHER_SOURCE_FIXTURE = `
import { sendMarkdownCardFeishu, sendMessageFeishu } from "./send.js";

export function createFeishuReplyDispatcher() {
  let streamingStartPromise: Promise<void> | null = null;

  return {
    deliver: async (payload: ReplyPayload, info) => {
      const text = payload.text ?? "";
      if (!text.trim()) {
        return;
      }

      const useCard = renderMode === "card" || (renderMode === "auto" && shouldUseCard(text));

      if ((info?.kind === "block" || info?.kind === "final") && streamingEnabled && useCard) {
        startStreaming();
        if (streamingStartPromise) {
          await streamingStartPromise;
        }
      }

      if (streaming?.isActive()) {
        if (info?.kind === "final") {
          streamText = text;
          await closeStreaming();
        }
        return;
      }

      let first = true;
      if (useCard) {
        for (const chunk of core.channel.text.chunkTextWithMode(text, textChunkLimit, chunkMode)) {
          await sendMarkdownCardFeishu({
            cfg,
            to: chatId,
            text: chunk,
            replyToMessageId,
            mentions: first ? mentionTargets : undefined,
            accountId,
          });
          first = false;
        }
      } else {
        const converted = core.channel.text.convertMarkdownTables(text, tableMode);
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
          first = false;
        }
      }
    },
    onError: async (error, info) => {
      params.runtime.error?.(\`feishu[\${account.accountId}] \${info.kind} reply failed: \${String(error)}\`);
    },
  };
}
`;

async function createTargetRoot(source = DISPATCHER_SOURCE_FIXTURE) {
  const targetRoot = await mkdtemp(path.join(tmpdir(), "patch-feishu-reply-media-"));
  const dispatcherPath = path.join(targetRoot, "reply-dispatcher.ts");
  await writeFile(dispatcherPath, source, "utf8");
  return { targetRoot, dispatcherPath, source };
}

function createRuntimeDispatcherHarness() {
  const patched = patchFeishuReplyDispatcherSource(DISPATCHER_SOURCE_FIXTURE);
  const executableSource = patched
    .replace(/^import .*$/gm, "")
    .replace(
      "deliver: async (payload: ReplyPayload, info) => {",
      "deliver: async (payload, info) => {"
    )
    .replace("export function createFeishuReplyDispatcher()", "function createFeishuReplyDispatcher()")
    .replace(/let streamingStartPromise:\s*Promise<void>\s*\|\s*null = null;/, "let streamingStartPromise = null;")
    .replace(/const dedupState = params as \{[\s\S]*?\};/, "const dedupState = params;");

  const sentMessageTexts = [];
  const sentCardTexts = [];
  const sentMediaUrls = [];

  const context = {
    params: { runtime: { error: () => {} } },
    core: {
      channel: {
        text: {
          chunkTextWithMode: (text) => [text],
          convertMarkdownTables: (text) => text,
        },
      },
    },
    cfg: {},
    chatId: "chat-id",
    replyToMessageId: undefined,
    mentionTargets: [],
    accountId: "acct-id",
    account: { accountId: "acct-id" },
    renderMode: "text",
    shouldUseCard: () => false,
    streamingEnabled: false,
    startStreaming: () => {},
    streaming: { isActive: () => false },
    closeStreaming: async () => {},
    textChunkLimit: 8192,
    chunkMode: "line",
    tableMode: "none",
    sendMarkdownCardFeishu: async ({ text }) => {
      sentCardTexts.push(text);
    },
    sendMessageFeishu: async ({ text }) => {
      sentMessageTexts.push(text);
    },
    sendMediaFeishu: async ({ mediaUrl }) => {
      sentMediaUrls.push(mediaUrl);
    },
  };

  const factory = new Function(
    "context",
    `
      "use strict";
      const {
        params,
        core,
        cfg,
        chatId,
        replyToMessageId,
        mentionTargets,
        accountId,
        account,
        renderMode,
        shouldUseCard,
        streamingEnabled,
        startStreaming,
        streaming,
        closeStreaming,
        textChunkLimit,
        chunkMode,
        tableMode,
        sendMarkdownCardFeishu,
        sendMessageFeishu,
        sendMediaFeishu,
      } = context;
      let streamText = "";
      ${executableSource}
      return createFeishuReplyDispatcher();
    `
  );

  const dispatcher = factory(context);
  return { dispatcher, sentMessageTexts, sentCardTexts, sentMediaUrls, params: context.params };
}

test("patchFeishuReplyDispatcherSource adds media delivery logic", () => {
  const out = patchFeishuReplyDispatcherSource(DISPATCHER_SOURCE_FIXTURE);

  assert.match(out, /import \{ sendMediaFeishu \} from "\.\/media\.js";/);
  assert.match(out, /const VOICE_ERROR_TEXT_RE =/);
  assert.match(out, /function shouldPreferTextDeliveryInVoiceMode\(text\) \{/);
  assert.match(out, /function extractMediaUrlsFromTextFallback\(text\) \{/);
  assert.match(
    out,
    /const originalText = payload\.text \?\? "";[\s\S]*const fallback = extractMediaUrlsFromTextFallback\(originalText\);[\s\S]*const text = fallback\.text;/
  );
  assert.match(
    out,
    /const mediaUrls =\s*payload\.mediaUrls\?\.length[\s\S]*:\s*fallback\.mediaUrls;/
  );
  assert.match(out, /const canSendMedia = info\?\.kind === "final" \|\| !info\?\.kind;/);
  assert.match(out, /if \(info\?\.kind === "block"\) \{/);
  assert.match(out, /let textDeliveredByStreaming = false;/);
  assert.match(
    out,
    /const dedupState = params as \{[\s\S]*__openclawFeishuLastDeliveredTextForDedup\?: string;[\s\S]*__openclawFeishuLastDeliveredRawTextForDedup\?: string;[\s\S]*__openclawFeishuNoFinalTextCandidate\?: \(\) => string;[\s\S]*__openclawFeishuHadOutboundDelivery\?: \(\) => boolean;[\s\S]*__openclawFeishuHadMediaDelivery\?: \(\) => boolean;/
  );
  assert.match(
    out,
    /const lastDeliveredTextForDedup =\s*dedupState\.__openclawFeishuLastDeliveredTextForDedup \?\? null;/
  );
  assert.match(
    out,
    /const shouldSkipDuplicatedText =[\s\S]*lastDeliveredTextForDedup === normalizedSourceText;/
  );
  assert.match(
    out,
    /const shouldTrimFinalPrefix =[\s\S]*normalizedSourceText\.startsWith\(lastDeliveredTextForDedup\);/
  );
  assert.match(
    out,
    /if \(shouldTrimFinalPrefix\) \{[\s\S]*trimmedCurrent\.startsWith\(trimmedLast\)[\s\S]*textToDeliver = trimmedCurrent\.slice\(trimmedLast\.length\)\.trimStart\(\);/
  );
  assert.match(
    out,
    /const hasTextToDeliver = normalizedTextToDeliver\.length > 0;/
  );
  assert.match(
    out,
    /const suppressTextDelivery = params\.forceVoiceModeTts === true;[\s\S]*const preferTextDeliveryInVoiceMode =[\s\S]*if \(\s*\(!suppressTextDelivery \|\| preferTextDeliveryInVoiceMode\)[\s\S]*!textDeliveredByStreaming[\s\S]*hasTextToDeliver[\s\S]*!shouldSkipDuplicatedText[\s\S]*\)\s*\{[\s\S]*await sendMessageFeishu\(\{/
  );
  assert.match(
    out,
    /const converted = core\.channel\.text\.convertMarkdownTables\(textToDeliver, tableMode\);/
  );
  assert.match(
    out,
    /if \(\s*hasText &&\s*normalizedSourceText\.length > 0 &&\s*\(!shouldSkipDuplicatedText \|\| textDeliveredByStreaming\)\s*\)\s*\{\s*dedupState\.__openclawFeishuLastDeliveredTextForDedup = normalizedSourceText;[\s\S]*dedupState\.__openclawFeishuLastDeliveredRawTextForDedup = text;[\s\S]*\}/
  );
  assert.match(
    out,
    /if \(canSendMedia && mediaUrls\.length > 0\) \{[\s\S]*await sendMediaFeishu\(\{[\s\S]*text: `Attachment: \$\{mediaUrl\}`/
  );
  assert.match(out, /voice fallback send failed/);
  assert.match(out, /dedupState\.__openclawFeishuNoFinalTextCandidate = \(\) => noFinalTextCandidate;/);
  assert.match(out, /dedupState\.__openclawFeishuHadOutboundDelivery = \(\) => hadOutboundDelivery;/);
  assert.match(out, /dedupState\.__openclawFeishuHadMediaDelivery = \(\) => hadMediaDelivery;/);
  assert.doesNotMatch(out, /if \(!text\.trim\(\)\) \{\s*return;\s*\}/);
});

test("patchFeishuReplyDispatcherSource is idempotent", () => {
  const once = patchFeishuReplyDispatcherSource(DISPATCHER_SOURCE_FIXTURE);
  const twice = patchFeishuReplyDispatcherSource(once);
  assert.equal(twice, once);
});

test("deliver suppresses block text and only sends final text at runtime", async () => {
  const { dispatcher, sentMessageTexts, sentCardTexts, params } = createRuntimeDispatcherHarness();

  await dispatcher.deliver({ text: "prefix", mediaUrls: [] }, { kind: "block" });
  await dispatcher.deliver({ text: "prefix and tail", mediaUrls: [] }, { kind: "final" });

  assert.deepEqual(sentCardTexts, []);
  assert.deepEqual(sentMessageTexts, ["prefix and tail"]);
  assert.equal(params.__openclawFeishuLastDeliveredTextForDedup, "prefix and tail");
  assert.equal(params.__openclawFeishuLastDeliveredRawTextForDedup, "prefix and tail");
  assert.equal(params.__openclawFeishuNoFinalTextCandidate(), "prefix and tail");
  assert.equal(params.__openclawFeishuHadOutboundDelivery(), true);
  assert.equal(params.__openclawFeishuHadMediaDelivery(), false);
});

test("deliver extracts media path line from text fallback and avoids path echo", async () => {
  const { dispatcher, sentMessageTexts, sentCardTexts, sentMediaUrls, params } =
    createRuntimeDispatcherHarness();

  await dispatcher.deliver(
    {
      text: "给你一张图\nSaved: ./workspace/outputs/selfie/test.png",
      mediaUrls: [],
    },
    { kind: "final" }
  );

  assert.deepEqual(sentCardTexts, []);
  assert.deepEqual(sentMessageTexts, ["给你一张图"]);
  assert.deepEqual(sentMediaUrls, ["./workspace/outputs/selfie/test.png"]);
  assert.equal(params.__openclawFeishuHadMediaDelivery(), true);
});

test("applyPatchToTargetRoot applies patch and creates backup", async () => {
  const { targetRoot, dispatcherPath, source } = await createTargetRoot();

  const result = await applyPatchToTargetRoot({ targetRoot, apply: true });

  assert.deepEqual(result, {
    targetRoot,
    dispatcherPath,
    changed: true,
    apply: true,
  });
  assert.equal(await readFile(dispatcherPath, "utf8"), patchFeishuReplyDispatcherSource(source));
  assert.equal(await readFile(`${dispatcherPath}.bak`, "utf8"), source);
});

test("applyPatchToTargetRoot is idempotent on second apply", async () => {
  const { targetRoot, dispatcherPath } = await createTargetRoot();
  await applyPatchToTargetRoot({ targetRoot, apply: true });
  await writeFile(`${dispatcherPath}.bak`, "keep-existing-backup", "utf8");

  const result = await applyPatchToTargetRoot({ targetRoot, apply: true });

  assert.deepEqual(result, {
    targetRoot,
    dispatcherPath,
    changed: false,
    apply: true,
  });
  assert.equal(await readFile(`${dispatcherPath}.bak`, "utf8"), "keep-existing-backup");
});

test("applyPatchToTargetRoot dry-run does not write files", async () => {
  const { targetRoot, dispatcherPath, source } = await createTargetRoot();

  const result = await applyPatchToTargetRoot({ targetRoot, apply: false });

  assert.deepEqual(result, {
    targetRoot,
    dispatcherPath,
    changed: true,
    apply: false,
  });
  assert.equal(await readFile(dispatcherPath, "utf8"), source);
  await assert.rejects(access(`${dispatcherPath}.bak`), { code: "ENOENT" });
});

test("CLI defaults to dry-run and supports --apply with --target-root", async () => {
  const scriptPath = fileURLToPath(
    new URL("../patch-openclaw-feishu-reply-media.mjs", import.meta.url)
  );
  const { targetRoot, dispatcherPath, source } = await createTargetRoot();

  const dryRun = spawnSync(process.execPath, [scriptPath, "--target-root", targetRoot], {
    encoding: "utf8",
  });
  assert.equal(dryRun.status, 0, dryRun.stderr);
  assert.deepEqual(JSON.parse(dryRun.stdout.trim()), {
    targetRoot,
    dispatcherPath,
    changed: true,
    apply: false,
  });
  assert.equal(await readFile(dispatcherPath, "utf8"), source);

  const applyRun = spawnSync(
    process.execPath,
    [scriptPath, "--apply", "--target-root", targetRoot],
    { encoding: "utf8" }
  );
  assert.equal(applyRun.status, 0, applyRun.stderr);
  assert.deepEqual(JSON.parse(applyRun.stdout.trim()), {
    targetRoot,
    dispatcherPath,
    changed: true,
    apply: true,
  });
  assert.equal(await readFile(dispatcherPath, "utf8"), patchFeishuReplyDispatcherSource(source));
});
