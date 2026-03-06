#!/usr/bin/env python3
"""
Synchronize OpenClaw/Claude model selection files after a model upgrade.

This script only touches a fixed allowlist of 10 files.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Tuple


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=["scan", "apply", "verify", "all"],
        default="all",
        help="scan: inspect only; apply: mutate files; verify: validate state; all: scan+apply+verify",
    )
    parser.add_argument("--home", default=str(Path.home()), help="User home path.")
    parser.add_argument("--provider", default="qmcode", help="Provider slug, default: qmcode.")
    parser.add_argument("--openclaw-home", help="Override OpenClaw home (default: <home>/.openclaw).")
    parser.add_argument("--claude-settings", help="Override Claude settings path.")
    parser.add_argument("--primary-model", required=True, help="Primary model id, e.g. gpt-5.4.")
    parser.add_argument("--fallback-model", required=True, help="Fallback model id, e.g. gpt-5.3-codex.")
    parser.add_argument(
        "--claude-model",
        help="Claude profile model id used in gpt-*. If omitted, uses --primary-model.",
    )
    parser.add_argument("--run-tests", action="store_true", help="Run OpenClaw regression tests in verify mode.")
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
    fallback_slug = f"{provider}/{fallback_id}"

    if model_obj.get("primary") != primary_slug:
        model_obj["primary"] = primary_slug
        changed = True
        notes.append(f"set primary={primary_slug}")
    if model_obj.get("fallbacks") != [fallback_slug]:
        model_obj["fallbacks"] = [fallback_slug]
        changed = True
        notes.append(f"set fallbacks=[{fallback_slug}]")

    if primary_slug not in models_map:
        models_map[primary_slug] = {"alias": model_alias(primary_id)}
        changed = True
        notes.append(f"add models map key: {primary_slug}")
    if fallback_slug not in models_map:
        models_map[fallback_slug] = {"alias": model_alias(fallback_id)}
        changed = True
        notes.append(f"add models map key: {fallback_slug}")

    primary_entry = models_map.get(primary_slug)
    if isinstance(primary_entry, dict):
        desired_alias = model_alias(primary_id)
        if primary_entry.get("alias") != desired_alias:
            primary_entry["alias"] = desired_alias
            changed = True
            notes.append(f"set alias for {primary_slug}: {desired_alias}")

    fallback_entry = models_map.get(fallback_slug)
    if isinstance(fallback_entry, dict) and "alias" not in fallback_entry:
        fallback_entry["alias"] = model_alias(fallback_id)
        changed = True
        notes.append(f"set alias for {fallback_slug}: {model_alias(fallback_id)}")

    return changed, notes


def replace_required_line(text: str, pattern: str, repl: str, desc: str) -> Tuple[str, str]:
    new_text, count = re.subn(pattern, repl, text, flags=re.MULTILINE)
    if count == 0:
        raise ValueError(f"Line not found for update: {desc}")
    return new_text, f"{desc} ({count} hit)"


def update_shell_constants(
    path: Path,
    primary_slug: str,
    fallback_slug: str,
    primary_alias: str,
) -> Tuple[bool, List[str]]:
    text = path.read_text(encoding="utf-8")
    original = text
    notes: List[str] = []

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
            f'DEFAULT_EXPECTED_FALLBACKS_JSON="${{OPENCLAW_DAILY_UPDATE_EXPECTED_FALLBACKS_JSON:-[\\\"{fallback_slug}\\\"]}}"',
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
            f'DEFAULT_MODEL_GUARD_FALLBACK_MODELS=("{fallback_slug}")',
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
            f'DEFAULT_FALLBACK_MODELS=("{fallback_slug}")',
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
        if old == new:
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


def verify_state(
    home: Path,
    openclaw_home: Path,
    provider: str,
    primary_id: str,
    fallback_id: str,
    claude_model: str,
    run_tests: bool,
) -> bool:
    primary_slug = f"{provider}/{primary_id}"
    fallback_slug = f"{provider}/{fallback_id}"
    ok = True

    oc = read_json(openclaw_home / "openclaw.json")
    occ = read_json(openclaw_home / "openclaw_codex.json")
    am = read_json(openclaw_home / "agents/main/agent/models.json")
    cs = read_json(home / ".claude/settings.json")

    for name, doc in [("openclaw.json", oc), ("openclaw_codex.json", occ)]:
        model_obj = doc["agents"]["defaults"]["model"]
        if model_obj.get("primary") != primary_slug:
            print(f"[FAIL] {name}: primary != {primary_slug}")
            ok = False
        if model_obj.get("fallbacks") != [fallback_slug]:
            print(f"[FAIL] {name}: fallbacks != [{fallback_slug}]")
            ok = False
        model_map = doc["agents"]["defaults"].get("models", {})
        if primary_slug not in model_map or fallback_slug not in model_map:
            print(f"[FAIL] {name}: models map missing primary/fallback key")
            ok = False
        qm_ids = {m.get("id") for m in provider_models(doc, provider)}
        if primary_id not in qm_ids or fallback_id not in qm_ids:
            print(f"[FAIL] {name}: provider model definitions missing primary/fallback id")
            ok = False

    am_ids = {m.get("id") for m in provider_models(am, provider)}
    if primary_id not in am_ids or fallback_id not in am_ids:
        print("[FAIL] agents/main/agent/models.json: provider model definitions missing primary/fallback id")
        ok = False

    env = cs.get("env", {})
    expected_profiles = {
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": f"{claude_model}(medium)",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": f"{claude_model}(xhigh)",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": f"{claude_model}(high)",
    }
    for key, expected in expected_profiles.items():
        if env.get(key) != expected:
            print(f"[FAIL] .claude/settings.json: {key} != {expected}")
            ok = False

    daily_text = (openclaw_home / "scripts/daily-auto-update-local.sh").read_text(encoding="utf-8")
    update_text = (openclaw_home / "scripts/update-openclaw-with-feishu-repatch.sh").read_text(encoding="utf-8")
    enforce_text = (openclaw_home / "scripts/enforce-openclaw-kimi-model.sh").read_text(encoding="utf-8")
    primary_alias = model_alias(primary_id)

    required_snippets = [
        (daily_text, f"DEFAULT_EXPECTED_PRIMARY_MODEL=\"${{OPENCLAW_DAILY_UPDATE_EXPECTED_PRIMARY_MODEL:-{primary_slug}}}\""),
        (daily_text, f"DEFAULT_EXPECTED_FALLBACKS_JSON=\"${{OPENCLAW_DAILY_UPDATE_EXPECTED_FALLBACKS_JSON:-[\\\"{fallback_slug}\\\"]}}\""),
        (update_text, f"DEFAULT_MODEL_GUARD_PRIMARY_MODEL=\"{primary_slug}\""),
        (update_text, f"DEFAULT_MODEL_GUARD_PRIMARY_ALIAS=\"{primary_alias}\""),
        (update_text, f"DEFAULT_MODEL_GUARD_FALLBACK_MODELS=(\"{fallback_slug}\")"),
        (enforce_text, f"DEFAULT_PRIMARY_MODEL=\"{primary_slug}\""),
        (enforce_text, f"DEFAULT_PRIMARY_ALIAS=\"{primary_alias}\""),
        (enforce_text, f"DEFAULT_FALLBACK_MODELS=(\"{fallback_slug}\")"),
    ]
    for text, snippet in required_snippets:
        if snippet not in text:
            print(f"[FAIL] script snippet missing: {snippet}")
            ok = False

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
                print(f"[FAIL] test failed (rc={rc}): {cmd}")
                ok = False
    return ok


def main() -> int:
    args = parse_args()
    home = Path(args.home).expanduser().resolve()
    openclaw_home = Path(args.openclaw_home).expanduser().resolve() if args.openclaw_home else home / ".openclaw"
    claude_settings = (
        Path(args.claude_settings).expanduser().resolve() if args.claude_settings else home / TARGET_CLAUDE_FILE
    )
    claude_model = args.claude_model or args.primary_model

    primary_slug = f"{args.provider}/{args.primary_model}"
    fallback_slug = f"{args.provider}/{args.fallback_model}"
    print(f"[INFO] target primary={primary_slug}")
    print(f"[INFO] target fallback={fallback_slug}")
    print(f"[INFO] target claude model={claude_model}")

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
    current_fallback_slug = current_fallbacks[0] if current_fallbacks else fallback_slug
    current_primary_alias = (
        oc["agents"]["defaults"].get("models", {}).get(current_primary_slug, {}).get("alias")
        if isinstance(oc["agents"]["defaults"].get("models", {}).get(current_primary_slug), dict)
        else model_alias(args.primary_model)
    )
    if not current_primary_alias:
        current_primary_alias = model_alias(args.primary_model)

    print(f"[INFO] current primary={current_primary_slug}")
    print(f"[INFO] current fallback={current_fallback_slug}")

    if args.mode in {"scan", "all"}:
        for rel in TARGET_OPENCLAW_FILES:
            p = openclaw_home / rel
            print(f"[SCAN] {p} exists={p.exists()}")
        print(f"[SCAN] {claude_settings} exists={claude_settings.exists()}")

    if args.mode in {"apply", "all"}:
        catalog = build_catalog([oc, occ, am], args.provider)
        required_ids = [args.primary_model, args.fallback_model]
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
            changed, notes = update_shell_constants(path, primary_slug, fallback_slug, model_alias(args.primary_model))
            if changed:
                changed_files[str(path)] = notes

        replacements = {
            current_primary_slug: primary_slug,
            current_fallback_slug: fallback_slug,
            current_primary_alias: model_alias(args.primary_model),
        }
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
            home=home,
            openclaw_home=openclaw_home,
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
