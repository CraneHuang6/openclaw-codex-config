#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_TEMPLATE="${OPENCLAW_AUTH_PROFILES_TEMPLATE:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.template.json}"
DEFAULT_OUTPUT="${OPENCLAW_AUTH_PROFILES_OUTPUT:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.json}"
DEFAULT_RENDER_SCRIPT="${OPENCLAW_AUTH_PROFILES_RENDER_SCRIPT:-$SCRIPT_DIR/render-auth-profiles-from-env.sh}"
DEFAULT_REQUIRED_PROFILES="kimi-coding:default,openrouter:default,voyage:default"
DEFAULT_REQUIRED_ENV_VARS="OPENCLAW_AUTH_KIMI_KEY,OPENCLAW_AUTH_OPENROUTER_KEY,OPENCLAW_AUTH_VOYAGE_KEY"

mode="apply"
template="$DEFAULT_TEMPLATE"
output="$DEFAULT_OUTPUT"
render_script="$DEFAULT_RENDER_SCRIPT"
required_profiles="$DEFAULT_REQUIRED_PROFILES"
required_env_vars="$DEFAULT_REQUIRED_ENV_VARS"

show_help() {
  cat <<'EOF'
Usage: ensure-openclaw-auth-profiles.sh [options]

Options:
  --dry-run                         Validate current auth profiles; report if render is needed.
  --apply                           Ensure auth profiles are ready (default).
  --template <path>                 Override auth template path.
  --output <path>                   Override auth profiles output path.
  --render-script <path>            Override render script path.
  --required-profiles <csv>         Required profiles with non-empty key fields.
  --required-env-vars <csv>         Required env vars when render is needed.
  -h, --help                        Show this help message.
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
    --render-script)
      if (($# < 2)); then
        echo "missing value for --render-script" >&2
        exit 2
      fi
      render_script="$2"
      shift 2
      ;;
    --required-profiles)
      if (($# < 2)); then
        echo "missing value for --required-profiles" >&2
        exit 2
      fi
      required_profiles="$2"
      shift 2
      ;;
    --required-env-vars)
      if (($# < 2)); then
        echo "missing value for --required-env-vars" >&2
        exit 2
      fi
      required_env_vars="$2"
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 binary not found in PATH" >&2
  exit 1
fi

if [[ ! -x "$render_script" ]]; then
  echo "render script not executable: $render_script" >&2
  exit 1
fi

split_csv() {
  local csv="$1"
  local IFS=','
  read -r -a items <<< "$csv"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [[ -n "$item" ]]; then
      printf '%s\n' "$item"
    fi
  done
}

check_auth_profiles() {
  python3 - "$output" "$required_profiles" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
required_profiles = [s.strip() for s in sys.argv[2].split(",") if s.strip()]

if not output_path.exists():
    print("missing\toutput_missing")
    raise SystemExit(1)

try:
    doc = json.loads(output_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"invalid\tjson_parse_failed:{exc}")
    raise SystemExit(1)

profiles = doc.get("profiles")
if not isinstance(profiles, dict):
    print("invalid\tprofiles_missing")
    raise SystemExit(1)

missing = []
for profile_id in required_profiles:
    entry = profiles.get(profile_id)
    if not isinstance(entry, dict):
        missing.append(f"{profile_id}:entry")
        continue
    key = entry.get("key")
    if not isinstance(key, str) or not key.strip():
        missing.append(f"{profile_id}:key")

if missing:
    print(f"invalid\tmissing_fields:{','.join(missing)}")
    raise SystemExit(1)

print("ready\tok")
PY
}

missing_env_vars=()
while IFS= read -r env_name; do
  if [[ -n "$env_name" && -z "${!env_name:-}" ]]; then
    missing_env_vars+=("$env_name")
  fi
done < <(split_csv "$required_env_vars")

set +e
check_out="$(check_auth_profiles 2>&1)"
check_code=$?
set -e

if (( check_code == 0 )); then
  echo "{\"ok\":true,\"mode\":\"$mode\",\"status\":\"ready\",\"changed\":false,\"output\":\"$output\"}"
  exit 0
fi

if [[ ! -f "$template" ]]; then
  echo "template not found: $template" >&2
  exit 1
fi

if (( ${#missing_env_vars[@]} > 0 )); then
  echo "missing required env vars: $(IFS=,; echo "${missing_env_vars[*]}")" >&2
  exit 1
fi

if [[ "$mode" == "dry-run" ]]; then
  echo "{\"ok\":true,\"mode\":\"dry-run\",\"status\":\"would_render\",\"changed\":true,\"output\":\"$output\"}"
  exit 0
fi

"$render_script" --template "$template" --output "$output" >/dev/null

set +e
verify_out="$(check_auth_profiles 2>&1)"
verify_code=$?
set -e
if (( verify_code != 0 )); then
  echo "rendered auth profiles failed validation: $verify_out" >&2
  exit 1
fi

echo "{\"ok\":true,\"mode\":\"apply\",\"status\":\"rendered\",\"changed\":true,\"output\":\"$output\"}"
