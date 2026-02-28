#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SOURCE_SKILL_DIR="${OPENCLAW_SKILL_SYNC_SOURCE_SKILL_DIR:-$SKILL_DIR}"
DEFAULT_SOURCE_SCRIPTS_DIR="${OPENCLAW_SKILL_SYNC_SOURCE_SCRIPTS_DIR:-$HOME/.openclaw/scripts}"

mode="apply"
source_skill_dir="$DEFAULT_SOURCE_SKILL_DIR"
source_scripts_dir="$DEFAULT_SOURCE_SCRIPTS_DIR"

show_help() {
  cat <<'HELP'
Usage: sync-from-openclaw.sh [options]

Copy required local update/repatch scripts from ~/.openclaw/scripts into this Codex skill,
and refresh skill docs/wrapper from a source skill directory (defaults to this Codex skill itself),
then rewrite script defaults to prefer the local (self-contained) copies.

Options:
  --apply                      Copy + rewrite files (default).
  --dry-run                    Print planned copy list and exit.
  --source-skill-dir <path>    Override source skill directory for SKILL/docs/wrapper (default: this Codex skill).
  --source-scripts-dir <path>  Override source OpenClaw scripts directory.
  -h, --help                   Show this help message.
HELP
}

while (($#)); do
  case "$1" in
    --apply)
      mode="apply"
      shift
      ;;
    --dry-run)
      mode="dry-run"
      shift
      ;;
    --source-skill-dir)
      if (($# < 2)); then
        echo "missing value for --source-skill-dir" >&2
        exit 2
      fi
      source_skill_dir="$2"
      shift 2
      ;;
    --source-scripts-dir)
      if (($# < 2)); then
        echo "missing value for --source-scripts-dir" >&2
        exit 2
      fi
      source_scripts_dir="$2"
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

skill_files=(
  "SKILL.md"
  "agents/openai.yaml"
  "references/update-flow-cheatsheet.md"
  "scripts/run_openclaw_update_flow.sh"
)

script_files=(
  "daily-auto-update-local.sh"
  "extract-openclaw-update-report-summary.py"
  "append-openclaw-update-memory.sh"
  "openclaw-update-known-bug-fix.sh"
  "update-openclaw-with-feishu-repatch.sh"
  "openclaw-update-snapshot-rollback.sh"
  "install-daily-auto-update-launchd.sh"
  "install-openclaw-latest-dmg.sh"
  "update-installed-skills.sh"
  "render-auth-profiles-from-env.sh"
  "enforce-openclaw-kimi-model.sh"
  "enforce-openclaw-media-transcribe-bins.sh"
  "enforce-openclaw-plugin-skill-deps.sh"
  "ensure-openclaw-auth-profiles.sh"
  "repatch-openclaw-feishu-account-id-import.sh"
  "repatch-openclaw-feishu-video-media.sh"
  "repatch-openclaw-feishu-dedup-hardening.sh"
  "repatch-openclaw-feishu-reply-media.sh"
  "repatch-openclaw-feishu-reply-voice.sh"
  "repatch-openclaw-feishu-media-path.sh"
  "repatch-openclaw-nano-banana-model.sh"
  "repatch-didaapi-subtasks.sh"
  "patch-openclaw-runtime-hardening.mjs"
  "patch-openclaw-feishu-video-media.mjs"
  "patch-openclaw-feishu-dedup-hardening.mjs"
  "patch-openclaw-feishu-reply-media.mjs"
  "patch-openclaw-feishu-reply-voice.mjs"
  "patch-openclaw-feishu-media-path.mjs"
  "patch-didaapi-subtasks.py"
)

for rel in "${skill_files[@]}"; do
  src="$source_skill_dir/$rel"
  if [[ ! -f "$src" ]]; then
    echo "missing source file: $src" >&2
    exit 1
  fi
  printf 'skill-file=%s\n' "$rel"
done

for rel in "${script_files[@]}"; do
  src="$source_scripts_dir/$rel"
  if [[ ! -f "$src" ]]; then
    echo "missing source script: $src" >&2
    exit 1
  fi
  printf 'script-file=%s\n' "$rel"
done

if [[ "$mode" == "dry-run" ]]; then
  echo "mode=dry-run"
  echo "source_skill_dir=$source_skill_dir"
  echo "source_scripts_dir=$source_scripts_dir"
  echo "dest_skill_dir=$SKILL_DIR"
  exit 0
fi

mkdir -p "$SKILL_DIR/agents" "$SKILL_DIR/references" "$SKILL_DIR/scripts"

copy_file() {
  local src="$1" dst="$2"
  if [[ "$src" == "$dst" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  if [[ -x "$src" ]]; then
    chmod +x "$dst"
  fi
}

for rel in "${skill_files[@]}"; do
  copy_file "$source_skill_dir/$rel" "$SKILL_DIR/$rel"
done

for rel in "${script_files[@]}"; do
  copy_file "$source_scripts_dir/$rel" "$SKILL_DIR/scripts/$rel"
done

python3 - "$SKILL_DIR" <<'PY'
import pathlib
import re
import sys

skill_dir = pathlib.Path(sys.argv[1])
scripts_dir = skill_dir / "scripts"


def must_replace(text: str, old: str, new: str, path: pathlib.Path) -> str:
    if old not in text:
        raise SystemExit(f"patch failed: expected text not found in {path}: {old}")
    return text.replace(old, new)


def write(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def patch_add_script_dir(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    marker = 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
    if marker in text:
        return
    text = must_replace(
        text,
        "set -euo pipefail\n\n",
        "set -euo pipefail\n\n" + marker,
        path,
    )
    write(path, text)

# 1) Wrapper script: use local copies inside this skill.
path = scripts_dir / "run_openclaw_update_flow.sh"
text = path.read_text(encoding="utf-8")
if 'DAILY_SCRIPT="${OPENCLAW_SKILL_DAILY_SCRIPT:-$SCRIPT_DIR/daily-auto-update-local.sh}"' not in text:
    text = must_replace(text, "set -euo pipefail\n\n", "set -euo pipefail\n\nSCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n\n", path)
    text = must_replace(text, 'DAILY_SCRIPT="$OPENCLAW_HOME/scripts/daily-auto-update-local.sh"', 'DAILY_SCRIPT="${OPENCLAW_SKILL_DAILY_SCRIPT:-$SCRIPT_DIR/daily-auto-update-local.sh}"', path)
    text = must_replace(text, 'UNIFIED_PATCH_SCRIPT="$OPENCLAW_HOME/scripts/update-openclaw-with-feishu-repatch.sh"', 'UNIFIED_PATCH_SCRIPT="${OPENCLAW_SKILL_UNIFIED_PATCH_SCRIPT:-$SCRIPT_DIR/update-openclaw-with-feishu-repatch.sh}"', path)
    text = must_replace(text, 'LAUNCHD_SCRIPT="$OPENCLAW_HOME/scripts/install-daily-auto-update-launchd.sh"', 'LAUNCHD_SCRIPT="${OPENCLAW_SKILL_LAUNCHD_SCRIPT:-$SCRIPT_DIR/install-daily-auto-update-launchd.sh}"', path)
    path.write_text(text, encoding="utf-8")

# 2) daily script defaults -> local copies (self-contained).
path = scripts_dir / "daily-auto-update-local.sh"
patch_add_script_dir(path)
text = path.read_text(encoding="utf-8")
text = must_replace(
    text,
    'DEFAULT_UPDATE_SCRIPT="${OPENCLAW_DAILY_UPDATE_SCRIPT:-$DEFAULT_OPENCLAW_HOME/scripts/update-openclaw-with-feishu-repatch.sh}"',
    'DEFAULT_UPDATE_SCRIPT="${OPENCLAW_DAILY_UPDATE_SCRIPT:-$SCRIPT_DIR/update-openclaw-with-feishu-repatch.sh}"',
    path,
)
text = must_replace(
    text,
    'DEFAULT_SNAPSHOT_SCRIPT="${OPENCLAW_DAILY_UPDATE_SNAPSHOT_SCRIPT:-$DEFAULT_OPENCLAW_HOME/scripts/openclaw-update-snapshot-rollback.sh}"',
    'DEFAULT_SNAPSHOT_SCRIPT="${OPENCLAW_DAILY_UPDATE_SNAPSHOT_SCRIPT:-$SCRIPT_DIR/openclaw-update-snapshot-rollback.sh}"',
    path,
)
text = must_replace(
    text,
    'skills_sync_script="${OPENCLAW_DAILY_UPDATE_SKILLS_SYNC_SCRIPT:-}"',
    'skills_sync_script="${OPENCLAW_DAILY_UPDATE_SKILLS_SYNC_SCRIPT:-$SCRIPT_DIR/update-installed-skills.sh}"',
    path,
)
write(path, text)

# 3) unified update script defaults -> local script dir.
path = scripts_dir / "update-openclaw-with-feishu-repatch.sh"
patch_add_script_dir(path)
text = path.read_text(encoding="utf-8")
if 'SELF_SCRIPT_DIR="${OPENCLAW_UPDATE_SKILL_SCRIPTS_DIR:-$SCRIPT_DIR}"' not in text:
    text = must_replace(
        text,
        'DEFAULT_NODE_BIN="node"\n',
        'DEFAULT_NODE_BIN="node"\nSELF_SCRIPT_DIR="${OPENCLAW_UPDATE_SKILL_SCRIPTS_DIR:-$SCRIPT_DIR}"\n',
        path,
    )
for name in [
    "repatch-openclaw-feishu-account-id-import.sh",
    "repatch-openclaw-feishu-video-media.sh",
    "repatch-openclaw-feishu-dedup-hardening.sh",
    "repatch-openclaw-feishu-reply-media.sh",
    "repatch-openclaw-feishu-reply-voice.sh",
    "repatch-openclaw-feishu-media-path.sh",
    "patch-openclaw-runtime-hardening.mjs",
    "enforce-openclaw-kimi-model.sh",
    "enforce-openclaw-media-transcribe-bins.sh",
    "enforce-openclaw-plugin-skill-deps.sh",
    "ensure-openclaw-auth-profiles.sh",
    "repatch-didaapi-subtasks.sh",
    "install-openclaw-latest-dmg.sh",
]:
    old = f'/Users/crane/.openclaw/scripts/{name}'
    new = f'${{SELF_SCRIPT_DIR}}/{name}'
    text = text.replace(old, new)
write(path, text)

# 4) launchd installer -> local daily script (logs still go to ~/.openclaw/logs).
path = scripts_dir / "install-daily-auto-update-launchd.sh"
patch_add_script_dir(path)
text = path.read_text(encoding="utf-8")
text = text.replace('/Users/crane/.openclaw/scripts/daily-auto-update-local.sh', '${SCRIPT_DIR}/daily-auto-update-local.sh')
write(path, text)

# 5) repatch scripts -> local patchers.
repatch_files = [
    "repatch-openclaw-feishu-dedup-hardening.sh",
    "repatch-openclaw-feishu-media-path.sh",
    "repatch-openclaw-feishu-reply-media.sh",
    "repatch-openclaw-feishu-reply-voice.sh",
    "repatch-openclaw-feishu-video-media.sh",
    "repatch-didaapi-subtasks.sh",
]
for rel in repatch_files:
    path = scripts_dir / rel
    patch_add_script_dir(path)
    text = path.read_text(encoding="utf-8")
    patcher_map = {
        "repatch-openclaw-feishu-dedup-hardening.sh": "patch-openclaw-feishu-dedup-hardening.mjs",
        "repatch-openclaw-feishu-media-path.sh": "patch-openclaw-feishu-media-path.mjs",
        "repatch-openclaw-feishu-reply-media.sh": "patch-openclaw-feishu-reply-media.mjs",
        "repatch-openclaw-feishu-reply-voice.sh": "patch-openclaw-feishu-reply-voice.mjs",
        "repatch-openclaw-feishu-video-media.sh": "patch-openclaw-feishu-video-media.mjs",
        "repatch-didaapi-subtasks.sh": "patch-didaapi-subtasks.py",
    }
    patcher_name = patcher_map[rel]
    text = must_replace(
        text,
        f'PATCHER="/Users/crane/.openclaw/scripts/{patcher_name}"',
        f'PATCHER="$SCRIPT_DIR/{patcher_name}"',
        path,
    )
    # Make DidaAPI workspace root user-agnostic.
    text = text.replace('DEFAULT_WORKSPACE_ROOT="/Users/crane/.openclaw/workspace"', 'DEFAULT_WORKSPACE_ROOT="${OPENCLAW_HOME:-$HOME/.openclaw}/workspace"')
    write(path, text)

# 6) Auth profile guard/render defaults: keep OpenClaw data paths, localize render-script path.
path = scripts_dir / "ensure-openclaw-auth-profiles.sh"
patch_add_script_dir(path)
text = path.read_text(encoding="utf-8")
if 'DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"' not in text:
    text = must_replace(text, 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n', 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nDEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"\n', path)
text = must_replace(text, 'DEFAULT_TEMPLATE="/Users/crane/.openclaw/agents/main/agent/auth-profiles.template.json"', 'DEFAULT_TEMPLATE="${OPENCLAW_AUTH_PROFILES_TEMPLATE:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.template.json}"', path)
text = must_replace(text, 'DEFAULT_OUTPUT="/Users/crane/.openclaw/agents/main/agent/auth-profiles.json"', 'DEFAULT_OUTPUT="${OPENCLAW_AUTH_PROFILES_OUTPUT:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.json}"', path)
text = must_replace(text, 'DEFAULT_RENDER_SCRIPT="/Users/crane/.openclaw/scripts/render-auth-profiles-from-env.sh"', 'DEFAULT_RENDER_SCRIPT="${OPENCLAW_AUTH_PROFILES_RENDER_SCRIPT:-$SCRIPT_DIR/render-auth-profiles-from-env.sh}"', path)
write(path, text)

path = scripts_dir / "render-auth-profiles-from-env.sh"
patch_add_script_dir(path)
text = path.read_text(encoding="utf-8")
if 'DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"' not in text:
    text = must_replace(text, 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n', 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nDEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"\n', path)
text = must_replace(text, 'DEFAULT_TEMPLATE="/Users/crane/.openclaw/agents/main/agent/auth-profiles.template.json"', 'DEFAULT_TEMPLATE="${OPENCLAW_AUTH_PROFILES_TEMPLATE:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.template.json}"', path)
text = must_replace(text, 'DEFAULT_OUTPUT="/Users/crane/.openclaw/agents/main/agent/auth-profiles.json"', 'DEFAULT_OUTPUT="${OPENCLAW_AUTH_PROFILES_OUTPUT:-$DEFAULT_OPENCLAW_HOME/agents/main/agent/auth-profiles.json}"', path)
write(path, text)

# 7) Docs: point wrapper commands to Codex skill path + add sync instructions.
for rel in ["SKILL.md", "references/update-flow-cheatsheet.md"]:
    path = skill_dir / rel
    text = path.read_text(encoding="utf-8")
    text = re.sub(
        r"/Users/crane/(?:\\.openclaw/workspace|\\.codex)/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow\\.sh",
        "/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh",
        text,
    )
    path.write_text(text, encoding="utf-8")

skill_md = skill_dir / "SKILL.md"
text = skill_md.read_text(encoding="utf-8")
anchor = "## Guardrails\n"
insert = "## Sync (Self-Contained Scripts)\n\n- 本技能包含本地自包含脚本副本（`scripts/`），默认优先调用同目录脚本。\n- 当 `~/.openclaw/scripts` 有更新时，先执行同步脚本再使用本技能：\n  - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/sync-from-openclaw.sh --apply`\n- 同步脚本会从 source skill 目录（默认本技能目录）与 `~/.openclaw/scripts` 复制并重写入口脚本路径。\n\n"
if "sync-from-openclaw.sh --apply" not in text:
    text = must_replace(text, anchor, insert + anchor, skill_md)
    skill_md.write_text(text, encoding="utf-8")

cheat = skill_dir / "references/update-flow-cheatsheet.md"
text = cheat.read_text(encoding="utf-8")
anchor = "## 单独安装最新 OpenClaw dmg\n"
insert = "## 同步 Codex 自包含脚本\n\n```bash\n# 从 ~/.openclaw 同步技能文档 + 更新/补丁脚本，并重写为同目录优先\nbash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/sync-from-openclaw.sh --apply\n```\n\n"
if "同步 Codex 自包含脚本" not in text:
    text = must_replace(text, anchor, insert + anchor, cheat)
    cheat.write_text(text, encoding="utf-8")
PY

chmod +x "$SCRIPT_DIR"/*.sh || true
chmod +x "$SCRIPT_DIR"/*.py || true

echo "mode=apply"
echo "source_skill_dir=$source_skill_dir"
echo "source_scripts_dir=$source_scripts_dir"
echo "dest_skill_dir=$SKILL_DIR"
echo "synced_skill_files=${#skill_files[@]}"
echo "synced_script_files=${#script_files[@]}"
