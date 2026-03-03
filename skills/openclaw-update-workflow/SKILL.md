---
name: openclaw-update-workflow
description: Use when maintaining OpenClaw on this machine after version updates, including reapplying local patches, running daily health checks, and diagnosing update-related regressions such as Feishu no-reply.
---

# OpenClaw Update Workflow

## Overview

把本机 OpenClaw 的“更新 + 重打补丁 + 自检”流程统一成一套可重复执行的操作。
优先调用本技能脚本，不重复手工拼命令。

## When to Use

- 升级 OpenClaw 到新版本后，需要自动重打本地补丁。
- 每日巡检，默认先检查最新版和本机健康状态；若显示有新版本则自动进入 `full` 升级链路。
- 更新后出现 Feishu 无回复、gateway timeout、model 回退等问题。
- Feishu 能收到文本但看不到语音/附件（常见日志：`Local media path is not under an allowed directory`）。
- 需要刷新 launchd 每日 4 点自动更新任务。

## Quick Start

默认入口脚本：

```bash
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh <mode> [-- extra args]
```

模式：

- `monitor`：巡检监控（先 `--skip-update` + 检查 `latest_version` + 生成报告；若 `latest_version > before_version` 则自动执行 `full`）。
- `stable`：日常稳定维护（`--skip-update`）。
- `full`：真实升级（`--with-update`，含三阶段自愈/回滚链路）。可人工手动强制触发。
  - 升级链路会先尝试安装 OpenClaw 最新 `.dmg`（GUI），再执行 CLI 更新与补丁。
- `patch`：仅重打统一补丁链（不执行 `openclaw update`）。
- `launchd-refresh`：刷新系统级每日自动更新任务。
- `doctor`：快速健康检查（`status --deep` + `gateway probe` + `security audit --deep`）。
- `voice-doctor`：语音链路专检（默认只检查，可加 `--apply` 自动修复默认音色与情绪路由）。
- `feishu-no-reply`：飞书“收到消息但无回复”快速预检（通道健康 + 最近入站/派发标记 + 致命插件报错 + gateway launchd 代理环境/可达性快照）。
- `selfie-key-precheck`：自拍链路 Gemini Key 优先级预检（强制注入无效 `GEMINI_API_KEY`，验证仍可成功出图）。
- `cron-partial-precheck`：Cron“状态显示成功但只输出中间进度”回归预检（检查 run 状态、session stopReason、runtime patch marker 覆盖率；支持 `--all-jobs` 全量扫描）。

## Proxy (Clash LAN)

- 当 Codex 自动化环境无法访问本机 loopback（`127.0.0.1:7897`）时，使用 LAN 变量注入：
  - `OPENCLAW_SKILL_HTTP_PROXY_HOST`（例如 `192.168.1.2`）
  - `OPENCLAW_SKILL_HTTP_PROXY_PORT`（默认 `7897`）
  - `OPENCLAW_SKILL_SOCKS_PROXY_PORT`（默认 `7897`）
- 预检开关：
  - `OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED`（默认 `1`）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_URL`（默认 `https://registry.npmjs.org`）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_TIMEOUT`（默认 `5` 秒）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_ATTEMPTS`（默认 `2`，失败后短重试）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_RETRY_DELAY`（默认 `1` 秒）
- monitor 自动升级开关：
  - `OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION`（默认 `1`；设为 `0` 时仅巡检不自动执行 `full`）

```bash
OPENCLAW_SKILL_HTTP_PROXY_HOST=192.168.1.2 \
OPENCLAW_SKILL_HTTP_PROXY_PORT=7897 \
OPENCLAW_SKILL_SOCKS_PROXY_PORT=7897 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor
```

## Standard Workflow

