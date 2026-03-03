#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$DEFAULT_OPENCLAW_HOME/openclaw.json}"
DEFAULT_PRIMARY_MODEL="qmcode/gpt-5.3-codex"
DEFAULT_PRIMARY_ALIAS="GPT-5.3 Codex"
DEFAULT_FALLBACK_MODELS=("qmcode/gpt-5.2" "openrouter/arcee-ai/trinity-large-preview:free")

mode="apply"
config_path="$DEFAULT_CONFIG_PATH"
primary_model="$DEFAULT_PRIMARY_MODEL"
primary_alias="$DEFAULT_PRIMARY_ALIAS"
fallback_models=("${DEFAULT_FALLBACK_MODELS[@]}")
fallback_overridden=false

show_help() {
  cat <<'EOF'
Usage: enforce-openclaw-kimi-model.sh [options]

Options:
  --dry-run                    Report whether config would change, without writing.
  --apply                      Enforce config in-place (default).
  --config-path <path>         Override openclaw config path.
  --primary-model <model-id>   Override enforced primary model id.
  --primary-alias <alias>      Override enforced model alias.
  --fallback-model <model-id>  Add enforced fallback model id (repeatable).
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
    --primary-model)
      if (($# < 2)); then
        echo "missing value for --primary-model" >&2
        exit 2
      fi
      primary_model="$2"
      shift 2
      ;;
    --primary-alias)
      if (($# < 2)); then
        echo "missing value for --primary-alias" >&2
        exit 2
      fi
      primary_alias="$2"
      shift 2
      ;;
    --fallback-model)
      if (($# < 2)); then
        echo "missing value for --fallback-model" >&2
        exit 2
      fi
      if [[ "$fallback_overridden" != "true" ]]; then
        fallback_models=()
        fallback_overridden=true
      fi
      fallback_models+=("$2")
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

node - "$config_path" "$mode" "$primary_model" "$primary_alias" "${fallback_models[@]}" <<'NODE'
const fs = require("fs");
const path = require("path");

const [configPath, mode, primaryModel, primaryAlias, ...fallbackModels] =
  process.argv.slice(2);

let doc;
try {
  const raw = fs.readFileSync(configPath, "utf8");
  doc = JSON.parse(raw);
} catch (error) {
  console.error(`failed to parse JSON: ${configPath}: ${error.message}`);
  process.exit(1);
}

let changed = false;

function ensureObject(parent, key) {
  const current = parent[key];
  if (
    typeof current === "object" &&
    current !== null &&
    !Array.isArray(current)
  ) {
    return current;
  }
  parent[key] = {};
  changed = true;
  return parent[key];
}

if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
  doc = {};
  changed = true;
}

const agents = ensureObject(doc, "agents");
const defaults = ensureObject(agents, "defaults");
const model = ensureObject(defaults, "model");
const models = ensureObject(defaults, "models");

if (model.primary !== primaryModel) {
  model.primary = primaryModel;
  changed = true;
}

if (
  !Array.isArray(model.fallbacks) ||
  model.fallbacks.length !== fallbackModels.length ||
  model.fallbacks.some((value, index) => value !== fallbackModels[index])
) {
  model.fallbacks = [...fallbackModels];
  changed = true;
}

const currentEntry = models[primaryModel];
if (
  typeof currentEntry !== "object" ||
  currentEntry === null ||
  Array.isArray(currentEntry)
) {
  models[primaryModel] = { alias: primaryAlias };
  changed = true;
} else if (currentEntry.alias !== primaryAlias) {
  currentEntry.alias = primaryAlias;
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

const result = {
  ok: true,
  mode,
  changed,
  configPath,
  primaryModel,
  fallbacks: fallbackModels
};

console.log(JSON.stringify(result));
NODE
