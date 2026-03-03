#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OPENCLAW_BIN="/opt/homebrew/bin/openclaw"
DEFAULT_NODE_BIN="node"
SELF_SCRIPT_DIR="${OPENCLAW_UPDATE_SKILL_SCRIPTS_DIR:-$SCRIPT_DIR}"
DEFAULT_ACCOUNT_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-openclaw-feishu-account-id-import.sh"
DEFAULT_VIDEO_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-openclaw-feishu-video-media.sh"
DEFAULT_DEDUP_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-openclaw-feishu-dedup-hardening.sh"
DEFAULT_REPLY_MEDIA_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-openclaw-feishu-reply-media.sh"
DEFAULT_REPLY_VOICE_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-openclaw-feishu-reply-voice.sh"
DEFAULT_MEDIA_PATH_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-openclaw-feishu-media-path.sh"
DEFAULT_NANO_BANANA_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-openclaw-nano-banana-model.sh"
DEFAULT_RUNTIME_PATCH_SCRIPT="${SELF_SCRIPT_DIR}/patch-openclaw-runtime-hardening.mjs"
DEFAULT_MODEL_GUARD_SCRIPT="${SELF_SCRIPT_DIR}/enforce-openclaw-kimi-model.sh"
DEFAULT_MODEL_GUARD_PRIMARY_MODEL="qmcode/gpt-5.3-codex"
DEFAULT_MODEL_GUARD_PRIMARY_ALIAS="GPT-5.3 Codex"
DEFAULT_MODEL_GUARD_FALLBACK_MODELS=("qmcode/gpt-5.2" "openrouter/arcee-ai/trinity-large-preview:free")
DEFAULT_MEDIA_TRANSCRIBE_GUARD_SCRIPT="${SELF_SCRIPT_DIR}/enforce-openclaw-media-transcribe-bins.sh"
DEFAULT_PLUGIN_SKILL_GUARD_SCRIPT="${SELF_SCRIPT_DIR}/enforce-openclaw-plugin-skill-deps.sh"
DEFAULT_AUTH_PROFILES_GUARD_SCRIPT="${SELF_SCRIPT_DIR}/ensure-openclaw-auth-profiles.sh"
DEFAULT_DIDAAPI_SUBTASKS_REPATCH_SCRIPT="${SELF_SCRIPT_DIR}/repatch-didaapi-subtasks.sh"
DEFAULT_DMG_INSTALL_SCRIPT="${SELF_SCRIPT_DIR}/install-openclaw-latest-dmg.sh"
DEFAULT_NANO_BANANA_TARGET="/opt/homebrew/lib/node_modules/openclaw/skills/nano-banana-pro/scripts/generate_image.py"
DEFAULT_OPENCLAW_ROOT="/opt/homebrew/lib/node_modules/openclaw"
DEFAULT_VIDEO_TARGET_ROOT="/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src"
DEFAULT_RUNTIME_TARGET_ROOT="/opt/homebrew/lib/node_modules/openclaw/dist"
DEFAULT_NPM_REGISTRY_CANDIDATES="https://registry.npmjs.org,https://registry.npmmirror.com"
DEFAULT_NPM_BIN="npm"
DEDUP_PERSIST_ENV_MARKER="OPENCLAW_FEISHU_DEDUP_STATE_FILE"
DEDUP_PERSIST_FILE_MARKER="feishu-dedup-message-ids.json"
DEDUP_PERSIST_EXPORT_MARKER="tryRecordMessagePersistent"
BOT_EVENT_ID_LOG_MARKER='eventId=${eventId}'
REPLY_MEDIA_DEDUP_MARKER="__openclawFeishuLastDeliveredRawTextForDedup"
REPLY_MEDIA_PREFIX_TRIM_MARKER="shouldTrimFinalPrefix"
REPLY_MEDIA_TEXT_FALLBACK_MARKER="extractMediaUrlsFromTextFallback"
REPLY_MEDIA_NO_FINAL_CANDIDATE_MARKER="__openclawFeishuNoFinalTextCandidate"
REPLY_MEDIA_OUTBOUND_DELIVERY_MARKER="__openclawFeishuHadOutboundDelivery"
REPLY_MEDIA_OUTBOUND_MEDIA_MARKER="__openclawFeishuHadMediaDelivery"
REPLY_MEDIA_DISPATCHER_MIRROR_MARKER="__openclawFeishuDispatcherStateMirror"
REPLY_MEDIA_DISPATCHER_OUTBOUND_WRITEBACK_MARKER="dispatcherState.__openclawFeishuHadOutboundDelivery = () => hadOutboundDelivery;"
REPLY_MEDIA_DISPATCHER_MIRROR_WRITEBACK_MARKER="dispatcherState.__openclawFeishuDispatcherStateMirror = true;"
REPLY_MEDIA_DISPATCHER_MIRROR_BLOCK_START_ANCHOR="finally {"
REPLY_MEDIA_DISPATCHER_MIRROR_BLOCK_END_ANCHOR="onError:"
REPLY_MEDIA_VOICE_ERROR_RE_MARKER="VOICE_ERROR_TEXT_RE"
REPLY_MEDIA_VOICE_PREFER_TEXT_MARKER="shouldPreferTextDeliveryInVoiceMode"
REPLY_MEDIA_VOICE_TTS_FAIL_LOG_MARKER="voice fallback send failed"
REPLY_VOICE_COMMAND_MARKER="resolveReplyVoiceCommand(ctx.content)"
REPLY_VOICE_FASTPATH_MARKER='reply voice synthesis failed after ${sentChunks} chunk(s):'
REPLY_VOICE_PARSE_MARKER="parseReplyTargetContentForVoice"
REPLY_VOICE_SEGMENT_MARKER="splitReplyVoiceText(replyText, 500)"
REPLY_VOICE_STATE_CACHE_MARKER='const voiceModeStateCache = new Map<string, "on" | "off">();'
REPLY_VOICE_STATE_BRIDGE_MARKER="const voiceModeStateBridge = createVoiceModeStateBridge();"
REPLY_VOICE_LOCAL_TOGGLE_MARKER="handled voice mode command locally ("
REPLY_VOICE_FORCE_TTS_MARKER="forceVoiceModeTts: voiceModeEnabled"
REPLY_VOICE_MODE_ENABLED_LOG_MARKER="voice mode enabled for session"
REPLY_VOICE_COMMAND_FILE_MARKER="splitReplyVoiceText"
REPLY_VOICE_TTS_MARKER="createReplyVoiceTtsBridge"
REPLY_VOICE_TTS_STATE_BRIDGE_MARKER="createVoiceModeStateBridge"
REPLY_VOICE_TTS_MEDIA_MARKER='startsWith("MEDIA:")'
REPLY_VOICE_MISSING_SCRIPT_HINT_MARKER="无法找到语音脚本，请检查 xiaoke-voice-mode/scripts/generate_tts_media.sh。"
REPLY_VOICE_TTS_SCRIPT_NOT_FOUND_MARKER="reply voice script not found; checked:"
REPLY_VOICE_TTS_TIMEOUT_ENV_MARKER="OPENCLAW_REPLY_VOICE_TTS_TIMEOUT_MS"
REPLY_VOICE_TTS_EXEC_DETAIL_MARKER="reply voice script execution failed (timeoutMs="
REPLY_VOICE_NO_FINAL_GUARD_MARKER="!queuedFinal && finalCount === 0"
REPLY_VOICE_NO_FINAL_FALLBACK_TEXT_MARKER="VOICE_MODE_NO_REPLY_FALLBACK_TEXT"
REPLY_VOICE_NO_FINAL_FALLBACK_REPLY_LOG_MARKER="sent no-final fallback text via reply"
REPLY_VOICE_NO_FINAL_FALLBACK_DIRECT_LOG_MARKER="sent no-final fallback text via direct message"
REPLY_VOICE_NO_FINAL_FALLBACK_TEXT_ERR_MARKER="failed to send voice mode no-reply fallback text via reply"
REPLY_VOICE_NO_FINAL_FALLBACK_DIRECT_ERR_MARKER="failed to send voice mode no-reply fallback text via direct message"
REPLY_VOICE_NO_FINAL_TEXT_CANDIDATE_MARKER="using no-final text candidate from dispatcher"
REPLY_VOICE_NO_DELIVERY_FALLBACK_MARKER="const voiceQueuedButNoDeliveryDelayFallbackState ="
REPLY_VOICE_NO_DELIVERY_DELAY_CONST_MARKER="const FEISHU_VOICE_NO_DELIVERY_FALLBACK_DELAY_MS = 60_000;"
REPLY_VOICE_NO_DELIVERY_DELAY_SCHEDULE_MARKER="queued final reply without confirmed outbound delivery in voice mode; scheduling delayed fallback text in"
REPLY_VOICE_NO_DELIVERY_DELAY_FIRE_MARKER="delayed no-delivery fallback timer fired after"
REPLY_VOICE_NO_DELIVERY_DELAY_SKIP_MARKER="delayed no-delivery fallback skipped after"
REPLY_VOICE_NO_DELIVERY_DELAY_TIMER_MARKER="setTimeout(() => {"
REPLY_VOICE_NO_DELIVERY_BLOCK_START_ANCHOR="if (voiceQueuedButNoDeliveryDelayFallbackState) {"
REPLY_VOICE_NO_DELIVERY_BLOCK_END_ANCHOR="if (voiceNoDeliveryAfterSupplementFailureFallbackState) {"
REPLY_VOICE_SUPPLEMENTAL_MEDIA_MARKER="delivered supplemental voice media from final text candidate"
REPLY_VOICE_SUPPLEMENTAL_FAILURE_FALLBACK_MARKER="supplemental voice delivery failed in voice mode; forcing fallback text"
REPLY_VOICE_DISPATCH_DRAIN_MARKER="dispatcher.waitForIdle()"
REPLY_VOICE_TIMEOUT_OVERRIDE_MARKER="const FEISHU_REPLY_TIMEOUT_OVERRIDE_SECONDS = 90;"
REPLY_VOICE_FORCE_THINKING_OFF_MARKER='thinking: voiceModeEnabled ? "off" : undefined,'
REPLY_VOICE_DISABLE_BLOCK_STREAMING_REGEX='disableBlockStreaming:[[:space:]]*(true|voiceModeEnabled[[:space:]]*\?[[:space:]]*true[[:space:]]*:[[:space:]]*undefined),'
REPLY_VOICE_REPLY_OPTIONS_DISABLE_BLOCK_STREAMING_REGEX='replyOptions:[[:space:]]*\{[^}]*disableBlockStreaming:[[:space:]]*(true|voiceModeEnabled[[:space:]]*\?[[:space:]]*true[[:space:]]*:[[:space:]]*undefined)'
REPLY_VOICE_CREATE_DISPATCHER_CALL_MARKER="createFeishuReplyDispatcher({"
REPLY_VOICE_SLOW_NOTICE_DISABLED_MARKER="const FEISHU_SLOW_REPLY_NOTICE_ENABLED = false;"
REPLY_VOICE_SLOW_NOTICE_TIMER_GUARD_MARKER="const slowReplyTimer = FEISHU_SLOW_REPLY_NOTICE_ENABLED"
RUNTIME_REASONING_SUPPRESS_GUARD_MARKER="const hasRenderableContent = Boolean(text || payload.mediaUrl || payload.mediaUrls && payload.mediaUrls.length > 0 || payload.audioAsVoice || payload.channelData && Object.keys(payload.channelData).length > 0);"
RUNTIME_REPLY_THINK_OVERRIDE_MARKER="const replyOptionThinkLevel = normalizeThinkLevel(opts?.thinking);"
MEDIA_PATH_HELPER_MARKER="resolveFeishuMediaUrlForLoad"
MEDIA_PATH_TMP_BRIDGE_MARKER='"workspace", "tmp-media"'
MEDIA_AUDIO_UPLOAD_RETRY_MARKER="const uploadDurationCandidates ="
MEDIA_AUDIO_MSGTYPE_RETRY_MARKER='const msgTypeCandidates: Array<"audio" | "media" | "file"> ='
NANO_BANANA_MODEL_PATCH_MARKER="OPENCLAW_NANO_BANANA_MODEL_PATCH_V1-BEGIN"
FEISHU_NODE_SDK_PACKAGE="@larksuiteoapi/node-sdk"