1. 先选模式：Codex 自动化默认用 `monitor`（检测到新版本会自动进入 `full`）；日常手工维护可用 `stable`；需要无条件升级时可手动用 `full`。
2. 执行封装脚本，并把额外参数透传给底层脚本（例如 `--feishu-target`、`--skip-launchd-check`）。
   - 统一更新脚本会校验 media-path 补丁 marker（`/tmp -> state/workspace/tmp-media` 桥接 + `uploadDurationCandidates` + `msgTypeCandidates(audio/media/file)`），缺失即失败，避免“看似成功但语音/附件发送回退”。
   - 统一更新脚本会校验 dedup 持久化导出 marker（`tryRecordMessagePersistent`），缺失即失败，避免“飞书能收消息但处理阶段崩溃无回复”（常见报错：`TypeError: ...tryRecordMessagePersistent is not a function`）。
   - 统一更新脚本会校验 reply-media 文本兜底解析 marker（`Saved: ./...png` / 裸路径 / Markdown `![...](...)`）与语音模式文本抑制 marker（`!params.forceVoiceModeTts` + `suppressTextDelivery`），防止飞书只回显文件路径文本或“先发文字再发语音”。
   - 统一更新脚本会校验 reply-voice 快路径 marker（回复消息 + `生成语音`，500 分段，失败即中断），并校验“缺脚本提示文案 + checked paths + 默认 `--voice-id wakaba_mutsumi` + `OPENCLAW_REPLY_VOICE_TTS_TIMEOUT_MS` + `reply voice script execution failed (timeoutMs=`”标记，防止升级后回退到普通文本回复、弱化报错、60 秒硬超时或音色漂移（如 `metis`）。
  - 统一更新脚本在关键路径启用锚点区间结构校验（例如 `finally { ... } -> onError:` 的 dispatcher mirror 写回区间，和 `if (voiceQueuedButNoDeliveryDelayFallbackState) { ... }` 的 no-delivery 分支区间），避免“仅伪造 marker 文本”误判为已修复。
  - reply-voice 补丁需兼容 dispatch options 锚点顺序漂移（`replyOptions`/`timeoutOverrideSeconds`/`thinking` 的顺序变化）与 `replyOptions` 键值写法漂移（如 `replyOptions: replyOptions` / 临时缺失），并强制保留 `forceVoiceModeTts: voiceModeEnabled`；同时要求 `createFeishuReplyDispatcher(...)` 调用内也注入 `forceVoiceModeTts: voiceModeEnabled`，避免升级后出现“语音模式已开启但仍走文本发送”。
   - 统一更新脚本会额外校验语音模式状态链路 marker（`voiceModeStateCache` + `handled voice mode command locally` + `forceVoiceModeTts: voiceModeEnabled` + `voice mode enabled for session`），防止升级后“语音模式开关看似生效但仍按文本路径下发”。
   - `full` 模式会强制执行 `openclaw gateway install --force`，并自动守卫/补装 `@larksuiteoapi/node-sdk`（缺失时自动安装）。
  - 日更脚本对 `status --deep` 的 `gateway closed (1006 ...)` 增加一次短重试（常见于 gateway 重启窗口），避免误报失败。
  - 日更脚本内置并发锁、`openclaw.json` 权限自修复、DNS/HTTP 预检、以及 `gateway probe` 的 `EPERM(127.0.0.1)` 环境限制降级。
  - 日更脚本写报告前会自动 `mkdir -p workspace/outputs/system-updates`，避免首次迁移或目录被清理后因 `REPORT_FILE` 路径不存在直接失败。
  - 若 DidaAPI 子任务补丁命中 `target file missing:`，统一补丁脚本会记录并跳过，不再触发整条更新流程回滚；其他 DidaAPI 错误仍按失败处理。
3. 读取输出里的 `REPORT_FILE=...`，按报告字段判定：
   - `dns_precheck`
   - `status_deep`
   - `gateway_probe`
   - `security_audit`
   - `gateway_self_heal` / `gateway_self_heal_actions`
   - `feishu_probe`
   - `first_error_class` / `result_domain`
   - `known_bug_fix` / `known_bug_fix_signature`
   - 若出现 `pairing required`，优先确认报告里是否已触发 `approve-pairing-repair` 自动自愈；仅当请求非 `cli`/`gateway-client` repair 或 approve 失败时再人工介入
