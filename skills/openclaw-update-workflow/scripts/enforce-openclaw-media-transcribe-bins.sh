#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$DEFAULT_OPENCLAW_HOME/openclaw.json}"
DEFAULT_FFMPEG_BIN="/opt/homebrew/bin/ffmpeg"
DEFAULT_WHISPER_BIN="/opt/homebrew/bin/whisper-cli"

mode="apply"
config_path="$DEFAULT_CONFIG_PATH"
ffmpeg_bin="$DEFAULT_FFMPEG_BIN"
whisper_bin="$DEFAULT_WHISPER_BIN"

show_help() {
  cat <<'EOF'
Usage: enforce-openclaw-media-transcribe-bins.sh [options]

Options:
  --dry-run                    Report whether config would change, without writing.
  --apply                      Enforce config in-place (default).
  --config-path <path>         Override openclaw config path.
  --ffmpeg-bin <path>          Override ffmpeg executable path.
  --whisper-bin <path>         Override whisper-cli executable path.
  -h, --help                   Show this help message.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run)
      mode="dry-run"
      shift
      ;;
    --apply)
      mode="apply"
      shift
      ;;
    --config-path)
      if (($# < 2)); then
        echo "missing value for --config-path" >&2
        exit 2
      fi
      config_path="$2"
      shift 2
      ;;
    --ffmpeg-bin)
      if (($# < 2)); then
        echo "missing value for --ffmpeg-bin" >&2
        exit 2
      fi
      ffmpeg_bin="$2"
      shift 2
      ;;
    --whisper-bin)
      if (($# < 2)); then
        echo "missing value for --whisper-bin" >&2
        exit 2
      fi
      whisper_bin="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$config_path" ]]; then
  echo "config file not found: $config_path" >&2
  exit 1
fi

if [[ ! -r "$config_path" ]]; then
  echo "config file not readable: $config_path" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node binary not found in PATH" >&2
  exit 1
fi

node - "$config_path" "$mode" "$ffmpeg_bin" "$whisper_bin" <<'NODE'
const fs = require("fs");
const path = require("path");

const [configPath, mode, ffmpegBin, whisperBin] = process.argv.slice(2);

let doc;
try {
  const raw = fs.readFileSync(configPath, "utf8");
  doc = JSON.parse(raw);
} catch (error) {
  console.error(`failed to parse JSON: ${configPath}: ${error.message}`);
  process.exit(1);
}

if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
  console.error("top-level JSON must be an object");
  process.exit(1);
}

let changed = false;
let audioModelsPatched = 0;
let videoModelsPatched = 0;

function replaceCommands(value) {
  if (typeof value !== "string" || value.length === 0) {
    return value;
  }
  const replaced = value
    .replace(/(^|[^A-Za-z0-9_./-])ffmpeg(?=\s|$)/g, `$1${ffmpegBin}`)
    .replace(/(^|[^A-Za-z0-9_./-])whisper-cli(?=\s|$)/g, `$1${whisperBin}`);
  return replaced;
}

function patchModel(model) {
  if (typeof model !== "object" || model === null || Array.isArray(model)) {
    return false;
  }
  let modelChanged = false;
  if (typeof model.command === "string") {
    if (model.command === "ffmpeg") {
      model.command = ffmpegBin;
      modelChanged = true;
    } else if (model.command === "whisper-cli") {
      model.command = whisperBin;
      modelChanged = true;
    }
  }

  if (Array.isArray(model.args)) {
    for (let i = 0; i < model.args.length; i += 1) {
      if (typeof model.args[i] !== "string") {
        continue;
      }
      const next = replaceCommands(model.args[i]);
      if (next !== model.args[i]) {
        model.args[i] = next;
        modelChanged = true;
      }
    }
  }
  return modelChanged;
}

function patchMediaModels(kind) {
  const models = doc?.tools?.media?.[kind]?.models;
  if (!Array.isArray(models)) {
    return 0;
  }
  let patched = 0;
  for (const model of models) {
    if (patchModel(model)) {
      patched += 1;
    }
  }
  return patched;
}

audioModelsPatched = patchMediaModels("audio");
videoModelsPatched = patchMediaModels("video");
if (audioModelsPatched > 0 || videoModelsPatched > 0) {
  changed = true;
}

if (mode === "apply" && changed) {
  const rendered = `${JSON.stringify(doc, null, 2)}\n`;
  const dir = path.dirname(configPath);
  const base = path.basename(configPath);
  const tempPath = path.join(dir, `${base}.tmp-${process.pid}`);
  fs.writeFileSync(tempPath, rendered, { mode: 0o600 });
  fs.renameSync(tempPath, configPath);
}

console.log(
  JSON.stringify({
    ok: true,
    mode,
    changed,
    configPath,
    ffmpegBin,
    whisperBin,
    audioModelsPatched,
    videoModelsPatched
  })
);
NODE
