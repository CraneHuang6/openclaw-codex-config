#!/usr/bin/env bash
# Validation helpers for merge-manager dry-run.
# Shared read-only core only: detect which validation commands apply.

mm_command_applicable_for_repo() {
  local repo_root="$1"
  local command="$2"
  python3 - "$repo_root" "$command" <<'PY'
import json
import pathlib
import shlex
import sys

repo = pathlib.Path(sys.argv[1])
command = sys.argv[2]
try:
    parts = shlex.split(command)
except ValueError:
    raise SystemExit(1)
if not parts:
    raise SystemExit(1)

package_json = repo / 'package.json'
package_scripts = {}
if package_json.exists():
    try:
        package_scripts = json.loads(package_json.read_text(encoding='utf-8')).get('scripts', {})
    except Exception:
        package_scripts = {}

python_markers = [
    repo / 'pyproject.toml',
    repo / 'requirements.txt',
    repo / 'setup.cfg',
    repo / 'tox.ini',
    repo / 'tests',
]


def repo_path(raw: str) -> pathlib.Path:
    path = pathlib.Path(raw)
    return path if path.is_absolute() else repo / path


def script_exists(script_name: str) -> bool:
    return bool(package_scripts.get(script_name))

head = parts[0]
allowed = False

if head in {'npm', 'pnpm', 'bun'}:
    if package_json.exists():
        if len(parts) >= 3 and parts[1] == 'run':
            allowed = script_exists(parts[2])
        elif len(parts) >= 2 and parts[1] == 'test':
            allowed = script_exists('test')
elif head == 'yarn':
    if package_json.exists() and len(parts) >= 2:
        allowed = script_exists(parts[1])
elif head in {'pytest', 'tox'}:
    allowed = any(marker.exists() for marker in python_markers)
elif head in {'python', 'python3', 'python3.11'}:
    if len(parts) >= 3 and parts[1] == '-m' and parts[2] == 'pytest':
        allowed = any(marker.exists() for marker in python_markers)
    elif len(parts) >= 2 and parts[1].endswith('.py'):
        allowed = repo_path(parts[1]).exists()
elif head == 'uv':
    allowed = len(parts) >= 3 and parts[1] == 'run' and parts[2] == 'pytest' and any(marker.exists() for marker in python_markers)
elif head == 'cargo':
    allowed = (repo / 'Cargo.toml').exists()
elif head == 'go':
    allowed = (repo / 'go.mod').exists() and len(parts) >= 2 and parts[1] == 'test'
elif head == 'make':
    allowed = (repo / 'Makefile').exists()
elif head == 'just':
    allowed = (repo / 'justfile').exists() or (repo / 'Justfile').exists()
elif head in {'bash', 'sh', 'zsh'}:
    allowed = len(parts) >= 2 and repo_path(parts[1]).exists()
elif '/' in head or head.startswith('.'):
    allowed = repo_path(head).exists()

raise SystemExit(0 if allowed else 1)
PY
}

mm_emit_unique_commands() {
  awk '!seen[$0]++'
}

mm_detect_validation_commands() {
  local repo_root="$1"
  local policy_file="$2"
  local detect_if_missing
  detect_if_missing="$(mm_policy_nested_scalar "$policy_file" validation_commands detect_if_missing true)"

  local explicit=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    explicit+=("$cmd")
  done < <(mm_policy_nested_list "$policy_file" validation_commands explicit)

  local preferred=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    preferred+=("$cmd")
  done < <(mm_policy_nested_list "$policy_file" validation_commands preferred)

  local conservative_root_scripts=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    conservative_root_scripts+=("$cmd")
  done < <(mm_policy_nested_list "$policy_file" validation_commands conservative_root_scripts)

  local found=()
  local cmd
  for cmd in "${explicit[@]-}"; do
    if mm_command_applicable_for_repo "$repo_root" "$cmd"; then
      found+=("$cmd")
    fi
  done

  if [[ "${#found[@]}" -eq 0 && "$detect_if_missing" == "true" ]]; then
    for cmd in "${preferred[@]-}"; do
      if mm_command_applicable_for_repo "$repo_root" "$cmd"; then
        found+=("$cmd")
      fi
    done

    if [[ "${#found[@]}" -eq 0 ]]; then
      for cmd in "${conservative_root_scripts[@]-}"; do
        if mm_command_applicable_for_repo "$repo_root" "$cmd"; then
          found+=("$cmd")
        fi
      done
    fi
  fi

  if [[ "${#found[@]}" -gt 0 ]]; then
    printf '%s\n' "${found[@]}" | mm_emit_unique_commands
  fi
}