show_help() {
  cat <<'EOF'
Usage: update-openclaw-with-feishu-repatch.sh [options] [-- <openclaw update args...>]

Options:
  --dry-run                      Skip `openclaw update`; run all patches in preview mode.
  --skip-update                  Skip `openclaw update`; only run patches.
  --no-restart                   Do not restart gateway after apply mode.
  --target-file <path>           Override account import repatch target file.
  --video-target-root <dir>      Override feishu video patch target root.
  --runtime-target-root <dir>    Override runtime hardening patch target root.
  --openclaw-root <dir>          Override openclaw package root (for dependency guard).
  --openclaw-bin <path>          Override openclaw binary (default: /opt/homebrew/bin/openclaw).
  --npm-bin <path-or-name>       Override npm binary for dependency guard (default: npm).
  --node-bin <path-or-name>      Override node binary (default: node).
  --repatch-script <path>        Alias of --account-repatch-script (backward-compatible).
  --account-repatch-script <path> Override account import repatch script path.
  --video-repatch-script <path>  Override feishu video repatch script path.
  --dedup-repatch-script <path>  Override feishu dedup repatch script path.
  --reply-media-repatch-script <path> Override feishu reply media repatch script path.
  --reply-voice-repatch-script <path> Override feishu reply voice repatch script path.
  --media-path-repatch-script <path> Override feishu media path repatch script path.
  --nano-banana-repatch-script <path> Override nano-banana model repatch script path.
  --nano-banana-target <path>    Override nano-banana generate_image.py patch target path.
  --runtime-patch-script <path>  Override runtime hardening patch script path.
  --model-guard-script <path>    Override model rollback guard script path.
  --media-transcribe-guard-script <path> Override media transcribe guard script path.
  --plugin-skill-guard-script <path> Override plugin+skill dependency guard script path.
  --auth-profiles-guard-script <path> Override auth profiles guard script path.
  --didaapi-subtasks-repatch-script <path> Override DidaAPI subtasks repatch script path.
  --dmg-install-script <path>    Override latest OpenClaw dmg install script path.
  --skip-dmg-install             Skip latest OpenClaw dmg install step.
  --dmg-url <url>                Optional explicit dmg URL passed to dmg install script.
  --dmg-path <path>              Optional local dmg path passed to dmg install script.
  --skip-feishu-sdk-guard        Skip auto-guard for @larksuiteoapi/node-sdk.
  --npm-registry <url>           Force npm registry for `openclaw update`.
  --npm-registry-candidates <c>  Comma-separated registries probed before update.
  -h, --help                     Show this help message.
EOF
}

