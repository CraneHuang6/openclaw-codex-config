#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$DEFAULT_OPENCLAW_HOME/openclaw.json}"
DEFAULT_AUTH_PROFILES_PATH="${OPENCLAW_AUTH_PROFILES_PATH:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.json}"
DEFAULT_FEISHU_TARGET_ROOT="/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src"
DEFAULT_RUNTIME_TARGET_ROOT="/opt/homebrew/lib/node_modules/openclaw/dist"
DEFAULT_NANO_BANANA_TARGET="/opt/homebrew/lib/node_modules/openclaw/skills/nano-banana-pro/scripts/generate_image.py"
DEFAULT_WORKSPACE_ROOT="${OPENCLAW_WORKSPACE_ROOT:-}"
DEFAULT_SNAPSHOT_DIR="${OPENCLAW_UPDATE_SNAPSHOT_DIR:-$DEFAULT_OPENCLAW_HOME/backup/update-snapshots}"
DEFAULT_LATEST_LINK="${OPENCLAW_UPDATE_SNAPSHOT_LATEST_LINK:-$DEFAULT_SNAPSHOT_DIR/latest}"
DEFAULT_OPENCLAW_BIN="${OPENCLAW_BIN:-/opt/homebrew/bin/openclaw}"

mode=""
snapshot_id=""
config_path="$DEFAULT_CONFIG_PATH"
auth_profiles_path="$DEFAULT_AUTH_PROFILES_PATH"
feishu_target_root="$DEFAULT_FEISHU_TARGET_ROOT"
runtime_target_root="$DEFAULT_RUNTIME_TARGET_ROOT"
nano_banana_target="$DEFAULT_NANO_BANANA_TARGET"
workspace_root="$DEFAULT_WORKSPACE_ROOT"
snapshot_dir="$DEFAULT_SNAPSHOT_DIR"
latest_link="$DEFAULT_LATEST_LINK"
openclaw_bin="$DEFAULT_OPENCLAW_BIN"
restart_gateway=true

show_help() {
  cat <<'EOF'
Usage: openclaw-update-snapshot-rollback.sh [options]

Options:
  --mode <snapshot|rollback>       Required action mode.
  --snapshot-id <id>               Rollback specific snapshot id (default: latest link).
  --config-path <path>             OpenClaw config path.
  --auth-profiles-path <path>      Runtime auth profiles path.
  --feishu-target-root <dir>       Feishu extension source root.
  --runtime-target-root <dir>      Runtime dist root.
  --nano-banana-target <path>      nano-banana generate_image.py path.
  --workspace-root <dir>           Workspace root for local repatch targets.
  --snapshot-dir <dir>             Snapshot storage directory.
  --latest-link <path>             Latest snapshot symlink path.
  --openclaw-bin <path>            openclaw binary path (for version/restart).
  --no-restart                     Do not restart gateway after rollback.
  -h, --help                       Show this help message.
EOF
}

