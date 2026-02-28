#!/usr/bin/env bash
set -euo pipefail

DEFAULT_RELEASE_API="${OPENCLAW_DMG_RELEASE_API:-https://api.github.com/repos/openclaw/openclaw/releases/latest}"
DEFAULT_DOWNLOAD_DIR="${OPENCLAW_DMG_DOWNLOAD_DIR:-$HOME/.openclaw/tmp}"
DEFAULT_MOUNT_BASE="${OPENCLAW_DMG_MOUNT_BASE:-/tmp}"
DEFAULT_TARGET_APP="${OPENCLAW_DMG_TARGET_APP:-/Applications/OpenClaw.app}"
DEFAULT_APP_NAME="${OPENCLAW_DMG_APP_NAME:-OpenClaw.app}"
DEFAULT_CURL_BIN="${OPENCLAW_DMG_CURL_BIN:-curl}"
DEFAULT_HDIUTIL_BIN="${OPENCLAW_DMG_HDIUTIL_BIN:-hdiutil}"
DEFAULT_DITTO_BIN="${OPENCLAW_DMG_DITTO_BIN:-ditto}"
DEFAULT_PYTHON_BIN="${OPENCLAW_DMG_PYTHON_BIN:-python3}"

dry_run=false
release_api="$DEFAULT_RELEASE_API"
dmg_url=""
dmg_path=""
download_dir="$DEFAULT_DOWNLOAD_DIR"
mount_base="$DEFAULT_MOUNT_BASE"
target_app="$DEFAULT_TARGET_APP"
app_name="$DEFAULT_APP_NAME"
keep_download=false
curl_bin="$DEFAULT_CURL_BIN"
hdiutil_bin="$DEFAULT_HDIUTIL_BIN"
ditto_bin="$DEFAULT_DITTO_BIN"
python_bin="$DEFAULT_PYTHON_BIN"

show_help() {
  cat <<'USAGE'
Usage: install-openclaw-latest-dmg.sh [options]

Options:
  --apply                    Install dmg (default mode).
  --dry-run                  Resolve dmg source only, do not install.
  --release-api <url>        Override GitHub latest release API URL.
  --dmg-url <url>            Explicit dmg URL (skip API lookup).
  --dmg-path <path>          Use local dmg file (skip API lookup/download).
  --download-dir <dir>       Download directory for dmg.
  --mount-base <dir>         Base directory for temporary mount point.
  --target-app <path>        Target OpenClaw app path.
  --app-name <name>          App bundle name inside dmg (default: OpenClaw.app).
  --keep-download            Keep downloaded dmg file.
  --curl-bin <path-or-name>  Override curl binary.
  --hdiutil-bin <path-or-name> Override hdiutil binary.
  --ditto-bin <path-or-name> Override ditto binary.
  --python-bin <path-or-name> Override python binary.
  -h, --help                 Show this help message.
USAGE
}

