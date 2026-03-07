#!/usr/bin/env python3
"""
Synchronize OpenClaw/Claude model selection files after a model upgrade.

This script only touches a fixed allowlist of 10 static config files, and can
also inspect/fix runtime cron model drift plus stale cron sessions.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple


TARGET_OPENCLAW_FILES = [
    "openclaw_codex.json",
    "openclaw.json",
    "agents/main/agent/models.json",
    "scripts/daily-auto-update-local.sh",
    "scripts/update-openclaw-with-feishu-repatch.sh",
    "scripts/enforce-openclaw-kimi-model.sh",
    "scripts/tests/daily-auto-update-local.test.sh",
    "scripts/tests/enforce-openclaw-kimi-model.test.sh",
    "scripts/tests/update-openclaw-with-feishu-repatch.test.sh",
]

TARGET_CLAUDE_FILE = ".claude/settings.json"
RUNTIME_CRON_MODES = {"runtime-cron-scan", "runtime-cron-fix", "runtime-cron-verify"}
DOCTOR_MODE = "doctor"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=["scan", "apply", "verify", "all", DOCTOR_MODE, *sorted(RUNTIME_CRON_MODES)],
        default="all",
        help=(
            "scan/apply/verify/all: static 10-file sync; doctor: one-shot static+cron+session+canary self-check; "
            "runtime-cron-scan/fix/verify: inspect or repair cron payload.model and cron sessions"
        ),
    )
    parser.add_argument("--home", default=str(Path.home()), help="User home path.")
    parser.add_argument("--provider", default="qmcode", help="Provider slug, default: qmcode.")
    parser.add_argument("--openclaw-home", help="Override OpenClaw home (default: <home>/.openclaw).")
    parser.add_argument("--claude-settings", help="Override Claude settings path.")
    parser.add_argument("--primary-model", required=True, help="Primary model id, e.g. gpt-5.4.")
    parser.add_argument(
        "--fallback-model",
        default="",
        help="Optional fallback model id, e.g. gpt-5.3-codex. Leave empty for no fallback chain.",
    )
    parser.add_argument(
        "--claude-model",
        help="Claude profile model id used in gpt-*. If omitted, uses --primary-model.",
    )
    parser.add_argument("--run-tests", action="store_true", help="Run OpenClaw regression tests in verify mode.")
    parser.add_argument(
        "--openclaw-bin",
        default="/opt/homebrew/bin/openclaw",
        help="OpenClaw CLI path used by runtime cron modes.",
    )
    parser.add_argument(
        "--sessions-store",
        help="Override sessions store path (default: <openclaw-home>/agents/main/sessions/sessions.json).",
    )
    parser.add_argument(
        "--cron-session-prefix",
        default="agent:main:cron:",
        help="Session key prefix for cron runs in sessions.json.",
    )
    parser.add_argument(
        "--clear-cron-sessions",
        action="store_true",
        help="With runtime-cron-fix, clear session keys using --cron-session-prefix after cron model edits.",
    )
    parser.add_argument(
        "--doctor-session-key",
        default="agent:main:main",
        help="Primary session key expected to use the target model during doctor mode.",
    )
    parser.add_argument(
        "--doctor-log-limit",
        type=int,
        default=200,
        help="Recent gateway log lines scanned in doctor mode.",
    )
    parser.add_argument(
        "--doctor-probe-timeout-ms",
        type=int,
        default=12000,
        help="Probe timeout in ms used by doctor mode.",
    )
    parser.add_argument(
        "--doctor-probe-concurrency",
        type=int,
        default=1,
        help="Probe concurrency used by doctor mode.",
    )
    parser.add_argument(
        "--doctor-old-model",
        help="Optional old model string scanned in recent logs by doctor mode. Defaults to --fallback-model.",
    )
    return parser.parse_args()


def model_alias(model_id: str) -> str:
    if re.fullmatch(r"gpt-\d+(?:\.\d+)?", model_id):
        return "GPT-" + model_id.split("-", 1)[1]
    m_codex = re.fullmatch(r"gpt-(\d+(?:\.\d+)?)-codex", model_id)
    if m_codex:
        return f"GPT-{m_codex.group(1)} Codex"
    m_codex_mini = re.fullmatch(r"gpt-(\d+(?:\.\d+)?)-codex-mini", model_id)
    if m_codex_mini:
        return f"GPT-{m_codex_mini.group(1)} Codex Mini"
    return model_id


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_command(cmd: List[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def parse_json_object_from_text(text: str) -> Any:
    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char not in "[{":
            continue
        try:
            obj, _ = decoder.raw_decode(text[index:])
            return obj
        except json.JSONDecodeError:
            continue
    raise ValueError("no JSON object found in command output")


def fallback_ids(fallback_id: str) -> List[str]:
    return [fallback_id] if fallback_id else []


def fallback_slugs(provider: str, fallback_id: str) -> List[str]:
    return [f"{provider}/{fallback_id}"] if fallback_id else []


def shell_array(values: List[str]) -> str:
    if not values:
        return "()"
    return "(" + " ".join(f'"{value}"' for value in values) + ")"


def escaped_json_string(values: List[str]) -> str:
    return json.dumps(values, ensure_ascii=False).replace('"', '\\"')


def provider_models(doc: dict, provider: str) -> List[dict]:
    if isinstance(doc.get("models"), dict) and isinstance(doc["models"].get("providers"), dict):
        providers = doc["models"]["providers"]
    elif isinstance(doc.get("providers"), dict):
        providers = doc["providers"]
    else:
        raise ValueError("Missing providers tree.")
    if provider not in providers:
        raise ValueError(f"Provider '{provider}' not found.")
    models = providers[provider].get("models")
    if not isinstance(models, list):
        raise ValueError(f"Provider '{provider}' models is not a list.")
    return models


def build_catalog(docs: List[dict], provider: str) -> Dict[str, dict]:
    catalog: Dict[str, dict] = {}
    for doc in docs:
        try:
            models = provider_models(doc, provider)
        except ValueError:
            continue
        for item in models:
            if not isinstance(item, dict):
                continue
            model_id = item.get("id")
            if isinstance(model_id, str) and model_id not in catalog:
                catalog[model_id] = copy.deepcopy(item)
    return catalog


def ensure_model_definitions(
    models: List[dict], required_ids: List[str], catalog: Dict[str, dict], doc_name: str
) -> Tuple[bool, List[str]]:
    changed = False
    notes: List[str] = []
    existing = {item.get("id") for item in models if isinstance(item, dict)}
    for model_id in required_ids:
        if model_id in existing:
            continue
        if model_id not in catalog:
            raise ValueError(
                f"{doc_name}: model id '{model_id}' missing in all catalogs; please add model metadata first."
            )
        models.append(copy.deepcopy(catalog[model_id]))
        changed = True
        notes.append(f"append model definition: {model_id}")
    return changed, notes


def ensure_defaults_model_chain(
    doc: dict,
    provider: str,
    primary_id: str,
    fallback_id: str,
) -> Tuple[bool, List[str]]:
    changed = False
    notes: List[str] = []
    defaults = doc.setdefault("agents", {}).setdefault("defaults", {})
    model_obj = defaults.setdefault("model", {})
    models_map = defaults.setdefault("models", {})

    primary_slug = f"{provider}/{primary_id}"
    expected_fallback_slugs = fallback_slugs(provider, fallback_id)

    if model_obj.get("primary") != primary_slug:
        model_obj["primary"] = primary_slug
        changed = True
        notes.append(f"set primary={primary_slug}")
    if model_obj.get("fallbacks") != expected_fallback_slugs:
        model_obj["fallbacks"] = expected_fallback_slugs
        changed = True
        notes.append(f"set fallbacks={expected_fallback_slugs}")

    if primary_slug not in models_map:
        models_map[primary_slug] = {"alias": model_alias(primary_id)}
        changed = True
        notes.append(f"add models map key: {primary_slug}")

    primary_entry = models_map.get(primary_slug)
    desired_primary_alias = model_alias(primary_id)
    if isinstance(primary_entry, dict) and primary_entry.get("alias") != desired_primary_alias:
        primary_entry["alias"] = desired_primary_alias
        changed = True
        notes.append(f"set alias for {primary_slug}: {desired_primary_alias}")

    if fallback_id:
        fallback_slug = f"{provider}/{fallback_id}"
        if fallback_slug not in models_map:
            models_map[fallback_slug] = {"alias": model_alias(fallback_id)}
            changed = True
            notes.append(f"add models map key: {fallback_slug}")
        fallback_entry = models_map.get(fallback_slug)
        desired_fallback_alias = model_alias(fallback_id)
        if isinstance(fallback_entry, dict) and fallback_entry.get("alias") != desired_fallback_alias:
            fallback_entry["alias"] = desired_fallback_alias
            changed = True
            notes.append(f"set alias for {fallback_slug}: {desired_fallback_alias}")

    return changed, notes


def replace_required_line(text: str, pattern: str, repl: str, desc: str) -> Tuple[str, str]:
    new_text, count = re.subn(pattern, repl, text, flags=re.MULTILINE)
    if count == 0:
        raise ValueError(f"Line not found for update: {desc}")
    return new_text, f"{desc} ({count} hit)"


def update_shell_constants(
    path: Path,
    primary_slug: str,
    fallback_model_slugs: List[str],
    primary_alias: str,
) -> Tuple[bool, List[str]]:
    text = path.read_text(encoding="utf-8")
    original = text
    notes: List[str] = []
    fallback_json = escaped_json_string(fallback_model_slugs)
    fallback_array = shell_array(fallback_model_slugs)

    if path.name == "daily-auto-update-local.sh":
        text, note = replace_required_line(
            text,
            r'^DEFAULT_EXPECTED_PRIMARY_MODEL=.*$',
            f'DEFAULT_EXPECTED_PRIMARY_MODEL="${{OPENCLAW_DAILY_UPDATE_EXPECTED_PRIMARY_MODEL:-{primary_slug}}}"',
            "daily: DEFAULT_EXPECTED_PRIMARY_MODEL",
        )
        notes.append(note)
        text, note = replace_required_line(
            text,
            r'^DEFAULT_EXPECTED_FALLBACKS_JSON=.*$',
            f'DEFAULT_EXPECTED_FALLBACKS_JSON="${{OPENCLAW_DAILY_UPDATE_EXPECTED_FALLBACKS_JSON:-{fallback_json}}}"',
            "daily: DEFAULT_EXPECTED_FALLBACKS_JSON",
        )
        notes.append(note)
    elif path.name == "update-openclaw-with-feishu-repatch.sh":
        text, note = replace_required_line(
            text,
            r'^DEFAULT_MODEL_GUARD_PRIMARY_MODEL=.*$',
            f'DEFAULT_MODEL_GUARD_PRIMARY_MODEL="{primary_slug}"',
            "update script: DEFAULT_MODEL_GUARD_PRIMARY_MODEL",
        )
        notes.append(note)
        text, note = replace_required_line(
            text,
            r'^DEFAULT_MODEL_GUARD_PRIMARY_ALIAS=.*$',
            f'DEFAULT_MODEL_GUARD_PRIMARY_ALIAS="{primary_alias}"',
            "update script: DEFAULT_MODEL_GUARD_PRIMARY_ALIAS",
        )
        notes.append(note)
        text, note = replace_required_line(
            text,
            r'^DEFAULT_MODEL_GUARD_FALLBACK_MODELS=.*$',
            f'DEFAULT_MODEL_GUARD_FALLBACK_MODELS={fallback_array}',
            "update script: DEFAULT_MODEL_GUARD_FALLBACK_MODELS",
        )
        notes.append(note)
    elif path.name == "enforce-openclaw-kimi-model.sh":
        text, note = replace_required_line(
            text,
            r'^DEFAULT_PRIMARY_MODEL=.*$',
            f'DEFAULT_PRIMARY_MODEL="{primary_slug}"',
            "enforce script: DEFAULT_PRIMARY_MODEL",
        )
        notes.append(note)
        text, note = replace_required_line(
            text,
            r'^DEFAULT_PRIMARY_ALIAS=.*$',
            f'DEFAULT_PRIMARY_ALIAS="{primary_alias}"',
            "enforce script: DEFAULT_PRIMARY_ALIAS",
        )
        notes.append(note)
        text, note = replace_required_line(
            text,
            r'^DEFAULT_FALLBACK_MODELS=.*$',
            f'DEFAULT_FALLBACK_MODELS={fallback_array}',
            "enforce script: DEFAULT_FALLBACK_MODELS",
        )
        notes.append(note)
    else:
        raise ValueError(f"Unsupported shell target: {path}")

    changed = text != original
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed, notes


def update_test_file(path: Path, replacements: Dict[str, str]) -> Tuple[bool, List[str]]:
    text = path.read_text(encoding="utf-8")
    original = text
    notes: List[str] = []
    for old, new in replacements.items():
        if not old or old == new:
            continue
        if old in text:
            count = text.count(old)
            text = text.replace(old, new)
            notes.append(f"replace '{old}' -> '{new}' ({count} hit)")
    changed = text != original
    if changed:
        path.write_text(text, encoding="utf-8")
    return changed, notes


def update_claude_settings(path: Path, claude_model: str) -> Tuple[bool, List[str]]:
    data = read_json(path)
    env = data.setdefault("env", {})
    target = {
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": f"{claude_model}(medium)",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": f"{claude_model}(xhigh)",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": f"{claude_model}(high)",
    }
    notes: List[str] = []
    changed = False
    for key, value in target.items():
        if env.get(key) != value:
            env[key] = value
            changed = True
            notes.append(f"set {key}={value}")
    if changed:
        write_json(path, data)
    return changed, notes


def collect_static_failures(
    openclaw_home: Path,
    claude_settings: Path,
    provider: str,
    primary_id: str,
    fallback_id: str,
    claude_model: str,
    run_tests: bool,
) -> List[str]:
    primary_slug = f"{provider}/{primary_id}"
    expected_fallback_slugs = fallback_slugs(provider, fallback_id)
    failures: List[str] = []

    oc = read_json(openclaw_home / "openclaw.json")
    occ = read_json(openclaw_home / "openclaw_codex.json")
    am = read_json(openclaw_home / "agents/main/agent/models.json")
    cs = read_json(claude_settings)

    for name, doc in [("openclaw.json", oc), ("openclaw_codex.json", occ)]:
        model_obj = doc["agents"]["defaults"]["model"]
        if model_obj.get("primary") != primary_slug:
            failures.append(f"[FAIL] {name}: primary != {primary_slug}")
        if model_obj.get("fallbacks") != expected_fallback_slugs:
            failures.append(f"[FAIL] {name}: fallbacks != {expected_fallback_slugs}")
        model_map = doc["agents"]["defaults"].get("models", {})
        if primary_slug not in model_map:
            failures.append(f"[FAIL] {name}: models map missing primary key {primary_slug}")
        for fallback_slug in expected_fallback_slugs:
            if fallback_slug not in model_map:
                failures.append(f"[FAIL] {name}: models map missing fallback key {fallback_slug}")
        qm_ids = {m.get("id") for m in provider_models(doc, provider)}
        if primary_id not in qm_ids:
            failures.append(f"[FAIL] {name}: provider model definitions missing primary id {primary_id}")
        for fallback_id_item in fallback_ids(fallback_id):
            if fallback_id_item not in qm_ids:
                failures.append(f"[FAIL] {name}: provider model definitions missing fallback id {fallback_id_item}")

    am_ids = {m.get("id") for m in provider_models(am, provider)}
    if primary_id not in am_ids:
        failures.append(f"[FAIL] agents/main/agent/models.json: provider model definitions missing primary id {primary_id}")
    for fallback_id_item in fallback_ids(fallback_id):
        if fallback_id_item not in am_ids:
            failures.append(
                f"[FAIL] agents/main/agent/models.json: provider model definitions missing fallback id {fallback_id_item}"
            )

    env = cs.get("env", {})
    expected_profiles = {
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": f"{claude_model}(medium)",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": f"{claude_model}(xhigh)",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": f"{claude_model}(high)",
    }
    for key, expected in expected_profiles.items():
        if env.get(key) != expected:
            failures.append(f"[FAIL] {claude_settings}: {key} != {expected}")

    daily_text = (openclaw_home / "scripts/daily-auto-update-local.sh").read_text(encoding="utf-8")
    update_text = (openclaw_home / "scripts/update-openclaw-with-feishu-repatch.sh").read_text(encoding="utf-8")
    enforce_text = (openclaw_home / "scripts/enforce-openclaw-kimi-model.sh").read_text(encoding="utf-8")
    primary_alias = model_alias(primary_id)
    fallback_json = escaped_json_string(expected_fallback_slugs)
    fallback_array = shell_array(expected_fallback_slugs)

    required_snippets = [
        (
            daily_text,
            f'DEFAULT_EXPECTED_PRIMARY_MODEL="${{OPENCLAW_DAILY_UPDATE_EXPECTED_PRIMARY_MODEL:-{primary_slug}}}"',
        ),
        (
            daily_text,
            f'DEFAULT_EXPECTED_FALLBACKS_JSON="${{OPENCLAW_DAILY_UPDATE_EXPECTED_FALLBACKS_JSON:-{fallback_json}}}"',
        ),
        (update_text, f'DEFAULT_MODEL_GUARD_PRIMARY_MODEL="{primary_slug}"'),
        (update_text, f'DEFAULT_MODEL_GUARD_PRIMARY_ALIAS="{primary_alias}"'),
        (update_text, f"DEFAULT_MODEL_GUARD_FALLBACK_MODELS={fallback_array}"),
        (enforce_text, f'DEFAULT_PRIMARY_MODEL="{primary_slug}"'),
        (enforce_text, f'DEFAULT_PRIMARY_ALIAS="{primary_alias}"'),
        (enforce_text, f"DEFAULT_FALLBACK_MODELS={fallback_array}"),
    ]
    for source_text, snippet in required_snippets:
        if snippet not in source_text:
            failures.append(f"[FAIL] script snippet missing: {snippet}")

    if run_tests:
        test_cmds = [
            str(openclaw_home / "scripts/tests/enforce-openclaw-kimi-model.test.sh"),
            str(openclaw_home / "scripts/tests/update-openclaw-with-feishu-repatch.test.sh"),
            str(openclaw_home / "scripts/tests/daily-auto-update-local.test.sh"),
        ]
        for cmd in test_cmds:
            print(f"[RUN] bash {cmd}")
            rc = subprocess.call(["bash", cmd])
            if rc != 0:
                failures.append(f"[FAIL] test failed (rc={rc}): {cmd}")
    return failures


def verify_state(
    openclaw_home: Path,
    claude_settings: Path,
    provider: str,
    primary_id: str,
    fallback_id: str,
    claude_model: str,
    run_tests: bool,
) -> bool:
    failures = collect_static_failures(
        openclaw_home=openclaw_home,
        claude_settings=claude_settings,
        provider=provider,
        primary_id=primary_id,
        fallback_id=fallback_id,
        claude_model=claude_model,
        run_tests=run_tests,
    )
    for failure in failures:
        print(failure)
    return not failures


def load_cron_jobs(openclaw_bin: str) -> List[dict]:
    proc = run_command([openclaw_bin, "cron", "list", "--json"])
    if proc.returncode != 0:
        raise RuntimeError(f"openclaw cron list failed (rc={proc.returncode}): {(proc.stderr or proc.stdout).strip()}")
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"failed to parse openclaw cron list JSON: {exc}") from exc
    jobs = payload.get("jobs")
    if not isinstance(jobs, list):
        raise RuntimeError("openclaw cron list JSON missing jobs[]")
    return jobs


def cron_job_payload_model(job: dict) -> str | None:
    payload = job.get("payload") if isinstance(job, dict) else None
    if isinstance(payload, dict) and isinstance(payload.get("model"), str):
        return payload.get("model")
    return None


def cron_job_summary(job: dict) -> dict:
    return {
        "id": job.get("id"),
        "name": job.get("name"),
        "enabled": job.get("enabled"),
        "payload_model": cron_job_payload_model(job),
        "updatedAtMs": job.get("updatedAtMs"),
    }


def collect_cron_model_mismatches(jobs: List[dict], target_slug: str) -> List[dict]:
    mismatches: List[dict] = []
    for job in jobs:
        payload_model = cron_job_payload_model(job)
        if payload_model != target_slug:
            mismatches.append(cron_job_summary(job))
    return mismatches


def load_sessions_store(path: Path) -> dict:
    if not path.exists():
        return {}
    return read_json(path)


def collect_cron_session_mismatches(
    sessions_doc: dict,
    prefix: str,
    provider: str,
    primary_id: str,
) -> List[dict]:
    mismatches: List[dict] = []
    for key, value in sessions_doc.items():
        if not str(key).startswith(prefix):
            continue
        entry = value if isinstance(value, dict) else {}
        model = entry.get("model")
        model_provider = entry.get("modelProvider")
        if model != primary_id or (model_provider not in (None, provider)):
            mismatches.append(
                {
                    "key": key,
                    "model": model,
                    "modelProvider": model_provider,
                    "sessionId": entry.get("sessionId"),
                    "updatedAt": entry.get("updatedAt"),
                }
            )
    return mismatches


def clear_cron_sessions(path: Path, prefix: str) -> dict:
    if not path.exists():
        return {"path": str(path), "exists": False, "removed_count": 0, "removed_keys": []}
    doc = read_json(path)
    if not isinstance(doc, dict):
        raise ValueError(f"sessions store is not an object: {path}")
    removed_keys = [key for key in doc if str(key).startswith(prefix)]
    if removed_keys:
        new_doc = {key: value for key, value in doc.items() if not str(key).startswith(prefix)}
        write_json(path, new_doc)
    return {"path": str(path), "exists": True, "removed_count": len(removed_keys), "removed_keys": removed_keys}


def runtime_cron_scan(args: argparse.Namespace, sessions_store: Path) -> int:
    target_slug = f"{args.provider}/{args.primary_model}"
    jobs = load_cron_jobs(args.openclaw_bin)
    mismatches = collect_cron_model_mismatches(jobs, target_slug)
    report = {
        "target_model": target_slug,
        "job_count": len(jobs),
        "mismatch_count": len(mismatches),
        "mismatches": mismatches,
        "sessions_store": str(sessions_store),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


def runtime_cron_fix(args: argparse.Namespace, sessions_store: Path) -> int:
    target_slug = f"{args.provider}/{args.primary_model}"
    jobs = load_cron_jobs(args.openclaw_bin)
    mismatches = collect_cron_model_mismatches(jobs, target_slug)
    edited: List[dict] = []
    failed: List[dict] = []

    for job in mismatches:
        job_id = str(job["id"])
        proc = run_command([args.openclaw_bin, "cron", "edit", job_id, "--model", target_slug])
        item = {
            "id": job_id,
            "name": job.get("name"),
            "from_model": job.get("payload_model"),
            "to_model": target_slug,
            "returncode": proc.returncode,
            "output": (proc.stdout or proc.stderr).strip(),
        }
        if proc.returncode == 0:
            edited.append(item)
        else:
            failed.append(item)

    cleared_sessions = None
    if args.clear_cron_sessions:
        cleared_sessions = clear_cron_sessions(sessions_store, args.cron_session_prefix)

    remaining_jobs = load_cron_jobs(args.openclaw_bin)
    remaining_mismatches = collect_cron_model_mismatches(remaining_jobs, target_slug)
    report = {
        "target_model": target_slug,
        "edited_count": len(edited),
        "failed_count": len(failed),
        "edited": edited,
        "failed": failed,
        "remaining_mismatch_count": len(remaining_mismatches),
        "remaining_mismatches": remaining_mismatches,
        "cleared_sessions": cleared_sessions,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if failed or remaining_mismatches else 0


def runtime_cron_verify(args: argparse.Namespace, sessions_store: Path) -> int:
    target_slug = f"{args.provider}/{args.primary_model}"
    jobs = load_cron_jobs(args.openclaw_bin)
    job_mismatches = collect_cron_model_mismatches(jobs, target_slug)
    sessions_doc = load_sessions_store(sessions_store)
    session_mismatches = collect_cron_session_mismatches(
        sessions_doc,
        args.cron_session_prefix,
        args.provider,
        args.primary_model,
    )

    if job_mismatches:
        print(f"[FAIL] cron payload.model mismatch count={len(job_mismatches)}")
    if session_mismatches:
        print(f"[FAIL] cron session model mismatch count={len(session_mismatches)}")

    report = {
        "target_model": target_slug,
        "job_count": len(jobs),
        "job_mismatch_count": len(job_mismatches),
        "job_mismatches": job_mismatches,
        "sessions_store": str(sessions_store),
        "sessions_store_exists": sessions_store.exists(),
        "session_mismatch_count": len(session_mismatches),
        "session_mismatches": session_mismatches,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if job_mismatches or session_mismatches else 0


def load_probe_payload(openclaw_bin: str, provider: str, timeout_ms: int, concurrency: int) -> dict:
    proc = run_command(
        [
            openclaw_bin,
            "models",
            "status",
            "--probe",
            "--json",
            "--probe-provider",
            provider,
            "--probe-timeout",
            str(timeout_ms),
            "--probe-concurrency",
            str(concurrency),
        ]
    )
    if proc.returncode != 0:
        combined = (proc.stdout or "") + (proc.stderr or "")
        raise RuntimeError(f"openclaw models status --probe failed (rc={proc.returncode}): {combined.strip()}")
    payload = parse_json_object_from_text((proc.stdout or "") + "\n" + (proc.stderr or ""))
    if not isinstance(payload, dict):
        raise RuntimeError("openclaw models status --probe did not return a JSON object")
    return payload


def collect_probe_status(payload: dict, provider: str, target_slug: str, expected_fallbacks: List[str]) -> dict:
    auth = payload.get("auth") if isinstance(payload.get("auth"), dict) else {}
    probes = auth.get("probes") if isinstance(auth.get("probes"), dict) else {}
    results = probes.get("results") if isinstance(probes.get("results"), list) else []
    target_results = [
        item
        for item in results
        if isinstance(item, dict)
        and item.get("provider") == provider
        and item.get("model") == target_slug
    ]
    resolved_default = payload.get("resolvedDefault")
    actual_fallbacks = payload.get("fallbacks") if isinstance(payload.get("fallbacks"), list) else []
    ok = (
        resolved_default == target_slug
        and actual_fallbacks == expected_fallbacks
        and any(item.get("status") == "ok" for item in target_results)
    )
    return {
        "ok": ok,
        "resolved_default": resolved_default,
        "resolved_default_ok": resolved_default == target_slug,
        "fallbacks": actual_fallbacks,
        "fallbacks_ok": actual_fallbacks == expected_fallbacks,
        "probe_results": target_results,
        "probe_options": probes.get("options"),
        "probe_duration_ms": probes.get("durationMs"),
    }


def load_log_rows(openclaw_bin: str, limit: int) -> List[dict]:
    proc = run_command([openclaw_bin, "logs", "--json", "--limit", str(limit)])
    if proc.returncode != 0:
        combined = (proc.stdout or "") + (proc.stderr or "")
        raise RuntimeError(f"openclaw logs failed (rc={proc.returncode}): {combined.strip()}")
    rows: List[dict] = []
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def trim_events(events: List[dict], limit: int = 20) -> List[dict]:
    return events[:limit]


def collect_log_alerts(log_rows: List[dict], old_model: str) -> dict:
    membership_or_401: List[dict] = []
    old_model_hits: List[dict] = []
    model_snapshot_hits: List[dict] = []

    for row in log_rows:
        if row.get("type") != "log":
            continue
        message = str(row.get("message") or "")
        lower_message = message.lower()
        event = {
            "time": row.get("time"),
            "level": row.get("level"),
            "subsystem": row.get("subsystem"),
            "message": message[:500],
        }
        if (
            re.search(r"\bmembership\b", lower_message)
            or re.search(r"\b401\b", message)
            or "http 401" in lower_message
            or "user not found" in lower_message
        ):
            membership_or_401.append(event)
        if old_model and old_model in message:
            old_model_hits.append(event)
        if old_model and f"model-snapshot -> {old_model}" in message:
            model_snapshot_hits.append(event)

    return {
        "ok": not membership_or_401 and not model_snapshot_hits and (not old_model or not old_model_hits),
        "old_model": old_model,
        "membership_or_401": trim_events(membership_or_401),
        "old_model_hits": trim_events(old_model_hits),
        "model_snapshot_hits": trim_events(model_snapshot_hits),
    }


def collect_main_session_status(sessions_doc: dict, session_key: str, provider: str, primary_id: str) -> dict:
    entry = sessions_doc.get(session_key) if isinstance(sessions_doc, dict) else None
    if not isinstance(entry, dict):
        return {
            "session_key": session_key,
            "exists": False,
            "ok": False,
            "reason": "missing",
        }
    model = entry.get("model")
    model_provider = entry.get("modelProvider")
    ok = model == primary_id and model_provider in (None, provider)
    return {
        "session_key": session_key,
        "exists": True,
        "ok": ok,
        "reason": None if ok else "model mismatch",
        "model": model,
        "modelProvider": model_provider,
        "sessionId": entry.get("sessionId"),
        "updatedAt": entry.get("updatedAt"),
    }


def doctor(
    args: argparse.Namespace,
    openclaw_home: Path,
    claude_settings: Path,
    sessions_store: Path,
) -> int:
    target_slug = f"{args.provider}/{args.primary_model}"
    expected_fallbacks = fallback_slugs(args.provider, args.fallback_model)
    static_failures = collect_static_failures(
        openclaw_home=openclaw_home,
        claude_settings=claude_settings,
        provider=args.provider,
        primary_id=args.primary_model,
        fallback_id=args.fallback_model,
        claude_model=args.claude_model or args.primary_model,
        run_tests=args.run_tests,
    )

    jobs = load_cron_jobs(args.openclaw_bin)
    job_mismatches = collect_cron_model_mismatches(jobs, target_slug)

    sessions_doc = load_sessions_store(sessions_store)
    cron_session_mismatches = collect_cron_session_mismatches(
        sessions_doc,
        args.cron_session_prefix,
        args.provider,
        args.primary_model,
    )
    main_session = collect_main_session_status(
        sessions_doc=sessions_doc,
        session_key=args.doctor_session_key,
        provider=args.provider,
        primary_id=args.primary_model,
    )

    probe_error = None
    try:
        probe_payload = load_probe_payload(
            openclaw_bin=args.openclaw_bin,
            provider=args.provider,
            timeout_ms=args.doctor_probe_timeout_ms,
            concurrency=args.doctor_probe_concurrency,
        )
        probe_report = collect_probe_status(probe_payload, args.provider, target_slug, expected_fallbacks)
    except (RuntimeError, ValueError) as exc:
        probe_error = str(exc)
        probe_report = {"ok": False, "error": probe_error}

    log_error = None
    old_model = args.doctor_old_model if args.doctor_old_model is not None else args.fallback_model
    try:
        log_rows = load_log_rows(args.openclaw_bin, args.doctor_log_limit)
        canary_report = collect_log_alerts(log_rows, old_model)
        canary_report["log_limit"] = args.doctor_log_limit
    except RuntimeError as exc:
        log_error = str(exc)
        canary_report = {"ok": False, "error": log_error, "old_model": old_model, "log_limit": args.doctor_log_limit}

    overall_ok = (
        not static_failures
        and not job_mismatches
        and not cron_session_mismatches
        and main_session.get("ok") is True
        and probe_report.get("ok") is True
        and canary_report.get("ok") is True
    )

    report = {
        "mode": DOCTOR_MODE,
        "target_model": target_slug,
        "expected_fallbacks": expected_fallbacks,
        "static": {
            "ok": not static_failures,
            "failure_count": len(static_failures),
            "failures": static_failures,
        },
        "cron": {
            "job_count": len(jobs),
            "job_mismatch_count": len(job_mismatches),
            "job_mismatches": job_mismatches,
            "sessions_store": str(sessions_store),
            "cron_session_mismatch_count": len(cron_session_mismatches),
            "cron_session_mismatches": cron_session_mismatches,
        },
        "sessions": {
            "main_session": main_session,
        },
        "probe": probe_report,
        "canary": canary_report,
        "summary": {
            "ok": overall_ok,
            "probe_error": probe_error,
            "log_error": log_error,
        },
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("[DOCTOR] PASS" if overall_ok else "[DOCTOR] FAIL")
    return 0 if overall_ok else 1


def main() -> int:
    args = parse_args()
    home = Path(args.home).expanduser().resolve()
    openclaw_home = Path(args.openclaw_home).expanduser().resolve() if args.openclaw_home else home / ".openclaw"
    claude_settings = (
        Path(args.claude_settings).expanduser().resolve() if args.claude_settings else home / TARGET_CLAUDE_FILE
    )
    sessions_store = (
        Path(args.sessions_store).expanduser().resolve()
        if args.sessions_store
        else openclaw_home / "agents/main/sessions/sessions.json"
    )
    claude_model = args.claude_model or args.primary_model

    primary_slug = f"{args.provider}/{args.primary_model}"
    expected_fallback_slugs = fallback_slugs(args.provider, args.fallback_model)
    print(f"[INFO] target primary={primary_slug}")
    print(f"[INFO] target fallbacks={expected_fallback_slugs}")
    print(f"[INFO] target claude model={claude_model}")

    if args.mode == DOCTOR_MODE:
        try:
            return doctor(args, openclaw_home, claude_settings, sessions_store)
        except (RuntimeError, ValueError) as exc:
            print(f"[ERROR] {exc}")
            return 2

    if args.mode in RUNTIME_CRON_MODES:
        try:
            if args.mode == "runtime-cron-scan":
                return runtime_cron_scan(args, sessions_store)
            if args.mode == "runtime-cron-fix":
                return runtime_cron_fix(args, sessions_store)
            return runtime_cron_verify(args, sessions_store)
        except (RuntimeError, ValueError) as exc:
            print(f"[ERROR] {exc}")
            return 2

    oc_path = openclaw_home / "openclaw.json"
    occ_path = openclaw_home / "openclaw_codex.json"
    am_path = openclaw_home / "agents/main/agent/models.json"

    for required in [oc_path, occ_path, am_path, claude_settings]:
        if not required.exists():
            print(f"[ERROR] required file missing: {required}")
            return 2

    oc = read_json(oc_path)
    occ = read_json(occ_path)
    am = read_json(am_path)

    current_primary_slug = oc["agents"]["defaults"]["model"].get("primary", primary_slug)
    current_fallbacks = oc["agents"]["defaults"]["model"].get("fallbacks", [])
    current_fallback_slug = current_fallbacks[0] if current_fallbacks else ""
    current_primary_alias = (
        oc["agents"]["defaults"].get("models", {}).get(current_primary_slug, {}).get("alias")
        if isinstance(oc["agents"]["defaults"].get("models", {}).get(current_primary_slug), dict)
        else model_alias(args.primary_model)
    )
    if not current_primary_alias:
        current_primary_alias = model_alias(args.primary_model)

    print(f"[INFO] current primary={current_primary_slug}")
    print(f"[INFO] current fallbacks={current_fallbacks}")

    if args.mode in {"scan", "all"}:
        for rel in TARGET_OPENCLAW_FILES:
            p = openclaw_home / rel
            print(f"[SCAN] {p} exists={p.exists()}")
        print(f"[SCAN] {claude_settings} exists={claude_settings.exists()}")

    if args.mode in {"apply", "all"}:
        catalog = build_catalog([oc, occ, am], args.provider)
        required_ids = [args.primary_model, *fallback_ids(args.fallback_model)]
        changed_files: Dict[str, List[str]] = {}

        for name, doc, path in [("openclaw.json", oc, oc_path), ("openclaw_codex.json", occ, occ_path)]:
            changed = False
            notes: List[str] = []
            c1, n1 = ensure_model_definitions(provider_models(doc, args.provider), required_ids, catalog, name)
            changed |= c1
            notes.extend(n1)
            c2, n2 = ensure_defaults_model_chain(doc, args.provider, args.primary_model, args.fallback_model)
            changed |= c2
            notes.extend(n2)
            if changed:
                write_json(path, doc)
                changed_files[str(path)] = notes

        am_changed, am_notes = ensure_model_definitions(
            provider_models(am, args.provider), required_ids, catalog, "agents/main/agent/models.json"
        )
        if am_changed:
            write_json(am_path, am)
            changed_files[str(am_path)] = am_notes

        for rel in [
            "scripts/daily-auto-update-local.sh",
            "scripts/update-openclaw-with-feishu-repatch.sh",
            "scripts/enforce-openclaw-kimi-model.sh",
        ]:
            path = openclaw_home / rel
            changed, notes = update_shell_constants(path, primary_slug, expected_fallback_slugs, model_alias(args.primary_model))
            if changed:
                changed_files[str(path)] = notes

        replacements = {
            current_primary_slug: primary_slug,
            current_primary_alias: model_alias(args.primary_model),
        }
        if args.fallback_model and current_fallback_slug:
            replacements[current_fallback_slug] = expected_fallback_slugs[0]
        for rel in [
            "scripts/tests/daily-auto-update-local.test.sh",
            "scripts/tests/enforce-openclaw-kimi-model.test.sh",
            "scripts/tests/update-openclaw-with-feishu-repatch.test.sh",
        ]:
            path = openclaw_home / rel
            changed, notes = update_test_file(path, replacements)
            if changed:
                changed_files[str(path)] = notes

        c_changed, c_notes = update_claude_settings(claude_settings, claude_model)
        if c_changed:
            changed_files[str(claude_settings)] = c_notes

        if changed_files:
            print("[APPLY] updated files:")
            for file_path, notes in changed_files.items():
                print(f"  - {file_path}")
                for note in notes:
                    print(f"    * {note}")
        else:
            print("[APPLY] no file changes required.")

    if args.mode in {"verify", "all"}:
        ok = verify_state(
            openclaw_home=openclaw_home,
            claude_settings=claude_settings,
            provider=args.provider,
            primary_id=args.primary_model,
            fallback_id=args.fallback_model,
            claude_model=claude_model,
            run_tests=args.run_tests,
        )
        if not ok:
            print("[VERIFY] FAIL")
            return 1
        print("[VERIFY] PASS")

    return 0


if __name__ == "__main__":
    sys.exit(main())