while (($#)); do
  case "$1" in
    --mode)
      if (($# < 2)); then
        echo "missing value for --mode" >&2
        exit 2
      fi
      mode="$2"
      shift 2
      ;;
    --snapshot-id)
      if (($# < 2)); then
        echo "missing value for --snapshot-id" >&2
        exit 2
      fi
      snapshot_id="$2"
      shift 2
      ;;
    --config-path)
      if (($# < 2)); then
        echo "missing value for --config-path" >&2
        exit 2
      fi
      config_path="$2"
      shift 2
      ;;
    --auth-profiles-path)
      if (($# < 2)); then
        echo "missing value for --auth-profiles-path" >&2
        exit 2
      fi
      auth_profiles_path="$2"
      shift 2
      ;;
    --feishu-target-root)
      if (($# < 2)); then
        echo "missing value for --feishu-target-root" >&2
        exit 2
      fi
      feishu_target_root="$2"
      shift 2
      ;;
    --runtime-target-root)
      if (($# < 2)); then
        echo "missing value for --runtime-target-root" >&2
        exit 2
      fi
      runtime_target_root="$2"
      shift 2
      ;;
    --nano-banana-target)
      if (($# < 2)); then
        echo "missing value for --nano-banana-target" >&2
        exit 2
      fi
      nano_banana_target="$2"
      shift 2
      ;;
    --workspace-root)
      if (($# < 2)); then
        echo "missing value for --workspace-root" >&2
        exit 2
      fi
      workspace_root="$2"
      shift 2
      ;;
    --snapshot-dir)
      if (($# < 2)); then
        echo "missing value for --snapshot-dir" >&2
        exit 2
      fi
      snapshot_dir="$2"
      shift 2
      ;;
    --latest-link)
      if (($# < 2)); then
        echo "missing value for --latest-link" >&2
        exit 2
      fi
      latest_link="$2"
      shift 2
      ;;
    --openclaw-bin)
      if (($# < 2)); then
        echo "missing value for --openclaw-bin" >&2
        exit 2
      fi
      openclaw_bin="$2"
      shift 2
      ;;
    --no-restart)
      restart_gateway=false
      shift
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

if [[ "$mode" != "snapshot" && "$mode" != "rollback" ]]; then
  echo "mode must be one of: snapshot, rollback" >&2
  exit 2
fi

if [[ "$openclaw_bin" != */* ]]; then
  if ! command -v "$openclaw_bin" >/dev/null 2>&1; then
    echo "openclaw binary not found in PATH: $openclaw_bin" >&2
    exit 1
  fi
else
  if [[ ! -x "$openclaw_bin" ]]; then
    echo "openclaw binary not executable: $openclaw_bin" >&2
    exit 1
  fi
fi

mkdir -p "$snapshot_dir"

if [[ -z "$workspace_root" ]]; then
  workspace_root="$(dirname "$config_path")/workspace"
fi

gather_tracked_files() {
  TRACKED_FILES=()
  TRACKED_FILES+=("$config_path")
  TRACKED_FILES+=("$auth_profiles_path")
  TRACKED_FILES+=("$feishu_target_root/accounts.ts")
  TRACKED_FILES+=("$feishu_target_root/bot.ts")
  TRACKED_FILES+=("$feishu_target_root/dedup.ts")
  TRACKED_FILES+=("$feishu_target_root/reply-dispatcher.ts")
  TRACKED_FILES+=("$feishu_target_root/media.ts")
  TRACKED_FILES+=("$feishu_target_root/reply-voice-command.ts")
  TRACKED_FILES+=("$feishu_target_root/reply-voice-tts.ts")
  TRACKED_FILES+=("$runtime_target_root/daemon-cli.js")
  TRACKED_FILES+=("$runtime_target_root/entry.js")
  TRACKED_FILES+=("$nano_banana_target")
  TRACKED_FILES+=("$workspace_root/services/DidaAPI/models/base.py")
  TRACKED_FILES+=("$workspace_root/services/DidaAPI/routers/tasks.py")
  TRACKED_FILES+=("$workspace_root/skills/didaapi-task-manager/scripts/didaapi_manager.py")

  local f
  shopt -s nullglob
  for f in "$runtime_target_root"/gateway-cli-*.js; do
    TRACKED_FILES+=("$f")
  done
  for f in "$runtime_target_root"/reply-*.js; do
    TRACKED_FILES+=("$f")
  done
  for f in "$runtime_target_root"/redact-*.js; do
    TRACKED_FILES+=("$f")
  done
  for f in "$runtime_target_root"/run-main-*.js; do
    TRACKED_FILES+=("$f")
  done
  for f in "$runtime_target_root"/subsystem-*.js; do
    TRACKED_FILES+=("$f")
  done
  shopt -u nullglob
}

safe_rel_path() {
  local src="$1"
  src="${src#/}"
  printf '%s' "$src"
}

snapshot_mode() {
  gather_tracked_files
  local snap_id snap_path manifest_path copied_count version
  snap_id="$(date '+%Y%m%d-%H%M%S')-$$"
  snap_path="$snapshot_dir/$snap_id"
  manifest_path="$snap_path/manifest.tsv"
  copied_count=0
  version="$("$openclaw_bin" --version 2>/dev/null || echo unknown)"

  mkdir -p "$snap_path/files"
  : > "$manifest_path"

  local src rel dest
  for src in "${TRACKED_FILES[@]}"; do
    if [[ ! -f "$src" ]]; then
      continue
    fi
    rel="$(safe_rel_path "$src")"
    dest="$snap_path/files/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -p "$src" "$dest"
    printf '%s\t%s\n' "$src" "$rel" >> "$manifest_path"
    copied_count=$((copied_count + 1))
  done

  if (( copied_count == 0 )); then
    rm -rf "$snap_path"
    echo "{\"ok\":false,\"mode\":\"snapshot\",\"status\":\"no_files\",\"snapshotDir\":\"$snapshot_dir\"}" >&2
    exit 1
  fi

  cat > "$snap_path/meta.json" <<EOF
{"snapshotId":"$snap_id","createdAt":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","version":"$version","fileCount":$copied_count}
EOF
  ln -sfn "$snap_path" "$latest_link"
  echo "{\"ok\":true,\"mode\":\"snapshot\",\"snapshotId\":\"$snap_id\",\"snapshotPath\":\"$snap_path\",\"fileCount\":$copied_count}"
}

resolve_snapshot_path() {
  if [[ -n "$snapshot_id" ]]; then
    printf '%s' "$snapshot_dir/$snapshot_id"
    return 0
  fi

  if [[ -L "$latest_link" ]]; then
    local target
    target="$(readlink "$latest_link")"
    if [[ "$target" == /* ]]; then
      printf '%s' "$target"
    else
      printf '%s' "$(cd "$(dirname "$latest_link")" && cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    fi
    return 0
  fi

  if [[ -d "$latest_link" ]]; then
    printf '%s' "$latest_link"
    return 0
  fi

  return 1
}

rollback_mode() {
  local snap_path manifest_path restored_count src rel backup
  if ! snap_path="$(resolve_snapshot_path)"; then
    echo "{\"ok\":false,\"mode\":\"rollback\",\"status\":\"snapshot_not_found\",\"latestLink\":\"$latest_link\"}" >&2
    exit 1
  fi
  manifest_path="$snap_path/manifest.tsv"
  if [[ ! -f "$manifest_path" ]]; then
    echo "{\"ok\":false,\"mode\":\"rollback\",\"status\":\"manifest_missing\",\"snapshotPath\":\"$snap_path\"}" >&2
    exit 1
  fi

  restored_count=0
  while IFS=$'\t' read -r src rel; do
    [[ -n "$src" ]] || continue
    backup="$snap_path/files/$rel"
    if [[ ! -f "$backup" ]]; then
      continue
    fi
    mkdir -p "$(dirname "$src")"
    cp -p "$backup" "$src"
    restored_count=$((restored_count + 1))
  done < "$manifest_path"

  if [[ "$restart_gateway" == "true" ]]; then
    "$openclaw_bin" gateway restart >/dev/null 2>&1 || true
  fi

  echo "{\"ok\":true,\"mode\":\"rollback\",\"snapshotPath\":\"$snap_path\",\"restored\":$restored_count,\"restarted\":$restart_gateway}"
}

run_minimal_post_rollback_probes() {
  local status_out status_code probe_out probe_code security_out security_code
  set +e
  status_out="$($openclaw_bin status --deep 2>&1)"
  status_code=$?
  probe_out="$($openclaw_bin gateway probe 2>&1)"
  probe_code=$?
  security_out="$($openclaw_bin security audit --deep 2>&1)"
  security_code=$?
  set -e

  local result="pass"
  if (( status_code != 0 || probe_code != 0 || security_code != 0 )); then
    result="fail"
  fi

  echo "{\"ok\":$([[ \"$result\" == \"pass\" ]] && echo true || echo false),\"probe\":\"$result\",\"status_exit\":$status_code,\"probe_exit\":$probe_code,\"security_exit\":$security_code}"
  if [[ "$result" != "pass" ]]; then
    return 1
  fi
  return 0
}

if [[ "$mode" == "snapshot" ]]; then
  snapshot_mode
else
  rollback_mode
  run_minimal_post_rollback_probes
fi