while (($#)); do
  case "$1" in
    --apply)
      dry_run=false
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --release-api)
      if (($# < 2)); then
        echo "missing value for --release-api" >&2
        exit 2
      fi
      release_api="$2"
      shift 2
      ;;
    --dmg-url)
      if (($# < 2)); then
        echo "missing value for --dmg-url" >&2
        exit 2
      fi
      dmg_url="$2"
      shift 2
      ;;
    --dmg-path)
      if (($# < 2)); then
        echo "missing value for --dmg-path" >&2
        exit 2
      fi
      dmg_path="$2"
      shift 2
      ;;
    --download-dir)
      if (($# < 2)); then
        echo "missing value for --download-dir" >&2
        exit 2
      fi
      download_dir="$2"
      shift 2
      ;;
    --mount-base)
      if (($# < 2)); then
        echo "missing value for --mount-base" >&2
        exit 2
      fi
      mount_base="$2"
      shift 2
      ;;
    --target-app)
      if (($# < 2)); then
        echo "missing value for --target-app" >&2
        exit 2
      fi
      target_app="$2"
      shift 2
      ;;
    --app-name)
      if (($# < 2)); then
        echo "missing value for --app-name" >&2
        exit 2
      fi
      app_name="$2"
      shift 2
      ;;
    --keep-download)
      keep_download=true
      shift
      ;;
    --curl-bin)
      if (($# < 2)); then
        echo "missing value for --curl-bin" >&2
        exit 2
      fi
      curl_bin="$2"
      shift 2
      ;;
    --hdiutil-bin)
      if (($# < 2)); then
        echo "missing value for --hdiutil-bin" >&2
        exit 2
      fi
      hdiutil_bin="$2"
      shift 2
      ;;
    --ditto-bin)
      if (($# < 2)); then
        echo "missing value for --ditto-bin" >&2
        exit 2
      fi
      ditto_bin="$2"
      shift 2
      ;;
    --python-bin)
      if (($# < 2)); then
        echo "missing value for --python-bin" >&2
        exit 2
      fi
      python_bin="$2"
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

require_cmd() {
  local bin="$1"
  if [[ "$bin" == */* ]]; then
    [[ -x "$bin" ]] || {
      echo "binary not executable: $bin" >&2
      exit 1
    }
  elif ! command -v "$bin" >/dev/null 2>&1; then
    echo "binary not found in PATH: $bin" >&2
    exit 1
  fi
}

require_cmd "$curl_bin"
require_cmd "$python_bin"
if [[ "$dry_run" == "false" ]]; then
  require_cmd "$hdiutil_bin"
  require_cmd "$ditto_bin"
fi

resolve_latest_asset() {
  local release_json="$1"
  RELEASE_JSON="$release_json" "$python_bin" - <<'PY'
import json
import os

raw = os.environ.get("RELEASE_JSON", "")
if not raw:
    raise SystemExit(1)
release = json.loads(raw)
assets = release.get("assets") or []
if not isinstance(assets, list):
    raise SystemExit(1)

scored = []
for asset in assets:
    if not isinstance(asset, dict):
        continue
    name = str(asset.get("name") or "")
    url = str(asset.get("browser_download_url") or "")
    if not name.lower().endswith(".dmg") or not url:
        continue
    score = 0
    lowered = name.lower()
    if "mac" in lowered or "darwin" in lowered:
        score += 10
    if "arm64" in lowered or "aarch64" in lowered:
        score += 3
    if "universal" in lowered:
        score += 2
    scored.append((score, name, url))

if not scored:
    raise SystemExit(1)

scored.sort(key=lambda x: (x[0], x[1]), reverse=True)
best = scored[0]
print(best[1])
print(best[2])
PY
}

release_tag=""
asset_name=""

if [[ -z "$dmg_path" && -z "$dmg_url" ]]; then
  release_json="$($curl_bin -fsSL "$release_api")"
  release_tag="$(RELEASE_JSON="$release_json" "$python_bin" - <<'PY'
import json
import os
raw = os.environ.get("RELEASE_JSON", "").strip()
obj = json.loads(raw)
print(obj.get("tag_name") or "")
PY
)"
  asset_fields="$(resolve_latest_asset "$release_json")"
  asset_name="$(printf '%s\n' "$asset_fields" | sed -n '1p')"
  dmg_url="$(printf '%s\n' "$asset_fields" | sed -n '2p')"
fi

if [[ -n "$dmg_path" && ! -f "$dmg_path" ]]; then
  echo "dmg file not found: $dmg_path" >&2
  exit 1
fi

if [[ "$dry_run" == "true" ]]; then
  printf 'mode=dry-run\n'
  printf 'release_tag=%s\n' "$release_tag"
  printf 'asset_name=%s\n' "$asset_name"
  printf 'dmg_url=%s\n' "$dmg_url"
  printf 'dmg_path=%s\n' "$dmg_path"
  exit 0
fi

downloaded_dmg=""
if [[ -z "$dmg_path" ]]; then
  mkdir -p "$download_dir"
  if [[ -n "$asset_name" ]]; then
    downloaded_dmg="$download_dir/$asset_name"
  else
    downloaded_dmg="$download_dir/openclaw-latest.dmg"
  fi
  $curl_bin -fL --retry 2 --connect-timeout 15 --max-time 1800 -o "$downloaded_dmg" "$dmg_url"
  dmg_path="$downloaded_dmg"
fi

if [[ ! -f "$dmg_path" ]]; then
  echo "dmg file not found after resolve: $dmg_path" >&2
  exit 1
fi

mkdir -p "$mount_base"
mount_point="$mount_base/openclaw-dmg-$RANDOM-$$"
mkdir -p "$mount_point"

mounted=false
cleanup() {
  if [[ "$mounted" == "true" ]]; then
    "$hdiutil_bin" detach "$mount_point" -quiet >/dev/null 2>&1 || true
  fi
  rmdir "$mount_point" >/dev/null 2>&1 || true
  if [[ -n "$downloaded_dmg" && "$keep_download" != "true" ]]; then
    rm -f "$downloaded_dmg"
  fi
}
trap cleanup EXIT

"$hdiutil_bin" attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" -quiet
mounted=true

app_source="$mount_point/$app_name"
if [[ ! -d "$app_source" ]]; then
  app_source="$(find "$mount_point" -maxdepth 4 -type d -name "$app_name" | head -n1 || true)"
fi
if [[ -z "$app_source" || ! -d "$app_source" ]]; then
  echo "app bundle not found in dmg: $app_name" >&2
  exit 1
fi

mkdir -p "$(dirname "$target_app")"
"$ditto_bin" "$app_source" "$target_app"

printf 'mode=apply\n'
printf 'release_tag=%s\n' "$release_tag"
printf 'asset_name=%s\n' "$asset_name"
printf 'dmg_path=%s\n' "$dmg_path"
printf 'installed_app=%s\n' "$target_app"
