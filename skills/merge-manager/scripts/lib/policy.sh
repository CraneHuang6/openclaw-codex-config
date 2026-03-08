#!/usr/bin/env bash
# Minimal YAML-like policy loader for merge-manager MVP.
# Supports top-level scalars, top-level lists, and one nested mapping level.

_merge_manager_policy_query() {
  local policy_file="$1"
  local query_kind="$2"
  local key="$3"
  local nested="${4:-}"
  python3 - "$policy_file" "$query_kind" "$key" "$nested" <<'PY'
import sys
from pathlib import Path

policy_file, query_kind, key, nested = sys.argv[1:5]
text = Path(policy_file).read_text(encoding='utf-8')
root = {}
current_top = None
current_nested = None
for raw in text.splitlines():
    if not raw.strip() or raw.lstrip().startswith('#'):
        continue
    indent = len(raw) - len(raw.lstrip(' '))
    line = raw.strip()
    if indent == 0:
        current_nested = None
        if line.endswith(':'):
            current_top = line[:-1]
            root[current_top] = {}
        else:
            k, v = [part.strip() for part in line.split(':', 1)]
            root[k] = v.strip('"')
            current_top = None
    elif indent == 2:
        if line.startswith('- '):
            if current_top is None:
                continue
            root.setdefault(current_top, [])
            if isinstance(root[current_top], dict):
                root[current_top] = []
            root[current_top].append(line[2:].strip().strip('"'))
        elif line.endswith(':'):
            if current_top is None:
                continue
            current_nested = line[:-1]
            root.setdefault(current_top, {})
            root[current_top][current_nested] = []
        else:
            if current_top is None:
                continue
            k, v = [part.strip() for part in line.split(':', 1)]
            root.setdefault(current_top, {})
            root[current_top][k] = v.strip('"')
    elif indent == 4 and line.startswith('- '):
        if current_top is None or current_nested is None:
            continue
        root.setdefault(current_top, {})
        root[current_top].setdefault(current_nested, [])
        root[current_top][current_nested].append(line[2:].strip().strip('"'))

value = None
if query_kind == 'scalar':
    value = root.get(key)
elif query_kind == 'list':
    value = root.get(key, [])
elif query_kind == 'nested-list':
    value = root.get(key, {}).get(nested, [])
elif query_kind == 'nested-scalar':
    value = root.get(key, {}).get(nested)

if isinstance(value, list):
    for item in value:
        print(item)
elif value is not None:
    print(value)
PY
}

mm_policy_scalar() {
  local policy_file="$1"
  local key="$2"
  local fallback="${3:-}"
  local value
  value="$(_merge_manager_policy_query "$policy_file" scalar "$key" | sed -n '1p')"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

mm_policy_list() {
  local policy_file="$1"
  local key="$2"
  _merge_manager_policy_query "$policy_file" list "$key"
}

mm_policy_nested_list() {
  local policy_file="$1"
  local key="$2"
  local nested="$3"
  _merge_manager_policy_query "$policy_file" nested-list "$key" "$nested"
}

mm_policy_nested_scalar() {
  local policy_file="$1"
  local key="$2"
  local nested="$3"
  local fallback="${4:-}"
  local value
  value="$(_merge_manager_policy_query "$policy_file" nested-scalar "$key" "$nested" | sed -n '1p')"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}
