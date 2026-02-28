#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="ai.openclaw.daily-auto-update.local"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT_PATH="${SCRIPT_DIR}/daily-auto-update-local.sh"
LOG_DIR="/Users/crane/.openclaw/logs"
RUN_MODE="${OPENCLAW_DAILY_UPDATE_RUN_MODE:---with-update}"
TARGET="${OPENCLAW_DAILY_UPDATE_FEISHU_TARGET:-oc_4f9389b28a8b716d80b16ad3de07be3d}"

if [[ ! -x "$SCRIPT_PATH" ]]; then
  echo "daily script not executable: $SCRIPT_PATH" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_PATH}</string>
    <string>${RUN_MODE}</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>4</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>OPENCLAW_DAILY_UPDATE_FEISHU_TARGET</key>
    <string>${TARGET}</string>
    <key>OPENCLAW_NPM_REGISTRY_CANDIDATES</key>
    <string>https://registry.npmjs.org,https://registry.npmmirror.com</string>
    <key>OPENCLAW_DAILY_UPDATE_SKILLS_SYNC</key>
    <string>1</string>
    <key>OPENCLAW_DAILY_UPDATE_LOCAL_GITHUB_OWNERS</key>
    <string>CraneHuang6</string>
  </dict>

  <key>StandardOutPath</key>
  <string>/Users/crane/.openclaw/logs/daily-auto-update.local.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/crane/.openclaw/logs/daily-auto-update.local.stderr.log</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST_PATH"

uid="$(id -u)"
launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$PLIST_PATH"
launchctl enable "gui/$uid/$LABEL"

echo "installed launchd job: $LABEL"
echo "plist: $PLIST_PATH"
echo "run mode: $RUN_MODE"
launchctl print "gui/$uid/$LABEL" | awk '/state =|last exit code =|path =/ {print}'
