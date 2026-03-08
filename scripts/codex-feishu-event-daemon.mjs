#!/usr/bin/env node
import path from "node:path";

const home = process.env.HOME || "";
process.env.CODEX_NOTIFY_CHANNEL ||= "discord";
process.env.CODEX_NOTIFY_TARGET ||= "1480021215044440145";
process.env.CODEX_NOTIFY_LOG_FILE ||= path.join(home, ".codex", "log", "codex-notify.log");
process.env.CODEX_NOTIFY_STATE_FILE ||= path.join(home, ".codex", "tmp", "codex-notify-state.json");
process.env.CODEX_NOTIFY_SEND_SCRIPT ||= path.join(home, ".codex", "scripts", "codex-notify-send.sh");

await import("./codex-notify-event-daemon.mjs");