4. 若失败，优先按 `references/update-flow-cheatsheet.md` 里的“单项补丁/排障命令”执行，不要直接改核心脚本。

## Known Fixes Only

- 自动修复仅允许命中已登记 signature（例如 `gateway_1006`、`missing_reply_voice_script`、`missing_dedup_persistent_export`、`didaapi_target_missing`、`dns_network`）。
- `gateway_1006` 的 apply 动作为分层自愈：`openclaw gateway restart`，若仍不健康则补做 `openclaw gateway install --force` + `openclaw gateway start`，最后 `openclaw gateway probe` 并以 `gateway status --json` 同时满足 `runtime.status=running` 且 `rpc.ok=true` 作为通过标准。
- `dns_network` 属于基础设施问题，只允许跳过/汇报，不自动改代码或改配置。
- 未知错误（`unsupported`）必须停止自动修复，写 inbox，并保留报告供人工排查。
- 运行已知修复脚本前建议先 `--dry-run`，确认 signature 判断正确后再 `--apply`。

## Automation Memory (经验沉淀)

- 日更报告会输出 `REPORT_FILE=...`；可用本地脚本提取摘要并追加到 Codex 自动化 memory：
  - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/append-openclaw-update-memory.sh --report <REPORT_FILE>`
- 摘要字段包含：`mode/result`、版本前后、`dns_precheck`、`status_deep`、`gateway_probe`、`security_audit`、`feishu_probe`、`first_error_class`、`result_domain`。
- 目的：沉淀“这次自动化真实发生了什么”，避免下次重复误判为功能 bug。

## 2026.3.1 经验沉淀（monitor/helper anchor）

- `monitor` 不是纯只读巡检：会执行统一补丁链（`--skip-update --no-restart`），所以补丁锚点漂移会在 `monitor` 暴露。
- `helper anchor not found` 的典型根因：`media.ts` 注释锚点文本漂移（例如句号/说明行变化）导致单锚点匹配失效。
- 快速判定命令（先 A 再 B）：
  - A: `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-media-path.sh --dry-run`
  - B: `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor`
- 固定验收口径：
  - A 输出不包含 `helper anchor not found`
  - B 输出包含 `STATUS=ok`

## Feishu Media Quick Fix

当出现“文本能发、语音/附件看不到”时，按这个最短链路处理：

1. 检查错误日志：
   - `rg -n "Local media path is not under an allowed directory" /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20`
   - `rg -n "voice fallback send failed|media send failed" /tmp/openclaw/openclaw-*.log /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20`
2. 重打媒体路径补丁（含 `/tmp` 媒体桥接）：
   - `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-media-path.sh --apply`
3. 重启并探测 gateway：
   - `openclaw gateway restart`
   - `openclaw gateway probe`
4. 再次重试业务消息。
5. 若“飞书能收到 `.opus` 但无法播放”：
   - 先用 `ffprobe` 校验文件封装/时长，再确认 `media.ts` 存在 `uploadDurationCandidates` 与 `msgTypeCandidates(audio/media/file)` 重试逻辑。

## Voice ID 快速定位（默认音色异常）

当“语音模式确认文本正常，但听到的不是默认音色”时，先抓当次请求的 `voice_id`，不要只看推断：

1. 暂停情绪路由后重试一次同样问题消息。
2. 在日志里按时间窗检索 TTS 请求参数（重点看 `voice_id`）。
3. 期望默认值为 `wakaba_mutsumi`；若仍是其他值（如 `metis`），按该次请求链路继续排查配置覆盖来源。

## Feishu 默认音色异常一键修复（metis -> wakaba）

当“开启语音模式后仍听到 metis”时，优先走语音专检：

1. 只检查（不改配置）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor`
2. 自动修复（推荐）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor -- --apply`
3. 修复动作包括：
   - `openclaw` 技能配置默认音色固定为 `wakaba_mutsumi`
   - `openclaw` 技能配置 `OPENCLAW_TTS_API_MODE=auto`（优先走 gateway，失败可回落 legacy）
   - `openclaw` 技能配置 `OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK=1`、`OPENCLAW_TTS_LEGACY_API_URL=http://127.0.0.1:9880/tts`
   - `openclaw` 技能配置 `OPENCLAW_TTS_GATEWAY_MAX_TIME=45`、`OPENCLAW_TTS_GATEWAY_DYNAMIC_TIMEOUT=1`（避免 20s 误超时）
   - `openclaw` 技能配置 `OPENCLAW_TTS_MAX_CHARS=120`、`OPENCLAW_TTS_SELF_HEAL_ON_TIMEOUT=1`（限制长文本卡死并在超时后自动拉起 TTS 服务）
   - `opclaw_tts_service` 的 `emotion_routing.enabled` 强制设为 `false`
   - `generate_tts_media.sh` 保持 gateway 主通道；通过 `openclaw` 配置开启 auto+fallback 兜底（降低“语音模式只回文字”概率）
   - `generate_tts_media.sh` 的 gateway 超时默认改为 `45s`，并按文本长度动态扩到上限（默认 `85s`），失败日志包含 `max_time`；当超时或 HTTP 500 时自动 `kickstart` `com.openclaw.gptsovits.backend/tts` 并等待健康检查恢复，默认再重试 1 次（重试文本默认压缩到 `80` 字）
   - 即使进入 legacy，默认参考音也固定为若叶睦（不再使用 metis 默认参考音）
   - 自动重启 `openclaw gateway`（以及已加载时的 `com.openclaw.gptsovits.tts`）

