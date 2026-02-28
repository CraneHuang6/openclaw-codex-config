#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_TEMPLATE="${OPENCLAW_AUTH_PROFILES_TEMPLATE:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.template.json}"
DEFAULT_OUTPUT="${OPENCLAW_AUTH_PROFILES_OUTPUT:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.json}"

template="$DEFAULT_TEMPLATE"
output="$DEFAULT_OUTPUT"

show_help() {
  cat <<'HELP'
Usage: render-auth-profiles-from-env.sh [options]

Options:
  --template <path>   Input template JSON path.
  --output <path>     Output auth-profiles.json path.
  -h, --help          Show this help message.
HELP
}

while (($#)); do
  case "$1" in
    --template)
      if (($# < 2)); then
        echo "missing value for --template" >&2
        exit 2
      fi
      template="$2"
      shift 2
      ;;
    --output)
      if (($# < 2)); then
        echo "missing value for --output" >&2
        exit 2
      fi
      output="$2"
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

if [[ ! -f "$template" ]]; then
  echo "template not found: $template" >&2
  exit 1
fi

python3 - "$template" "$output" <<'PY'
import json
import os
import sys
from pathlib import Path

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

replacements = {
    "__ENV:OPENCLAW_AUTH_KIMI_KEY__": "OPENCLAW_AUTH_KIMI_KEY",
    "__ENV:OPENCLAW_AUTH_OPENROUTER_KEY__": "OPENCLAW_AUTH_OPENROUTER_KEY",
    "__ENV:OPENCLAW_AUTH_VOYAGE_KEY__": "OPENCLAW_AUTH_VOYAGE_KEY",
}

missing = []


def render(value):
    if isinstance(value, dict):
        return {k: render(v) for k, v in value.items()}
    if isinstance(value, list):
        return [render(v) for v in value]
    if isinstance(value, str) and value in replacements:
        env_name = replacements[value]
        env_value = os.environ.get(env_name, "")
        if not env_value:
            missing.append(env_name)
            return value
        return env_value
    return value

with template_path.open("r", encoding="utf-8") as f:
    doc = json.load(f)

rendered = render(doc)

if missing:
    uniq = ",".join(sorted(set(missing)))
    print(f"missing required env vars: {uniq}", file=sys.stderr)
    raise SystemExit(1)

output_path.parent.mkdir(parents=True, exist_ok=True)
with output_path.open("w", encoding="utf-8") as f:
    json.dump(rendered, f, ensure_ascii=False, indent=2)
    f.write("\n")

os.chmod(output_path, 0o600)
print(str(output_path))
PY
