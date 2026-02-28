import path from "node:path";
import { access, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const DEFAULT_TARGET_ROOT = "/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src";

function replaceInFunctionBlock(source, functionName, transform) {
  const functionStart = source.indexOf(`function ${functionName}`);
  if (functionStart === -1) {
    return source;
  }

  const blockStart = source.indexOf("{", functionStart);
  if (blockStart === -1) {
    return source;
  }

  let depth = 0;
  let blockEnd = -1;
  for (let i = blockStart; i < source.length; i += 1) {
    const char = source[i];
    if (char === "{") {
      depth += 1;
    } else if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        blockEnd = i;
        break;
      }
    }
  }

  if (blockEnd === -1) {
    return source;
  }

  const originalBlock = source.slice(functionStart, blockEnd + 1);
  const updatedBlock = transform(originalBlock);
  if (originalBlock === updatedBlock) {
    return source;
  }

  return source.slice(0, functionStart) + updatedBlock + source.slice(blockEnd + 1);
}

function replaceParseMediaKeysBlock(source) {
  let updated = source;

  updated = updated.replace(
    /(function parseMediaKeys[\s\S]*?case "video":[\s\S]*?return \{ fileKey: parsed\.file_key, imageKey: parsed\.image_key)(?:, fileName: parsed\.file_name)? \};/,
    '$1, fileName: parsed.file_name };'
  );

  if (!updated.includes('case "media":')) {
    updated = updated.replace(
      /(function parseMediaKeys[\s\S]*?case "video":[\s\S]*?return \{ fileKey: parsed\.file_key, imageKey: parsed\.image_key, fileName: parsed\.file_name \};)/,
      '$1\n      case "media":\n        return { fileKey: parsed.file_key, imageKey: parsed.image_key, fileName: parsed.file_name };'
    );
  }

  return updated;
}

function replaceInferPlaceholderBlock(source) {
  return replaceInFunctionBlock(source, "inferPlaceholder", (block) => {
    if (block.includes('case "media":')) {
      return block;
    }

    return block.replace(
      /case "video":\s*return "<media:video>";/,
      'case "video":\n      return "<media:video>";\n    case "media":\n      return "<media:video>";'
    );
  });
}

export function patchFeishuBotSource(source) {
  let updated = source;

  updated = updated.replace(
    '["image", "file", "audio", "video", "sticker"].includes(messageType)',
    '["image", "file", "audio", "video", "sticker", "media"].includes(messageType)'
  );

  updated = replaceInFunctionBlock(updated, "parseMessageContent", (block) =>
    block.replace(
      "return inferPlaceholder(messageType);",
      "return inferPlaceholder(messageType, parsed.file_name, parsed.image_key);"
    )
  );

  updated = replaceParseMediaKeysBlock(updated);
  updated = replaceInferPlaceholderBlock(updated);

  updated = updated.replace(
    'const mediaTypes = ["image", "file", "audio", "video", "sticker", "post"];',
    'const mediaTypes = ["image", "file", "audio", "video", "media", "sticker", "post"];'
  );

  updated = updated.replace(
    "const fileKey = mediaKeys.imageKey || mediaKeys.fileKey;",
    `const fileKey =
  messageType === "image"
    ? mediaKeys.imageKey || mediaKeys.fileKey
    : mediaKeys.fileKey || mediaKeys.imageKey;`
  );

  return updated;
}

export async function applyPatchToTargetRoot({
  targetRoot = DEFAULT_TARGET_ROOT,
  apply = false,
} = {}) {
  const botPath = path.join(targetRoot, "bot.ts");
  const original = await readFile(botPath, "utf8");
  const patched = patchFeishuBotSource(original);
  const changed = patched !== original;

  if (apply && changed) {
    const backupPath = `${botPath}.bak`;
    try {
      await access(backupPath);
    } catch {
      await writeFile(backupPath, original, "utf8");
    }
    await writeFile(botPath, patched, "utf8");
  }

  return { targetRoot, botPath, changed, apply };
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