## Voice Fallback 预检（语音模式只回文字）

当“语音模式开启后只收到文字回复”时，先跑下面三条可判定预检：

1. 配置预检（A）：
   - `jq -r '.skills.entries["xiaoke-voice-mode"].env | [.OPENCLAW_TTS_API_MODE,.OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK,.OPENCLAW_TTS_LEGACY_API_URL] | @tsv' /Users/crane/.openclaw/openclaw.json`
2. 回落能力预检（B，故意坏端口，关闭 self-heal 避免重启干扰）：
   - `OPENCLAW_TTS_API_MODE=auto OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK=1 OPENCLAW_TTS_API_URL=http://127.0.0.1:1/tts OPENCLAW_TTS_LEGACY_API_URL=http://127.0.0.1:9880/tts OPENCLAW_TTS_SELF_HEAL_ON_TIMEOUT=0 bash /Users/crane/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh --text "voice-fallback-precheck-B"`
3. 主通道预检（C，9890）：
   - `OPENCLAW_TTS_API_MODE=auto OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK=1 OPENCLAW_TTS_API_URL=http://127.0.0.1:9890/tts OPENCLAW_TTS_LEGACY_API_URL=http://127.0.0.1:9880/tts bash /Users/crane/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh --text "voice-fallback-precheck-C"`

通过标准：

- A 输出必须为：`auto<TAB>1<TAB>http://127.0.0.1:9880/tts`
- B 必须满足：退出码 `0`、`stdout` 含 `MEDIA:`、`stderr` 含 `fallback to legacy`
- C 必须满足：退出码 `0`、`stdout` 含 `MEDIA:`

## Feishu No-Reply Quick Fix (消息已收到但无回复)

当飞书显示“消息发出成功”但小可不回复、Mac App 正常时，优先排查 dedup 导出缺失：

1. 检查处理阶段异常日志：
   - `rg -n "tryRecordMessagePersistent|error handling message: TypeError" /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20`
