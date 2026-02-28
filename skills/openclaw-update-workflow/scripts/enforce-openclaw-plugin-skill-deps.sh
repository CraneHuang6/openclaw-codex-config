#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$DEFAULT_OPENCLAW_HOME/openclaw.json}"
DEFAULT_REQUIRED_PLUGIN_ALLOW="device-pair,memory-core,phone-control,talk-voice,feishu"
DEFAULT_REQUIRED_PLUGIN_ENTRIES="feishu,memory-core"
DEFAULT_REQUIRED_SKILL_ENTRIES="xiaoke-selfie"

mode="apply"
config_path="$DEFAULT_CONFIG_PATH"
required_plugin_allow="$DEFAULT_REQUIRED_PLUGIN_ALLOW"
required_plugin_entries="$DEFAULT_REQUIRED_PLUGIN_ENTRIES"
required_skill_entries="$DEFAULT_REQUIRED_SKILL_ENTRIES"

show_help() {
  cat <<'EOF'
Usage: enforce-openclaw-plugin-skill-deps.sh [options]

Options:
  --dry-run                           Report whether config would change, without writing.
  --apply                             Enforce config in-place (default).
  --config-path <path>                Override openclaw config path.
  --required-plugin-allow <csv>       Required plugin ids in plugins.allow.
  --required-plugin-entries <csv>     Required enabled plugin entries.
  --required-skill-entries <csv>      Required enabled skill entries.
  -h, --help                          Show this help message.
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
    --required-plugin-allow)
      if (($# < 2)); then
        echo "missing value for --required-plugin-allow" >&2
        exit 2
      fi
      required_plugin_allow="$2"
      shift 2
      ;;
    --required-plugin-entries)
      if (($# < 2)); then
        echo "missing value for --required-plugin-entries" >&2
        exit 2
      fi
      required_plugin_entries="$2"
      shift 2
      ;;
    --required-skill-entries)
      if (($# < 2)); then
        echo "missing value for --required-skill-entries" >&2
        exit 2
      fi
      required_skill_entries="$2"
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

node - "$config_path" "$mode" "$required_plugin_allow" "$required_plugin_entries" "$required_skill_entries" <<'NODE'
const fs = require("fs");
const path = require("path");

const [
  configPath,
  mode,
  requiredPluginAllowCsv,
  requiredPluginEntriesCsv,
  requiredSkillEntriesCsv,
] = process.argv.slice(2);

function parseCsv(csv) {
  return String(csv || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function ensureObject(parent, key, state) {
  const current = parent[key];
  if (typeof current === "object" && current !== null && !Array.isArray(current)) {
    return current;
  }
  parent[key] = {};
  state.changed = true;
  return parent[key];
}

let doc;
try {
  const raw = fs.readFileSync(configPath, "utf8");
  doc = JSON.parse(raw);
} catch (error) {
  console.error(`failed to parse JSON: ${configPath}: ${error.message}`);
  process.exit(1);
}

const requiredPluginAllow = parseCsv(requiredPluginAllowCsv);
const requiredPluginEntries = parseCsv(requiredPluginEntriesCsv);
const requiredSkillEntries = parseCsv(requiredSkillEntriesCsv);

const state = { changed: false };

if (typeof doc !== "object" || doc === null || Array.isArray(doc)) {
  doc = {};
  state.changed = true;
}

const plugins = ensureObject(doc, "plugins", state);
const pluginEntries = ensureObject(plugins, "entries", state);
const skills = ensureObject(doc, "skills", state);
const skillEntries = ensureObject(skills, "entries", state);

if (plugins.enabled !== true) {
  plugins.enabled = true;
  state.changed = true;
}

let pluginEntriesEnabled = 0;
for (const pluginId of requiredPluginEntries) {
  const entry = ensureObject(pluginEntries, pluginId, state);
  if (entry.enabled !== true) {
    entry.enabled = true;
    state.changed = true;
  }
  pluginEntriesEnabled += 1;
}

if (!Array.isArray(plugins.allow)) {
  plugins.allow = [];
  state.changed = true;
}

const allowSet = new Set(plugins.allow.filter((item) => typeof item === "string"));
let pluginAllowAdded = 0;
for (const pluginId of requiredPluginAllow) {
  if (!allowSet.has(pluginId)) {
    allowSet.add(pluginId);
    pluginAllowAdded += 1;
    state.changed = true;
  }
}
if (pluginAllowAdded > 0) {
  plugins.allow = Array.from(allowSet);
}

let skillsEnabled = 0;
for (const skillId of requiredSkillEntries) {
  const entry = ensureObject(skillEntries, skillId, state);
  if (entry.enabled !== true) {
    entry.enabled = true;
    state.changed = true;
  }
  skillsEnabled += 1;
}

if (mode === "apply" && state.changed) {
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
    changed: state.changed,
    configPath,
    pluginEntriesEnabled,
    skillsEnabled,
    pluginAllowAdded,
    requiredPluginAllow,
    requiredPluginEntries,
    requiredSkillEntries,
  }),
);
NODE