dry_run=false
skip_update=false
restart_gateway=true
target_file=""
video_target_root="$DEFAULT_VIDEO_TARGET_ROOT"
runtime_target_root="$DEFAULT_RUNTIME_TARGET_ROOT"
openclaw_root="$DEFAULT_OPENCLAW_ROOT"
openclaw_bin="$DEFAULT_OPENCLAW_BIN"
npm_bin="$DEFAULT_NPM_BIN"
node_bin="$DEFAULT_NODE_BIN"
account_repatch_script="$DEFAULT_ACCOUNT_REPATCH_SCRIPT"
video_repatch_script="$DEFAULT_VIDEO_REPATCH_SCRIPT"
dedup_repatch_script="$DEFAULT_DEDUP_REPATCH_SCRIPT"
reply_media_repatch_script="$DEFAULT_REPLY_MEDIA_REPATCH_SCRIPT"
reply_voice_repatch_script="$DEFAULT_REPLY_VOICE_REPATCH_SCRIPT"
media_path_repatch_script="$DEFAULT_MEDIA_PATH_REPATCH_SCRIPT"
nano_banana_repatch_script="$DEFAULT_NANO_BANANA_REPATCH_SCRIPT"
nano_banana_target="$DEFAULT_NANO_BANANA_TARGET"
runtime_patch_script="$DEFAULT_RUNTIME_PATCH_SCRIPT"
model_guard_script="$DEFAULT_MODEL_GUARD_SCRIPT"
media_transcribe_guard_script="$DEFAULT_MEDIA_TRANSCRIBE_GUARD_SCRIPT"
plugin_skill_guard_script="$DEFAULT_PLUGIN_SKILL_GUARD_SCRIPT"
auth_profiles_guard_script="$DEFAULT_AUTH_PROFILES_GUARD_SCRIPT"
didaapi_subtasks_repatch_script="$DEFAULT_DIDAAPI_SUBTASKS_REPATCH_SCRIPT"
dmg_install_script="$DEFAULT_DMG_INSTALL_SCRIPT"
dmg_install_enabled="${OPENCLAW_UPDATE_DMG_INSTALL:-1}"
feishu_sdk_guard_enabled="${OPENCLAW_FEISHU_SDK_GUARD:-1}"
dmg_url=""
dmg_path=""
npm_registry=""
npm_registry_candidates="${OPENCLAW_NPM_REGISTRY_CANDIDATES:-$DEFAULT_NPM_REGISTRY_CANDIDATES}"
update_args=()

