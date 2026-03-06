#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$DEFAULT_OPENCLAW_HOME/openclaw.json}"
DEFAULT_PRIMARY_MODEL="qmcode/gpt-5.4"
DEFAULT_PRIMARY_ALIAS="GPT-5.4"
DEFAULT_FALLBACK_MODELS=("qmcode/gpt-5.2")
DEFAULT_OPENCLAW_BIN="${OPENCLAW_BIN:-/opt/homebrew/bin/openclaw}"
DEFAULT_PROBE_TIMEOUT_MS="${OPENCLAW_MODEL_GUARD_PROBE_TIMEOUT_MS:-12000}"
DEFAULT_PROBE_CONCURRENCY="${OPENCLAW_MODEL_GUARD_PROBE_CONCURRENCY:-2}"

mode="apply"
config_path="$DEFAULT_CONFIG_PATH"
primary_model="$DEFAULT_PRIMARY_MODEL"
primary_alias="$DEFAULT_PRIMARY_ALIAS"
fallback_models=("${DEFAULT_FALLBACK_MODELS[@]}")
fallback_overridden=false
verify_fallback_availability=false
openclaw_bin="$DEFAULT_OPENCLAW_BIN"
probe_timeout_ms="$DEFAULT_PROBE_TIMEOUT_MS"
probe_concurrency="$DEFAULT_PROBE_CONCURRENCY"

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
  --verify-fallback-availability
                               Fail closed when any fallback probe status is not ok.
  --openclaw-bin <path>        Override openclaw binary used for fallback probes.
  --probe-timeout-ms <n>       Probe timeout passed to `openclaw models status --probe`.
  --probe-concurrency <n>      Probe concurrency passed to `openclaw models status --probe`.
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
    --verify-fallback-availability)
      verify_fallback_availability=true
      shift
      ;;
    --openclaw-bin)
      if (($# < 2)); then
        echo "missing value for --openclaw-bin" >&2
        exit 2
      fi
      openclaw_bin="$2"
      shift 2
      ;;
    --probe-timeout-ms)
      if (($# < 2)); then
        echo "missing value for --probe-timeout-ms" >&2
        exit 2
      fi
      probe_timeout_ms="$2"
      shift 2
      ;;
    --probe-concurrency)
      if (($# < 2)); then
        echo "missing value for --probe-concurrency" >&2
        exit 2
      fi
      probe_concurrency="$2"
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

enforce_result="$(
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
)"

if [[ "$verify_fallback_availability" == "true" && "${#fallback_models[@]}" -gt 0 ]]; then
  if ! command -v "$openclaw_bin" >/dev/null 2>&1; then
    echo "fallback availability check failed: openclaw binary not found: $openclaw_bin" >&2
    exit 1
  fi

  set +e
  probe_output="$("$openclaw_bin" models status --probe --probe-timeout "$probe_timeout_ms" --probe-concurrency "$probe_concurrency" --json 2>&1)"
  probe_code=$?
  set -e
  if (( probe_code != 0 )); then
    echo "fallback availability check failed: probe command exited ${probe_code}" >&2
    printf '%s\n' "$probe_output" >&2
    exit 1
  fi

  set +e
  node - "$probe_output" "${fallback_models[@]}" <<'NODE'
const raw = String(process.argv[2] ?? "");
const start = raw.indexOf("{");
if (start < 0) {
  console.error("fallback availability check failed: probe output missing JSON payload");
  process.exit(1);
}

let payload;
try {
  payload = JSON.parse(raw.slice(start));
} catch (error) {
  console.error(`fallback availability check failed: invalid probe JSON (${error.message})`);
  process.exit(1);
}

const probeResults = Array.isArray(payload?.auth?.probes?.results) ? payload.auth.probes.results : [];
const fallbackModels = process.argv.slice(3);
const failures = [];

for (const fallback of fallbackModels) {
  const slash = fallback.indexOf("/");
  if (slash <= 0 || slash === fallback.length - 1) {
    failures.push({ model: fallback, status: "invalid_model_ref", error: "Expected provider/model format" });
    continue;
  }

  const provider = fallback.slice(0, slash);
  const model = fallback.slice(slash + 1);
  const match = probeResults.find(
    (entry) => String(entry?.provider ?? "") === provider && String(entry?.model ?? "") === fallback,
  );
  if (!match) {
    failures.push({
      model: fallback,
      status: "missing_probe_result",
      error: "No provider/model probe result found",
    });
    continue;
  }

  const status = String(match?.status ?? "unknown");
  if (status !== "ok") {
    failures.push({
      model: fallback,
      status,
      error: String(match?.error ?? "probe status is not ok"),
    });
  }
}

if (failures.length > 0) {
  console.error(`fallback availability check failed: ${JSON.stringify(failures)}`);
  process.exit(1);
}
NODE
  probe_verify_code=$?
  set -e
  if (( probe_verify_code != 0 )); then
    exit 1
  fi
fi

printf '%s\n' "$enforce_result"
