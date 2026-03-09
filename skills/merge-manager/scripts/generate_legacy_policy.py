#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
os.execv(sys.executable, [sys.executable, str(SCRIPT_DIR / 'derive_legacy_policy.py'), *sys.argv[1:]])
