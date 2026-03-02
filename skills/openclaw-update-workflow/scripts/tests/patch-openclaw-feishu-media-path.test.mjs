import test from "node:test";
import assert from "node:assert/strict";

import { patchFeishuMediaPathSource } from "../patch-openclaw-feishu-media-path.mjs";

const LOAD_MEDIA_SNIPPET = `
import fs from "fs";

async function loadMedia(mediaUrl: string) {
  const loaded = await getFeishuRuntime().media.loadWebMedia(mediaUrl, {
    mediaType: "file",
  });
  return loaded;
}
`;

const OLD_COMMENT_ANCHOR = `/**
 * Upload and send media (image or file) from URL, local path, or buffer
 */`;

const PERIOD_COMMENT_ANCHOR = `/**
 * Upload and send media (image or file) from URL, local path, or buffer.
 */`;

const FUNCTION_SIGNATURE_ANCHOR = "export async function sendMediaFeishu(";

function buildFixture(anchorBlock) {
  return `${LOAD_MEDIA_SNIPPET}\n${anchorBlock}\nexport async function sendMediaFeishu(params: {\n  cfg: FeishuConfig;\n  msgType?: "file" | "media";\n}): Promise<void> {\n  /** Use "media" for audio/video files, "file" for documents */\n  return;\n}\n`;
}

test("patches old comment anchor", () => {
  const input = buildFixture(OLD_COMMENT_ANCHOR);
  const out = patchFeishuMediaPathSource(input);

  assert.match(out, /function resolveFeishuMediaUrlForLoad\(mediaUrl: string\): string \{/);
  assert.match(out, /const normalizedMediaUrl = resolveFeishuMediaUrlForLoad\(mediaUrl\);/);
});

test("patches period comment anchor", () => {
  const input = buildFixture(PERIOD_COMMENT_ANCHOR);
  const out = patchFeishuMediaPathSource(input);

  assert.match(out, /function resolveFeishuMediaUrlForLoad\(mediaUrl: string\): string \{/);
  assert.match(out, /Upload and send media \(image or file\) from URL, local path, or buffer\./);
});

test("falls back to function signature anchor when comment is missing", () => {
  const input = buildFixture("");
  const out = patchFeishuMediaPathSource(input);

  const helperIndex = out.indexOf("function resolveFeishuMediaUrlForLoad(mediaUrl: string): string {");
  const signatureIndex = out.indexOf(FUNCTION_SIGNATURE_ANCHOR);

  assert.ok(helperIndex >= 0, "helper should be inserted");
  assert.ok(signatureIndex >= 0, "sendMediaFeishu signature should exist");
  assert.ok(helperIndex < signatureIndex, "helper should be inserted before signature anchor");
});

test("throws when all helper anchors are missing", () => {
  const input = `${LOAD_MEDIA_SNIPPET}\nexport async function sendMediaFromElsewhere(params: { msgType?: "file" | "media"; }): Promise<void> {\n  return;\n}\n`;

  assert.throws(() => patchFeishuMediaPathSource(input), /helper anchor not found/);
});

test("is idempotent", () => {
  const input = buildFixture(PERIOD_COMMENT_ANCHOR);
  const once = patchFeishuMediaPathSource(input);
  const twice = patchFeishuMediaPathSource(once);

  assert.equal(twice, once);
});
