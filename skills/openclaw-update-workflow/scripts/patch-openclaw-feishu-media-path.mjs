import path from "node:path";
import { access, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const DEFAULT_TARGET = "/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/media.ts";
const SPAWN_SYNC_IMPORT = 'import { spawnSync } from "node:child_process";';
const PATH_HELPER_MARKER = "function isPathUnderRoot(candidate: string, root: string): boolean {";
const HELPER_MARKER = "function resolveFeishuMediaUrlForLoad(mediaUrl: string): string {";
const DURATION_HELPER_MARKER = "function probeDurationMsWithFfprobe(filePath: string): number | undefined {";
const HELPER_INSERT_ANCHOR = `/**
 * Upload and send media (image or file) from URL, local path, or buffer
 */`;
const DURATION_HELPER_INSERT_ANCHOR = "function isPathUnderRoot(candidate: string, root: string): boolean {";
const LOAD_CALL_OLD = "const loaded = await getFeishuRuntime().media.loadWebMedia(mediaUrl, {";
const LOAD_CALL_NEW = `const normalizedMediaUrl = resolveFeishuMediaUrlForLoad(mediaUrl);
    const loaded = await getFeishuRuntime().media.loadWebMedia(normalizedMediaUrl, {`;
const AUDIO_MSG_TYPE_DOC_OLD = '/** Use "media" for audio/video files, "file" for documents */';
const AUDIO_MSG_TYPE_DOC_LEGACY = '/** Use "media" for audio/video, "file" for documents */';
const AUDIO_MSG_TYPE_DOC_V0 = '/** Use "audio" for opus, "media" for video, "file" for documents */';
const AUDIO_MSG_TYPE_DOC_NEW =
  '/** Use "audio"/"media" for audio files, "media" for video files, "file" for documents */';
const AUDIO_MSG_TYPE_SIGNATURE_OLD = 'msgType?: "file" | "media";';
const AUDIO_MSG_TYPE_SIGNATURE_NEW = 'msgType?: "file" | "media" | "audio";';
const AUDIO_ROUTE_COMMENT_OLD = `// Feishu mapping:
    // - opus => msg_type "audio"
    // - mp4  => msg_type "media"
    // - docs/others => msg_type "file"`;
const AUDIO_ROUTE_COMMENT_LEGACY =
  '// Feishu requires msg_type "media" for audio/video, "file" for documents';
const AUDIO_ROUTE_COMMENT_NEW =
  '// Feishu audio compatibility: retry msg_type for opus, use media/file for others';
const AUDIO_RETRY_MARKER_MSGTYPE = 'const msgTypeCandidates: Array<"audio" | "media" | "file"> =';
const AUDIO_RETRY_MARKER_UPLOAD = "const uploadDurationCandidates =";
const LEGACY_UPLOAD_SEND_BLOCK_PATTERN =
  /const fileType = detectFileType\(name\);\n(?:[\s\S]*?)const \{ fileKey \} = await uploadFileFeishu\(\{\n(?:[\s\S]*?)\n\s+\}\);\n(?:[\s\S]*?)return sendFileFeishu\(\{\n\s+cfg,\n\s+to,\n\s+fileKey,\n(?:[\s\S]*?)\n\s+\}\);\n/s;

const AUDIO_RETRY_BLOCK = `const fileType = detectFileType(name);
    const duration =
      fileType === "opus" || fileType === "mp4"
        ? await resolveUploadDurationMs({ file: buffer })
        : undefined;
    let fileKey: string | null = null;
    const uploadErrors: string[] = [];
    const uploadDurationCandidates =
      duration !== undefined && (fileType === "opus" || fileType === "mp4")
        ? [duration, undefined]
        : [duration];

    for (const uploadDuration of uploadDurationCandidates) {
      try {
        const uploaded = await uploadFileFeishu({
          cfg,
          file: buffer,
          fileName: name,
          fileType,
          duration: uploadDuration,
          accountId,
        });
        fileKey = uploaded.fileKey;
        break;
      } catch (error) {
        uploadErrors.push(
          \`duration=\${uploadDuration === undefined ? "none" : String(uploadDuration)}: \${String(error)}\`,
        );
      }
    }

    if (!fileKey) {
      throw new Error(\`Feishu file upload failed after retries: \${uploadErrors.join(" | ")}\`);
    }

    const msgTypeCandidates: Array<"audio" | "media" | "file"> =
      fileType === "opus"
        ? ["audio", "media", "file"]
        : fileType === "mp4"
          ? ["media", "file"]
          : ["file"];
    const sendErrors: string[] = [];

    for (const msgType of msgTypeCandidates) {
      try {
        return await sendFileFeishu({
          cfg,
          to,
          fileKey,
          msgType,
          replyToMessageId,
          accountId,
        });
      } catch (error) {
        sendErrors.push(\`msg_type=\${msgType}: \${String(error)}\`);
      }
    }

    throw new Error(\`Feishu file send failed after retries: \${sendErrors.join(" | ")}\`);`;

const HELPER_FUNCTION = `function isPathUnderRoot(candidate: string, root: string): boolean {
  const normalizedCandidate = path.resolve(candidate);
  const normalizedRoot = path.resolve(root);
  return (
    normalizedCandidate === normalizedRoot ||
    normalizedCandidate.startsWith(\`\${normalizedRoot}\${path.sep}\`)
  );
}

function resolveFeishuMediaUrlForLoad(mediaUrl: string): string {
  const trimmed = mediaUrl.trim();
  if (!trimmed) {
    return mediaUrl;
  }
  if (/^[a-zA-Z][a-zA-Z\\d+.-]*:\\/\\//.test(trimmed)) {
    return trimmed;
  }
  if (trimmed.startsWith("~")) {
    return trimmed;
  }

  const isAbsoluteLocalPath = path.isAbsolute(trimmed) || /^[a-zA-Z]:[\\\\/]/.test(trimmed);
  if (isAbsoluteLocalPath) {
    const absolutePath = path.resolve(trimmed);
    if (!fs.existsSync(absolutePath)) {
      return absolutePath;
    }

    const tempRoots = ["/tmp", "/private/tmp", process.env.TMPDIR]
      .filter((value) => typeof value === "string" && value.trim().length > 0)
      .map((value) => path.resolve(String(value).trim()));

    if (tempRoots.some((root) => isPathUnderRoot(absolutePath, root))) {
      const stateDir = getFeishuRuntime().state.resolveStateDir(process.env);
      const bridgeDir = path.resolve(stateDir, "workspace", "tmp-media");
      const bridgePath = path.resolve(bridgeDir, path.basename(absolutePath));
      try {
        fs.mkdirSync(bridgeDir, { recursive: true });
        fs.copyFileSync(absolutePath, bridgePath);
        return bridgePath;
      } catch {
        return absolutePath;
      }
    }

    return absolutePath;
  }

  const stateDir = getFeishuRuntime().state.resolveStateDir(process.env);
  const relativePath = trimmed.replace(/^\\.\\/+/, "");
  const openclawHome = process.env.OPENCLAW_HOME?.trim()
    ? path.resolve(process.env.OPENCLAW_HOME.trim())
    : process.env.HOME?.trim()
      ? path.resolve(process.env.HOME.trim(), ".openclaw")
      : "";
  const workspacePrefixedPath =
    relativePath.startsWith("workspace/") || relativePath.startsWith(\`workspace\${path.sep}\`)
      ? relativePath
      : path.join("workspace", relativePath);
  const candidates = [
    openclawHome ? path.resolve(openclawHome, relativePath) : "",
    openclawHome ? path.resolve(openclawHome, workspacePrefixedPath) : "",
    path.resolve(stateDir, relativePath),
    path.resolve(stateDir, "workspace", relativePath),
    path.resolve(process.cwd(), relativePath),
  ];

  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return trimmed;
}`;

const DURATION_HELPER_FUNCTION = `function probeDurationMsWithFfprobe(filePath: string): number | undefined {
  const probe = spawnSync(
    "ffprobe",
    [
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      filePath,
    ],
    { encoding: "utf8" },
  );

  if (probe.status !== 0) {
    return undefined;
  }
  const raw = probe.stdout?.trim();
  if (!raw) {
    return undefined;
  }
  const durationSeconds = Number.parseFloat(raw);
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return undefined;
  }
  return Math.max(1, Math.round(durationSeconds * 1000));
}

async function resolveUploadDurationMs(params: {
  file: Buffer | string;
}): Promise<number | undefined> {
  const { file } = params;
  if (!Buffer.isBuffer(file)) {
    return probeDurationMsWithFfprobe(file);
  }

  return await withTempDownloadPath({ prefix: "openclaw-feishu-media-probe-" }, async (tmpPath) => {
    await fs.promises.writeFile(tmpPath, file);
    return probeDurationMsWithFfprobe(tmpPath);
  });
}`;

export function patchFeishuMediaPathSource(source) {
  let updated = source;

  if (!updated.includes(SPAWN_SYNC_IMPORT)) {
    if (!updated.includes('import fs from "fs";')) {
      throw new Error("fs import anchor not found");
    }
    updated = updated.replace('import fs from "fs";', `import fs from "fs";\n${SPAWN_SYNC_IMPORT}`);
  }

  const helperIndex = updated.indexOf(HELPER_MARKER);
  const anchorIndex = updated.indexOf(HELPER_INSERT_ANCHOR);
  if (anchorIndex === -1) {
    throw new Error("helper anchor not found");
  }

  if (helperIndex === -1) {
    updated = updated.replace(HELPER_INSERT_ANCHOR, `${HELPER_FUNCTION}\n\n${HELPER_INSERT_ANCHOR}`);
  } else if (helperIndex < anchorIndex) {
    let replaceStart = helperIndex;
    const pathHelperIndex = updated.lastIndexOf(PATH_HELPER_MARKER, helperIndex);
    if (pathHelperIndex !== -1) {
      replaceStart = pathHelperIndex;
    }

    const currentHelper = updated.slice(replaceStart, anchorIndex).trimEnd();
    if (currentHelper !== HELPER_FUNCTION) {
      updated = `${updated.slice(0, replaceStart)}${HELPER_FUNCTION}\n\n${updated.slice(anchorIndex)}`;
    }
  } else {
    throw new Error("helper marker appears after helper anchor");
  }

  if (!updated.includes(DURATION_HELPER_MARKER)) {
    const durationAnchorIndex = updated.indexOf(DURATION_HELPER_INSERT_ANCHOR);
    if (durationAnchorIndex === -1) {
      throw new Error("duration helper anchor not found");
    }
    updated = `${updated.slice(0, durationAnchorIndex)}${DURATION_HELPER_FUNCTION}\n\n${updated.slice(durationAnchorIndex)}`;
  }

  if (!updated.includes("const normalizedMediaUrl = resolveFeishuMediaUrlForLoad(mediaUrl);")) {
    if (!updated.includes(LOAD_CALL_OLD)) {
      throw new Error("loadWebMedia anchor not found");
    }
    updated = updated.replace(LOAD_CALL_OLD, LOAD_CALL_NEW);
  }

  updated = updated.replace(AUDIO_MSG_TYPE_DOC_OLD, AUDIO_MSG_TYPE_DOC_NEW);
  updated = updated.replace(AUDIO_MSG_TYPE_DOC_LEGACY, AUDIO_MSG_TYPE_DOC_NEW);
  updated = updated.replace(AUDIO_MSG_TYPE_DOC_V0, AUDIO_MSG_TYPE_DOC_NEW);
  updated = updated.replace(AUDIO_MSG_TYPE_SIGNATURE_OLD, AUDIO_MSG_TYPE_SIGNATURE_NEW);
  updated = updated.replace(AUDIO_ROUTE_COMMENT_OLD, AUDIO_ROUTE_COMMENT_NEW);
  updated = updated.replace(AUDIO_ROUTE_COMMENT_LEGACY, AUDIO_ROUTE_COMMENT_NEW);

  if (
    (!updated.includes(AUDIO_RETRY_MARKER_MSGTYPE) || !updated.includes(AUDIO_RETRY_MARKER_UPLOAD)) &&
    updated.includes("const { fileKey } = await uploadFileFeishu({")
  ) {
    updated = updated.replace(LEGACY_UPLOAD_SEND_BLOCK_PATTERN, AUDIO_RETRY_BLOCK);
  }

  return updated;
}

export async function applyPatchToTarget({
  target = DEFAULT_TARGET,
  apply = false,
} = {}) {
  const targetPath = path.resolve(target);
  const original = await readFile(targetPath, "utf8");
  const patched = patchFeishuMediaPathSource(original);
  const changed = patched !== original;

  if (apply && changed) {
    const backupPath = `${targetPath}.bak`;
    try {
      await access(backupPath);
    } catch {
      await writeFile(backupPath, original, "utf8");
    }
    await writeFile(targetPath, patched, "utf8");
  }

  return { targetPath, changed, apply };
}

function parseCliArgs(argv) {
  let apply = false;
  let target = DEFAULT_TARGET;

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
    if (arg === "--target") {
      i += 1;
      if (i >= argv.length) {
        throw new Error("Missing value for --target");
      }
      target = argv[i];
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  return { target, apply };
}

const isMain =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const options = parseCliArgs(process.argv.slice(2));
  const result = await applyPatchToTarget(options);
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
