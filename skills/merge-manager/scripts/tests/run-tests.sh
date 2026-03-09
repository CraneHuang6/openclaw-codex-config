#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$ROOT/tests/test-github-gates.sh"
bash "$ROOT/tests/test-dry-run-compat.sh"