while (($#)); do
  case "$1" in
    --dry-run)
      dry_run=true
      shift
      ;;
    --skip-update)
      skip_update=true
      shift
      ;;
    --no-restart)
      restart_gateway=false
      shift
      ;;
    --target-file)
      if (($# < 2)); then
        echo "missing value for --target-file" >&2
        exit 2
      fi
      target_file="$2"
      shift 2
      ;;
    --video-target-root)
      if (($# < 2)); then
        echo "missing value for --video-target-root" >&2
        exit 2
      fi
      video_target_root="$2"
      shift 2
      ;;
    --runtime-target-root)
      if (($# < 2)); then
        echo "missing value for --runtime-target-root" >&2
        exit 2
      fi
      runtime_target_root="$2"
      shift 2
      ;;
    --openclaw-root)
      if (($# < 2)); then
        echo "missing value for --openclaw-root" >&2
        exit 2
      fi
      openclaw_root="$2"
      shift 2
      ;;
    --openclaw-bin)
      if (($# < 2)); then
        echo "missing value for --openclaw-bin" >&2
        exit 2
      fi
      openclaw_bin="$2"
      shift 2
      ;;
    --npm-bin)
      if (($# < 2)); then
        echo "missing value for --npm-bin" >&2
        exit 2
      fi
      npm_bin="$2"
      shift 2
      ;;
    --node-bin)
      if (($# < 2)); then
        echo "missing value for --node-bin" >&2
        exit 2
      fi
      node_bin="$2"
      shift 2
      ;;
    --repatch-script)
      if (($# < 2)); then
        echo "missing value for --repatch-script" >&2
        exit 2
      fi
      account_repatch_script="$2"
      shift 2
      ;;
    --account-repatch-script)
      if (($# < 2)); then
        echo "missing value for --account-repatch-script" >&2
        exit 2
      fi
      account_repatch_script="$2"
      shift 2
      ;;
    --video-repatch-script)
      if (($# < 2)); then
        echo "missing value for --video-repatch-script" >&2
        exit 2
      fi
      video_repatch_script="$2"
      shift 2
      ;;
    --dedup-repatch-script)
      if (($# < 2)); then
        echo "missing value for --dedup-repatch-script" >&2
        exit 2
      fi
      dedup_repatch_script="$2"
      shift 2
      ;;
    --reply-media-repatch-script)
      if (($# < 2)); then
        echo "missing value for --reply-media-repatch-script" >&2
        exit 2
      fi
      reply_media_repatch_script="$2"
      shift 2
      ;;
    --reply-voice-repatch-script)
      if (($# < 2)); then
        echo "missing value for --reply-voice-repatch-script" >&2
        exit 2
      fi
      reply_voice_repatch_script="$2"
      shift 2
      ;;
    --media-path-repatch-script)
      if (($# < 2)); then
        echo "missing value for --media-path-repatch-script" >&2
        exit 2
      fi
      media_path_repatch_script="$2"
      shift 2
      ;;
    --nano-banana-repatch-script)
      if (($# < 2)); then
        echo "missing value for --nano-banana-repatch-script" >&2
        exit 2
      fi
      nano_banana_repatch_script="$2"
      shift 2
      ;;
    --nano-banana-target)
      if (($# < 2)); then
        echo "missing value for --nano-banana-target" >&2
        exit 2
      fi
      nano_banana_target="$2"
      shift 2
      ;;
    --runtime-patch-script)
      if (($# < 2)); then
        echo "missing value for --runtime-patch-script" >&2
        exit 2
      fi
      runtime_patch_script="$2"
      shift 2
      ;;
    --model-guard-script)
      if (($# < 2)); then
        echo "missing value for --model-guard-script" >&2
        exit 2
      fi
      model_guard_script="$2"
      shift 2
      ;;
    --media-transcribe-guard-script)
      if (($# < 2)); then
        echo "missing value for --media-transcribe-guard-script" >&2
        exit 2
      fi
      media_transcribe_guard_script="$2"
      shift 2
      ;;
    --plugin-skill-guard-script)
      if (($# < 2)); then
        echo "missing value for --plugin-skill-guard-script" >&2
        exit 2
      fi
      plugin_skill_guard_script="$2"
      shift 2
      ;;
    --auth-profiles-guard-script)
      if (($# < 2)); then
        echo "missing value for --auth-profiles-guard-script" >&2
        exit 2
      fi
      auth_profiles_guard_script="$2"
      shift 2
      ;;
    --didaapi-subtasks-repatch-script)
      if (($# < 2)); then
        echo "missing value for --didaapi-subtasks-repatch-script" >&2
        exit 2
      fi
      didaapi_subtasks_repatch_script="$2"
      shift 2
      ;;
    --dmg-install-script)
      if (($# < 2)); then
        echo "missing value for --dmg-install-script" >&2
        exit 2
      fi
      dmg_install_script="$2"
      shift 2
      ;;
    --skip-dmg-install)
      dmg_install_enabled=0
      shift
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
    --skip-feishu-sdk-guard)
      feishu_sdk_guard_enabled=0
      shift
      ;;
    --npm-registry)
      if (($# < 2)); then
        echo "missing value for --npm-registry" >&2
        exit 2
      fi
      npm_registry="$2"
      shift 2
      ;;
    --npm-registry-candidates)
      if (($# < 2)); then
        echo "missing value for --npm-registry-candidates" >&2
        exit 2
      fi
      npm_registry_candidates="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --)
      shift
      while (($#)); do
        update_args+=("$1")
        shift
      done
      ;;
    *)
      update_args+=("$1")
      shift
      ;;
  esac
done

trim_spaces() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_registry() {
  local reg
  reg="$(trim_spaces "$1")"
  reg="${reg%/}"
  printf '%s' "$reg"
}

require_file_marker() {
  local file="$1"
  local marker="$2"
  local label="$3"
  if [[ ! -f "$file" ]]; then
    echo "$label file missing: $file" >&2
    exit 1
  fi
  if ! grep -Fq -- "$marker" "$file"; then
    echo "$label marker missing in $file: $marker" >&2
    exit 1
  fi
}

require_file_regex() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if [[ ! -f "$file" ]]; then
    echo "$label file missing: $file" >&2
    exit 1
  fi
  if ! grep -Eq -- "$pattern" "$file"; then
    echo "$label regex missing in $file: $pattern" >&2
    exit 1
  fi
}

require_anchor_block_marker() {
  local file="$1"
  local anchor="$2"
  local marker="$3"
  local label="$4"
  if [[ ! -f "$file" ]]; then
    echo "$label file missing: $file" >&2
    exit 1
  fi
  if ! awk -v anchor="$anchor" -v marker="$marker" '
    index($0, anchor) { in_block = 1; next }
    in_block {
      if (index($0, marker)) { found = 1; exit 0 }
      if (index($0, "});")) { in_block = 0 }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"; then
    echo "$label marker missing under anchor in $file: anchor=$anchor marker=$marker" >&2
    exit 1
  fi
}

require_anchor_range_markers() {
  local file="$1"
  local start_anchor="$2"
  local end_anchor="$3"
  local label="$4"
  shift 4
  local markers=("$@")

  if [[ ! -f "$file" ]]; then
    echo "$label file missing: $file" >&2
    exit 1
  fi
  if [[ "${#markers[@]}" -eq 0 ]]; then
    echo "$label internal error: no markers provided" >&2
    exit 1
  fi

  local marker_sep=$'\034'
  local marker_blob
  local IFS="$marker_sep"
  marker_blob="${markers[*]}"

  local check_out
  set +e
  check_out="$(
    awk -v start_anchor="$start_anchor" -v end_anchor="$end_anchor" -v markers="$marker_blob" -v marker_sep="$marker_sep" '
      BEGIN {
        marker_count = split(markers, marker_list, marker_sep)
      }
      !in_range && index($0, start_anchor) {
        in_range = 1
        start_seen = 1
        next
      }
      in_range {
        if (index($0, end_anchor)) {
          end_seen = 1
          in_range = 0
          exit
        }
        for (i = 1; i <= marker_count; i++) {
          if (index($0, marker_list[i])) {
            found[i] = 1
          }
        }
      }
      END {
        if (!start_seen) {
          print "START_ANCHOR_MISSING"
          exit 2
        }
        if (!end_seen) {
          print "END_ANCHOR_MISSING"
          exit 3
        }
        missing = ""
        for (i = 1; i <= marker_count; i++) {
          if (!found[i]) {
            if (missing != "") {
              missing = missing " | "
            }
            missing = missing marker_list[i]
          }
        }
        if (missing != "") {
          print missing
          exit 1
        }
      }
    ' "$file"
  )"
  local check_status=$?
  set -e

  case "$check_status" in
    0)
      ;;
    2)
      echo "$label start anchor missing in $file: $start_anchor" >&2
      exit 1
      ;;
    3)
      echo "$label end anchor missing in $file: $end_anchor" >&2
      exit 1
      ;;
    *)
      echo "$label marker missing inside anchored block in $file: start=$start_anchor end=$end_anchor missing=$check_out" >&2
      exit 1
      ;;
  esac
}

require_tree_marker() {
  local root="$1"
  local marker="$2"
  local label="$3"
  if [[ ! -d "$root" ]]; then
    echo "$label root missing: $root" >&2
    exit 1
  fi
  if ! grep -R -Fq -- "$marker" "$root"; then
    echo "$label marker missing under $root: $marker" >&2
    exit 1
  fi
}

pick_update_registry() {
  if [[ -n "$npm_registry" ]]; then
    normalize_registry "$npm_registry"
    return 0
  fi

  local fallback="" raw reg probe_url
  IFS=',' read -r -a raw <<< "$npm_registry_candidates"
  for reg in "${raw[@]}"; do
    reg="$(normalize_registry "$reg")"
    if [[ -z "$reg" ]]; then
      continue
    fi
    if [[ -z "$fallback" ]]; then
      fallback="$reg"
    fi
    if ! command -v curl >/dev/null 2>&1; then
      continue
    fi
    probe_url="$reg/openclaw"
    if curl -fsSIL --max-time 5 "$probe_url" >/dev/null 2>&1; then
      printf '%s' "$reg"
      return 0
    fi
  done

  if [[ -n "$fallback" ]]; then
    printf '%s' "$fallback"
    return 0
  fi

  printf '%s' "https://registry.npmjs.org"
}

if [[ ! -x "$openclaw_bin" ]]; then
  echo "openclaw binary not executable: $openclaw_bin" >&2
  exit 1
fi

if [[ "$node_bin" == */* ]]; then
  if [[ ! -x "$node_bin" ]]; then
    echo "node binary not executable: $node_bin" >&2
    exit 1
  fi
elif ! command -v "$node_bin" >/dev/null 2>&1; then
  echo "node binary not found in PATH: $node_bin" >&2
  exit 1
fi

if [[ "$npm_bin" == */* ]]; then
  if [[ ! -x "$npm_bin" ]]; then
    echo "npm binary not executable: $npm_bin" >&2
    exit 1
  fi
elif ! command -v "$npm_bin" >/dev/null 2>&1; then
  echo "npm binary not found in PATH: $npm_bin" >&2
  exit 1
fi

if [[ ! -x "$account_repatch_script" ]]; then
  echo "account repatch script not executable: $account_repatch_script" >&2
  exit 1
fi

if [[ ! -x "$video_repatch_script" ]]; then
  echo "video repatch script not executable: $video_repatch_script" >&2
  exit 1
fi

if [[ ! -x "$dedup_repatch_script" ]]; then
  echo "dedup repatch script not executable: $dedup_repatch_script" >&2
  exit 1
fi

if [[ ! -x "$reply_media_repatch_script" ]]; then
  echo "reply media repatch script not executable: $reply_media_repatch_script" >&2
  exit 1
fi

if [[ ! -x "$reply_voice_repatch_script" ]]; then
  echo "reply voice repatch script not executable: $reply_voice_repatch_script" >&2
  exit 1
fi

if [[ ! -x "$media_path_repatch_script" ]]; then
  echo "media path repatch script not executable: $media_path_repatch_script" >&2
  exit 1
fi

if [[ ! -x "$nano_banana_repatch_script" ]]; then
  echo "nano banana repatch script not executable: $nano_banana_repatch_script" >&2
  exit 1
fi

if [[ ! -f "$runtime_patch_script" ]]; then
  echo "runtime patch script missing: $runtime_patch_script" >&2
  exit 1
fi

if [[ ! -x "$model_guard_script" ]]; then
  echo "model guard script not executable: $model_guard_script" >&2
  exit 1
fi

if [[ ! -x "$media_transcribe_guard_script" ]]; then
  echo "media transcribe guard script not executable: $media_transcribe_guard_script" >&2
  exit 1
fi

if [[ ! -x "$plugin_skill_guard_script" ]]; then
  echo "plugin+skill guard script not executable: $plugin_skill_guard_script" >&2
  exit 1
fi

if [[ ! -x "$auth_profiles_guard_script" ]]; then
  echo "auth profiles guard script not executable: $auth_profiles_guard_script" >&2
  exit 1
fi

if [[ ! -x "$didaapi_subtasks_repatch_script" ]]; then
  echo "didaapi subtasks repatch script not executable: $didaapi_subtasks_repatch_script" >&2
  exit 1
fi

if [[ "$dmg_install_enabled" != "0" && "$dmg_install_enabled" != "1" ]]; then
  echo "OPENCLAW_UPDATE_DMG_INSTALL must be 0 or 1" >&2
  exit 2
fi

if [[ "$dmg_install_enabled" == "1" && ! -x "$dmg_install_script" ]]; then
  echo "dmg install script not executable: $dmg_install_script" >&2
  exit 1
fi

if [[ "$feishu_sdk_guard_enabled" != "0" && "$feishu_sdk_guard_enabled" != "1" ]]; then
  echo "OPENCLAW_FEISHU_SDK_GUARD must be 0 or 1" >&2
  exit 2
fi

if [[ ! -d "$openclaw_root" ]]; then
  echo "openclaw root not found: $openclaw_root" >&2
  exit 1
fi

ensure_feishu_node_sdk() {
  local registry="$1"
  local pkg_json="$openclaw_root/node_modules/@larksuiteoapi/node-sdk/package.json"
  if [[ -f "$pkg_json" ]]; then
    return 0
  fi
  echo "missing ${FEISHU_NODE_SDK_PACKAGE}; installing into $openclaw_root" >&2
  local npm_cmd=("$npm_bin" install --prefix "$openclaw_root" "$FEISHU_NODE_SDK_PACKAGE")
  if [[ -n "$registry" ]]; then
    npm_cmd+=(--registry "$registry")
  fi
  "${npm_cmd[@]}"
  if [[ ! -f "$pkg_json" ]]; then
    echo "failed to provision ${FEISHU_NODE_SDK_PACKAGE} under $openclaw_root" >&2
    exit 1
  fi
}

run_didaapi_subtasks_repatch() {
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/openclaw-didaapi-repatch.XXXXXX")"
  set +e
  "$didaapi_subtasks_repatch_script" "${didaapi_subtasks_repatch_args[@]}" >"$out_file" 2>&1
  local status=$?
  set -e

  cat "$out_file"

  if [[ "$status" -eq 0 ]]; then
    rm -f "$out_file"
    return 0
  fi

  if grep -Fq 'target file missing:' "$out_file"; then
    echo "didaapi subtasks repatch skipped (missing target file)" >&2
    rm -f "$out_file"
    return 0
  fi

  rm -f "$out_file"
  return "$status"
}

account_args=()
video_args=()
dedup_args=()
reply_media_args=()
reply_voice_args=()
runtime_args=()
nano_banana_args=()
model_guard_args=()
media_transcribe_guard_args=()
plugin_skill_guard_args=()
auth_profiles_guard_args=()
didaapi_subtasks_repatch_args=()

if [[ "$dry_run" == "true" ]]; then
  account_args+=(--dry-run)
  video_args+=(--dry-run)
  dedup_args+=(--dry-run)
  reply_media_args+=(--dry-run)
  reply_voice_args+=(--dry-run)
  runtime_args+=(--dry-run)
  nano_banana_args+=(--dry-run)
  model_guard_args+=(--dry-run)
  media_transcribe_guard_args+=(--dry-run)
  plugin_skill_guard_args+=(--dry-run)
  auth_profiles_guard_args+=(--dry-run)
  didaapi_subtasks_repatch_args+=(--dry-run)
else
  account_args+=(--apply)
  video_args+=(--apply)
  dedup_args+=(--apply)
  reply_media_args+=(--apply)
  reply_voice_args+=(--apply)
  runtime_args+=(--apply)
  nano_banana_args+=(--apply)
  model_guard_args+=(--apply)
  media_transcribe_guard_args+=(--apply)
  plugin_skill_guard_args+=(--apply)
  auth_profiles_guard_args+=(--apply)
  didaapi_subtasks_repatch_args+=(--apply)
fi

model_guard_args+=(
  --primary-model "$DEFAULT_MODEL_GUARD_PRIMARY_MODEL"
  --primary-alias "$DEFAULT_MODEL_GUARD_PRIMARY_ALIAS"
)
for model_guard_fallback in "${DEFAULT_MODEL_GUARD_FALLBACK_MODELS[@]}"; do
  model_guard_args+=(--fallback-model "$model_guard_fallback")
done

if [[ -n "$target_file" ]]; then
  account_args+=(--target-file "$target_file")
fi

video_args+=(--target-root "$video_target_root")
dedup_args+=(--target-root "$video_target_root")
reply_media_args+=(--target-root "$video_target_root")
reply_voice_args+=(--target-root "$video_target_root")
runtime_args+=(--target-root "$runtime_target_root")
nano_banana_args+=(--target "$nano_banana_target")

if [[ "$dry_run" == "false" && "$skip_update" == "false" ]]; then
  if [[ "$dmg_install_enabled" == "1" ]]; then
    dmg_install_cmd=("$dmg_install_script" --apply)
    if [[ -n "$dmg_url" ]]; then
      dmg_install_cmd+=(--dmg-url "$dmg_url")
    fi
    if [[ -n "$dmg_path" ]]; then
      dmg_install_cmd+=(--dmg-path "$dmg_path")
    fi
    "${dmg_install_cmd[@]}"
  fi

  update_registry="$(pick_update_registry)"
  if [[ -n "$update_registry" ]]; then
    echo "using npm registry: $update_registry" >&2
    NPM_CONFIG_REGISTRY="$update_registry" npm_config_registry="$update_registry" \
      "$openclaw_bin" update "${update_args[@]}"
  else
    "$openclaw_bin" update "${update_args[@]}"
  fi

  "$openclaw_bin" gateway install --force
fi

if [[ "$dry_run" == "false" && "$feishu_sdk_guard_enabled" == "1" ]]; then
  feishu_sdk_registry="$(pick_update_registry)"
  ensure_feishu_node_sdk "$feishu_sdk_registry"
fi

"$account_repatch_script" "${account_args[@]}"
"$video_repatch_script" "${video_args[@]}"
"$dedup_repatch_script" "${dedup_args[@]}"
"$reply_media_repatch_script" "${reply_media_args[@]}"
"$reply_voice_repatch_script" "${reply_voice_args[@]}"
if [[ "$dry_run" == "false" ]]; then
  require_file_marker "$video_target_root/dedup.ts" "$DEDUP_PERSIST_ENV_MARKER" "feishu dedup"
  require_file_marker "$video_target_root/dedup.ts" "$DEDUP_PERSIST_FILE_MARKER" "feishu dedup"
  require_file_marker "$video_target_root/dedup.ts" "$DEDUP_PERSIST_EXPORT_MARKER" "feishu dedup"
  require_file_marker "$video_target_root/bot.ts" "$BOT_EVENT_ID_LOG_MARKER" "feishu bot audit"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_DEDUP_MARKER" "feishu reply media dedup"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_PREFIX_TRIM_MARKER" "feishu reply media dedup"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_TEXT_FALLBACK_MARKER" "feishu reply media fallback"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_NO_FINAL_CANDIDATE_MARKER" "feishu reply media no-final text candidate"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_OUTBOUND_DELIVERY_MARKER" "feishu reply media outbound delivery state"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_OUTBOUND_MEDIA_MARKER" "feishu reply media outbound media state"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_DISPATCHER_MIRROR_MARKER" "feishu reply media dispatcher state mirror"
  require_anchor_range_markers \
    "$video_target_root/reply-dispatcher.ts" \
    "$REPLY_MEDIA_DISPATCHER_MIRROR_BLOCK_START_ANCHOR" \
    "$REPLY_MEDIA_DISPATCHER_MIRROR_BLOCK_END_ANCHOR" \
    "feishu reply media dispatcher mirror writeback block" \
    "$REPLY_MEDIA_DISPATCHER_OUTBOUND_WRITEBACK_MARKER" \
    "$REPLY_MEDIA_DISPATCHER_MIRROR_WRITEBACK_MARKER"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_VOICE_ERROR_RE_MARKER" "feishu reply media voice fallback"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_VOICE_PREFER_TEXT_MARKER" "feishu reply media voice fallback"
  require_file_marker "$video_target_root/reply-dispatcher.ts" "$REPLY_MEDIA_VOICE_TTS_FAIL_LOG_MARKER" "feishu reply media voice fallback"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_COMMAND_MARKER" "feishu reply voice"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_PARSE_MARKER" "feishu reply voice"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_SEGMENT_MARKER" "feishu reply voice"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_STATE_CACHE_MARKER" "feishu voice mode state"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_STATE_BRIDGE_MARKER" "feishu voice mode state"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_LOCAL_TOGGLE_MARKER" "feishu voice mode state"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_FORCE_TTS_MARKER" "feishu voice mode state"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_MODE_ENABLED_LOG_MARKER" "feishu voice mode state"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_FASTPATH_MARKER" "feishu reply voice"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_MISSING_SCRIPT_HINT_MARKER" "feishu reply voice"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_FINAL_GUARD_MARKER" "feishu reply voice no-final guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_FINAL_FALLBACK_TEXT_MARKER" "feishu reply voice no-final guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_FINAL_FALLBACK_REPLY_LOG_MARKER" "feishu reply voice no-final guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_FINAL_FALLBACK_DIRECT_LOG_MARKER" "feishu reply voice no-final guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_FINAL_FALLBACK_TEXT_ERR_MARKER" "feishu reply voice no-final guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_FINAL_FALLBACK_DIRECT_ERR_MARKER" "feishu reply voice no-final guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_FINAL_TEXT_CANDIDATE_MARKER" "feishu reply voice no-final guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_DELIVERY_FALLBACK_MARKER" "feishu reply voice no-delivery guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_DELIVERY_DELAY_CONST_MARKER" "feishu reply voice no-delivery guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_DELIVERY_DELAY_SCHEDULE_MARKER" "feishu reply voice no-delivery guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_DELIVERY_DELAY_FIRE_MARKER" "feishu reply voice no-delivery guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_NO_DELIVERY_DELAY_SKIP_MARKER" "feishu reply voice no-delivery guard"
  require_anchor_range_markers \
    "$video_target_root/bot.ts" \
    "$REPLY_VOICE_NO_DELIVERY_BLOCK_START_ANCHOR" \
    "$REPLY_VOICE_NO_DELIVERY_BLOCK_END_ANCHOR" \
    "feishu reply voice no-delivery branch structure" \
    "$REPLY_VOICE_NO_DELIVERY_DELAY_TIMER_MARKER" \
    "$REPLY_VOICE_NO_DELIVERY_DELAY_SCHEDULE_MARKER" \
    "$REPLY_VOICE_NO_DELIVERY_DELAY_FIRE_MARKER" \
    "$REPLY_VOICE_NO_DELIVERY_DELAY_SKIP_MARKER"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_SUPPLEMENTAL_MEDIA_MARKER" "feishu reply voice supplemental media guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_SUPPLEMENTAL_FAILURE_FALLBACK_MARKER" "feishu reply voice supplemental failure fallback guard"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_DISPATCH_DRAIN_MARKER" "feishu reply voice dispatch drain"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_TIMEOUT_OVERRIDE_MARKER" "feishu reply timeout override"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_FORCE_THINKING_OFF_MARKER" "feishu reply voice thinking off"
  require_file_regex "$video_target_root/bot.ts" "$REPLY_VOICE_DISABLE_BLOCK_STREAMING_REGEX" "feishu reply voice block streaming disable"
  require_file_regex "$video_target_root/bot.ts" "$REPLY_VOICE_REPLY_OPTIONS_DISABLE_BLOCK_STREAMING_REGEX" "feishu reply voice replyOptions block streaming disable"
  require_anchor_block_marker "$video_target_root/bot.ts" "$REPLY_VOICE_CREATE_DISPATCHER_CALL_MARKER" "$REPLY_VOICE_FORCE_TTS_MARKER" "feishu reply voice dispatcher force tts bridge"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_SLOW_NOTICE_DISABLED_MARKER" "feishu slow notice disable"
  require_file_marker "$video_target_root/bot.ts" "$REPLY_VOICE_SLOW_NOTICE_TIMER_GUARD_MARKER" "feishu slow notice disable"
  require_file_marker "$video_target_root/reply-voice-command.ts" "$REPLY_VOICE_COMMAND_FILE_MARKER" "feishu reply voice command"
  require_file_marker "$video_target_root/reply-voice-tts.ts" "$REPLY_VOICE_TTS_MARKER" "feishu reply voice tts"
  require_file_marker "$video_target_root/reply-voice-tts.ts" "$REPLY_VOICE_TTS_STATE_BRIDGE_MARKER" "feishu reply voice state bridge"
  require_file_marker "$video_target_root/reply-voice-tts.ts" "$REPLY_VOICE_TTS_MEDIA_MARKER" "feishu reply voice tts"
  require_file_marker "$video_target_root/reply-voice-tts.ts" "$REPLY_VOICE_TTS_SCRIPT_NOT_FOUND_MARKER" "feishu reply voice tts"
  require_file_marker "$video_target_root/reply-voice-tts.ts" "$REPLY_VOICE_TTS_TIMEOUT_ENV_MARKER" "feishu reply voice tts timeout"
  require_file_marker "$video_target_root/reply-voice-tts.ts" "$REPLY_VOICE_TTS_EXEC_DETAIL_MARKER" "feishu reply voice tts error detail"
fi
if [[ "$dry_run" == "true" ]]; then
  "$media_path_repatch_script" --dry-run --target "$video_target_root/media.ts"
else
  "$media_path_repatch_script" --target "$video_target_root/media.ts"
  require_file_marker "$video_target_root/media.ts" "$MEDIA_PATH_HELPER_MARKER" "feishu media path"
  require_file_marker "$video_target_root/media.ts" "$MEDIA_PATH_TMP_BRIDGE_MARKER" "feishu media path"
  require_file_marker "$video_target_root/media.ts" "$MEDIA_AUDIO_UPLOAD_RETRY_MARKER" "feishu media upload retry route"
  require_file_marker "$video_target_root/media.ts" "$MEDIA_AUDIO_MSGTYPE_RETRY_MARKER" "feishu media msg_type retry route"
fi
"$nano_banana_repatch_script" "${nano_banana_args[@]}"
if [[ "$dry_run" == "false" ]]; then
  require_file_marker "$nano_banana_target" "$NANO_BANANA_MODEL_PATCH_MARKER" "nano banana model patch"
fi
"$node_bin" "$runtime_patch_script" "${runtime_args[@]}"
if [[ "$dry_run" == "false" ]]; then
  require_tree_marker "$runtime_target_root" "$RUNTIME_REASONING_SUPPRESS_GUARD_MARKER" "runtime deliver reasoning guard"
  require_tree_marker "$runtime_target_root" "$RUNTIME_REPLY_THINK_OVERRIDE_MARKER" "runtime reply thinking override"
fi
"$model_guard_script" "${model_guard_args[@]}"
"$media_transcribe_guard_script" "${media_transcribe_guard_args[@]}"
"$plugin_skill_guard_script" "${plugin_skill_guard_args[@]}"
"$auth_profiles_guard_script" "${auth_profiles_guard_args[@]}"
run_didaapi_subtasks_repatch

if [[ "$dry_run" == "false" && "$restart_gateway" == "true" ]]; then
  "$openclaw_bin" gateway restart
fi