2. 重打 dedup 补丁（确保 `dedup.ts` 导出 `tryRecordMessagePersistent`）：
   - `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-dedup-hardening.sh --apply`
3. 重启并探测：
   - `openclaw gateway restart`
   - `openclaw channels status --probe --json`
4. 再次发送飞书测试消息（群聊需 `@小可`）。

快速预检命令（先看是否是通道卡住/插件加载异常）：

- `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-no-reply`
- 可选加窗口：`bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-no-reply -- --lines 200`
- 若预检出现 `REASON=gateway launchd proxy env detected but proxy endpoint is unreachable`，优先执行无代理重装/重启：
  - `openclaw gateway stop`
  - `env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u all_proxy -u no_proxy openclaw gateway install --force`
  - `openclaw gateway probe`

## Cron Partial-Report Quick Precheck (只发第一批资料/无最终报告)

当定时任务看起来“执行成功”，但只发了“第一批资料/等待继续搜索”等中间进度时，先跑预检确认是否命中 runtime 回归：

1. 执行预检（默认只检查 AI 自主学习 job）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck`
2. 推荐执行全量扫描（覆盖全部 cron job）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --all-jobs`
3. 关键判定字段：
   - `RESULT=pass`：最近一次没有“半截成功”信号。
   - `RESULT=fail` + `REASON=ok status with interim summary marker`：run 被误标为 `ok`，但 summary 仍是中间进度。
   - `RESULT=fail` + `REASON=ok status but assistant stopReason indicates incomplete/error end`：session 末状态异常（如 `toolUse` / `tool_calls` / `error`）。
   - `RESULT=warn` + `REASON=ok status but session file missing`：run 标记 `ok` 但 session 丢失，按阻断处理（非 0 退出）。
   - `RESULT=fail` + `REASON=runtime patch marker coverage incomplete`：`gateway-cli-*.js` 未全量命中补丁 marker，需重打 runtime hardening。
4. 指定 job 检查：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --job-id <job-id>`
5. 回看历史问题 session：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --session-id <session-id>`
6. 覆盖范围说明：
   - 不带 `--all-jobs` 时只检查单个 job（默认 `AI自主学习` 或 `--job-id` 指定）。

## Mail Cron Workspace Path Precheck

当“检查邮箱”cron 任务出现 `/tmp/qq_mail_1.scpt` 相关写入失败，或需要防止 message 回退到 `/tmp` 路径时，先跑这条预检：

- `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/mail-cron-workspace-path-precheck.sh`

判定标准：

- `RESULT=pass`：message 同时满足三条约束（包含 `workspace/tmp/mail-check` 绝对路径、包含“严禁/禁止 /tmp /var/tmp /private/tmp”语义、并明确 `osascript -e/heredoc + 不落盘 .scpt`）。
- `RESULT=fail`：至少一条约束不满足；`REASON` 会给出具体违反项（如 `workspace_tmp_path`、`ban_tmp_statement`、`osascript_or_heredoc_no_scpt`）。

失败后的修复方向：

- 把 cron `payload.message` 中所有临时脚本/临时文件路径限制到 `workspace/tmp`（例如 `/Users/crane/.openclaw/workspace/tmp`）。
- 在 message 中明确写出“禁止 /tmp”或等价禁止语句。
- 在 QQ AppleScript 规则中补充：优先 `osascript -e` 或 heredoc，且写明“不落盘 .scpt”；若必须落盘，固定到 `workspace/tmp/mail-check`。

## Voice Mode No-Final Quick Fix (语音模式无语音回复)

当飞书收到消息但“无语音、无文本且无明显报错”时，先判定是否是 agent 无 final：

1. 抓关键日志：
   - `rg -n "embedded run agent end|dispatch complete \\(queuedFinal=.*replies=.*\\)" /tmp/openclaw/openclaw-*.log -S | tail -40`
   - `rg -n "SLOW_REPLY_NOTICE_TEXT|slow-reply notice|HARD_TIMEOUT_FALLBACK_TEXT|dispatch complete \\(queuedFinal=false, replies=0\\)" /tmp/openclaw/openclaw-*.log /Users/crane/.openclaw/logs/gateway.log -S | tail -60`
2. 分类判断：
   - 若同一条消息出现 `embedded run agent end ... isError=false` 且随后 `dispatch complete (queuedFinal=false, replies=0)`：属于无 final（不是 TTS 失败）。
   - 若出现 `Local media path is not under an allowed directory`：属于媒体路径问题，走 `Feishu Media Quick Fix`。
3. 重打 reply-voice + reply-media 补丁（含 no-final 文字兜底 + 错误文案文字优先）：
   - `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-reply-voice.sh --apply`
4. 重启并探测：
   - `openclaw gateway restart`
   - `openclaw gateway probe`
5. 再次发送飞书测试消息（群聊需 `@小可`）。

## Selfie API Key Invalid Quick Fix

当飞书提示 `API key not valid`，且日志存在 `Blocked skill env overrides for xiaoke-selfie: GEMINI_API_KEY` 时，优先执行以下预检：

1. 执行 Gemini key 优先级预检（脚本会临时注入无效环境变量）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh selfie-key-precheck`
2. 预期输出：`PASS: xiaoke-selfie ignored invalid env key...`
3. 若失败，检查：
   - `~/.openclaw/openclaw.json` 中 `skills.entries.xiaoke-selfie.env.GEMINI_API_KEY` 是否存在且有效；
   - `xiaoke-selfie/scripts/xiaoke_selfie.py` 是否已包含“优先读 openclaw.json + 无效 key 自动重试备用 key”逻辑。

## Common Commands

```bash
# 每日巡检（自动化推荐；检测到新版本会自动 full）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 每日巡检但禁用自动 full（仅巡检）
OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 日常稳定维护
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh stable

# 真实升级（人工触发）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh full

# 真实升级但跳过 .dmg 安装
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh full -- --skip-dmg-install

# 仅重打补丁
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh patch

# 刷新 launchd 定时
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh launchd-refresh

# 语音链路专检（检查/修复默认音色）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor -- --apply

# 飞书无回复快速预检
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-no-reply

# 自拍 Gemini Key 优先级预检
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh selfie-key-precheck

# Cron 半截报告回归预检
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck
```

## Sync (Self-Contained Scripts)

- 本技能包含本地自包含脚本副本（`scripts/`），默认优先调用同目录脚本。
- 当 `~/.openclaw/scripts` 有更新时，先执行同步脚本再使用本技能：
  - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/sync-from-openclaw.sh --apply`
- 同步脚本会包含 `repatch-openclaw-nano-banana-model.sh`，避免 `full/monitor` 在“脚本不可执行/缺失”前置校验阶段直接失败。
- 同步脚本会从 `~/.openclaw/scripts` 复制更新/补丁脚本，并重写为同目录脚本优先；技能文档默认可从 Codex 技能目录自身读取（兼容已删除旧 OpenClaw 技能目录的场景）。

## Guardrails

- 不在技能内写入或回显密钥；认证信息仍通过既有环境变量流程注入。
- 不手改 `openclaw.json` 中 model/fallback，依赖现有 guard 脚本兜底。
- 发生失败时先用已有 repatch/guard 脚本，不引入新的网络依赖或临时黑魔法。
- 自动化只执行 `Known Fixes Only`；未知 bug 立即停止并转 inbox，不盲修。
- 回滚一致性依赖 snapshot 覆盖 `redact-*.js` + `run-main-*.js`，不要在更新后单独替换 `entry.js` 而不重打 runtime 补丁。

## References

- 完整命令清单：`references/update-flow-cheatsheet.md`
- 主流程 runbook：`/Users/crane/.openclaw/docs/runbooks/openclaw-update-local-patch-flow.md`
